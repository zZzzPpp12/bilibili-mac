import Foundation
import Observation
import BiliMacCore

@MainActor @Observable final class CommentActionsStore {
    private let api: any CommentWriting
    private var mid: Int?
    @ObservationIgnored private var models: [Int: CommentActionsModel] = [:]
    init(api: any CommentWriting) { self.api = api }
    func setAccount(_ mid: Int?) {
        models.values.forEach { $0.invalidate() }; models = [:]; self.mid = mid
    }
    func model(for video: Video) -> CommentActionsModel {
        if let model = models[video.aid] { return model }
        let model = CommentActionsModel(api: api, mid: mid, aid: video.aid, bvid: video.bvid)
        models[video.aid] = model; return model
    }
}

@MainActor @Observable final class CommentActionsModel {
    struct Composer: Identifiable {
        let id = UUID()
        let root: Int
        let parent: Int
        let name: String
        let preview: String
    }
    struct Deletion: Identifiable { let id = UUID(); let comment: Comment }
    struct Receipt: Identifiable {
        let id = UUID()
        let commentID: Int?
        let text: String
        let replyTo: String?
    }
    struct Reaction { let liked: Bool; let count: Int }
    let mid: Int?
    let aid: Int
    let bvid: String
    private let api: any CommentWriting
    private var active = true
    private var identity = UUID()
    private var drafts: [Int: String] = [:]
    private var reactions: [Int: Reaction] = [:]
    private(set) var deleted: Set<Int> = []
    private(set) var composer: Composer?
    private(set) var deletion: Deletion?
    private(set) var receipt: Receipt?
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var needsReview = false
    var error: String?
    var notice: String?

    init(api: any CommentWriting, mid: Int?, aid: Int, bvid: String) { self.api = api; self.mid = mid; self.aid = aid; self.bvid = bvid }
    var canAct: Bool { active && (mid ?? 0) > 0 && aid > 0 && !busy && !refreshing && !needsReview }
    var draft: String {
        get { drafts[composer?.parent ?? 0] ?? "" }
        set { drafts[composer?.parent ?? 0] = newValue }
    }
    var characterCount: Int { draft.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }
    var canSend: Bool { canAct && composer != nil && (try? CommentText.normalized(draft)) != nil }
    var officialURL: URL? { VideoInput.bvid(bvid) == bvid ? URL(string: "https://www.bilibili.com/video/\(bvid)/") : nil }

    func invalidate() {
        active = false; identity = UUID(); drafts = [:]; reactions = [:]; deleted = []
        composer = nil; deletion = nil; receipt = nil; busy = false; refreshing = false; needsReview = false; error = nil; notice = nil
    }
    func present(reply: Comment? = nil, root: Int = 0) {
        guard canAct, composer == nil, deletion == nil else { return }
        if let reply {
            guard reply.id > 0, root > 0, !deleted.contains(reply.id), !deleted.contains(root) else { return }
            composer = Composer(root: root, parent: reply.id, name: reply.name, preview: reply.message)
        } else { composer = Composer(root: 0, parent: 0, name: "", preview: "") }
        error = nil; notice = nil
    }
    func dismissComposer() { if !busy { composer = nil } }
    func clearReceipt() { receipt = nil }
    func effective(_ comment: Comment) -> Comment {
        var row = comment
        if let reaction = reactions[row.id] { row.liked = reaction.liked; row.likes = reaction.count }
        return row
    }
    func send(id: UUID) async {
        guard canSend, let mid, let composer, composer.id == id, deletion == nil else { return }
        let scope = identity, original = draft
        guard let text = try? CommentText.normalized(original) else { return }
        busy = true; error = nil; notice = nil; receipt = nil
        defer { if scope == identity { busy = false } }
        do {
            let result = try await api.addComment(mid: mid, aid: aid, bvid: bvid, message: text, root: composer.root, parent: composer.parent)
            guard active, scope == identity else { return }
            guard result.id > 0 else { throw ClientError.writeUncertain }
            if drafts[composer.parent] == original { drafts[composer.parent] = "" }
            receipt = Receipt(commentID: result.id, text: text, replyTo: composer.parent == 0 ? nil : composer.name)
            self.composer = nil
            // Never insert a receipt into the fetched list or inflate its count.
            notice = "服务器已接收，请刷新评论列表查看；公开显示以哔哩哔哩处理结果为准。"
        } catch {
            guard active, scope == identity else { return }
            failure(error)
            if needsReview { receipt = Receipt(commentID: nil, text: text, replyTo: composer.parent == 0 ? nil : composer.name) }
        }
    }
    func like(_ comment: Comment) async {
        guard canAct, let mid, composer == nil, deletion == nil, !deleted.contains(comment.id) else { return }
        let before = effective(comment)
        guard let liked = before.liked else { error = "点赞状态暂不可用，请刷新评论后再试。"; return }
        let scope = identity; busy = true; error = nil; notice = nil
        defer { if scope == identity { busy = false } }
        do {
            try await api.likeComment(mid: mid, aid: aid, bvid: bvid, id: comment.id, liked: !liked)
            guard active, scope == identity else { return }
            reactions[comment.id] = Reaction(liked: !liked, count: max(0, before.likes + (liked ? -1 : 1)))
            notice = liked ? "已取消评论点赞" : "已赞这条评论"
        } catch { if active, scope == identity { failure(error) } }
    }
    func proposeDelete(_ comment: Comment) {
        guard canAct, composer == nil, deletion == nil, comment.mid == mid, comment.mid > 0, !deleted.contains(comment.id) else { return }
        deletion = Deletion(comment: comment)
    }
    func cancelDelete() { if !busy { deletion = nil } }
    // Capture and lock synchronously: confirmationDialog dismisses its binding
    // before an unstructured Task gets a chance to run.
    func requestDelete(id: UUID) {
        guard let operation = beginDelete(id: id) else { return }
        Task { await finishDelete(operation) }
    }
    func confirmDelete(id: UUID) async {
        guard let operation = beginDelete(id: id) else { return }
        await finishDelete(operation)
    }
    private func beginDelete(id: UUID) -> (scope: UUID, proposal: Deletion)? {
        guard canAct, let mid, let deletion, deletion.id == id, deletion.comment.mid == mid else { return nil }
        busy = true; error = nil; notice = nil
        self.deletion = nil
        return (identity, deletion)
    }
    private func finishDelete(_ operation: (scope: UUID, proposal: Deletion)) async {
        let scope = operation.scope, deletion = operation.proposal
        defer { if scope == identity { busy = false; self.deletion = nil } }
        guard active, scope == identity, let mid else { return }
        do {
            try await api.deleteComment(mid: mid, aid: aid, bvid: bvid, comment: deletion.comment)
            guard active, scope == identity else { return }
            deleted.insert(deletion.comment.id); reactions[deletion.comment.id] = nil
            notice = "评论已删除；刷新列表可核对最新数量。"
        } catch { if active, scope == identity { failure(error) } }
    }
    func refresh(_ browser: CommentsModel) async {
        guard active, !busy, !refreshing, browser.aid == aid else { return }
        let scope = identity; refreshing = true
        defer { if scope == identity { refreshing = false } }
        let success = await browser.load()
        guard active, scope == identity, success else { return }
        reactions = [:]
        if needsReview { notice = "列表已刷新；上次操作结果仍待核对，请到官方页面确认。" }
    }
    /// A list's absence is not proof of rejection/deletion: moderation and
    /// pagination can hide a submitted comment. Only the user can release this
    /// guard after checking the official page; this never resends a request.
    func acknowledgeReview() {
        guard active, !busy, needsReview else { return }
        needsReview = false; error = nil; notice = "已解除提交限制。没有重发上次请求；再次发送可能产生重复评论。"
    }
    private func failure(_ error: any Error) {
        self.error = error.localizedDescription
        if case ClientError.writeUncertain = error {
            needsReview = true
            notice = "操作结果尚未确认，未自动重试。请到官方页面核对后再继续；草稿已保留。"
        }
    }
}
