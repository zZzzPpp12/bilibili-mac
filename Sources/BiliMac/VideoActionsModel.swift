import Foundation
import Observation
import BiliMacCore

/// Retain each video's in-flight/unknown outcome while navigating away and back.
@MainActor @Observable final class InteractionStore {
    private let api: any VideoInteractionServing
    private let favoritesChanged: (Int) -> Void
    private var mid: Int?
    @ObservationIgnored private var models: [Int: VideoActionsModel] = [:]
    init(api: any VideoInteractionServing, favoritesChanged: @escaping (Int) -> Void) { self.api = api; self.favoritesChanged = favoritesChanged }
    func setAccount(_ mid: Int?) {
        models.values.forEach { $0.invalidate() }; models = [:]; self.mid = mid
    }
    func model(for video: Video) -> VideoActionsModel {
        if let existing = models[video.aid] { return existing }
        let model = VideoActionsModel(api: api, mid: mid, aid: video.aid, bvid: video.bvid, favoritesChanged: favoritesChanged)
        models[video.aid] = model; return model
    }
    func favoritesSaved(aid: Int) async { if let model = models[aid] { await model.refresh() } }
}

@MainActor @Observable final class VideoActionsModel {
    enum SpendKind { case coins, triple }
    struct Confirmation: Identifiable {
        let id = UUID()
        let kind: SpendKind
        let before: VideoInteractionState
    }
    private let api: any VideoInteractionServing
    let mid: Int?
    let aid: Int
    let bvid: String
    private let favoritesChanged: (Int) -> Void
    private var identity = UUID()
    private var active = true
    private var readIdentity = UUID()
    private(set) var state: VideoInteractionState?
    private(set) var loading = false
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var confirmation: Confirmation?
    var error: String?
    var notice: String?
    var canAct: Bool { active && mid != nil && aid > 0 && state != nil && !loading && !busy && !needsRefresh }
    var isOwnVideo: Bool { mid != nil && state?.ownerID == mid }
    var coinReason: String? {
        guard let state else { return "请先读取互动状态" }
        if isOwnVideo { return "不能给自己的视频投币" }
        if state.remaining == 0 { return "本视频已投满 \(state.coinLimit) 枚硬币" }
        if state.available == 0 { return "硬币余额不足" }
        return nil
    }
    var tripleReason: String? {
        guard let state else { return "请先读取互动状态" }
        if state.isTriple { return "已完成点赞、投币和收藏" }
        if isOwnVideo { return "自己的视频不能使用投币三连" }
        if state.balance < Double(state.remaining) { return "余额不足以确认三连最多消耗的 \(state.remaining) 枚硬币" }
        return nil
    }
    init(api: any VideoInteractionServing, mid: Int?, aid: Int, bvid: String, favoritesChanged: @escaping (Int) -> Void = { _ in }) {
        self.api = api; self.mid = mid; self.aid = aid; self.bvid = bvid; self.favoritesChanged = favoritesChanged
    }
    func invalidate() {
        active = false; identity = UUID(); readIdentity = UUID(); state = nil; confirmation = nil
        loading = false; busy = false; needsRefresh = false; error = nil; notice = nil
    }
    func ensureLoaded() async { if state == nil && !loading { await refresh() } }
    func refresh() async {
        guard active, let mid, aid > 0, !busy else { return }
        readIdentity = UUID(); let token = readIdentity, scope = identity
        confirmation = nil; loading = true; error = nil
        defer { if scope == identity && token == readIdentity { loading = false } }
        do {
            let value = try await api.interactionState(mid: mid, aid: aid)
            guard scope == identity, token == readIdentity, !Task.isCancelled else { return }
            state = value; needsRefresh = false; notice = nil
        } catch {
            if scope == identity, token == readIdentity, !Task.isCancelled { self.error = error.localizedDescription; needsRefresh = true }
        }
    }
    func toggleLike() async {
        guard canAct, confirmation == nil, let mid, let before = state else { return }
        let scope = identity; busy = true; error = nil; notice = nil
        defer { if scope == identity { busy = false } }
        do {
            try await api.setVideoLike(mid: mid, aid: aid, bvid: bvid, liked: !before.liked)
            guard scope == identity else { return }
            state?.liked = !before.liked; notice = before.liked ? "已取消点赞" : "已点赞"
        } catch { if scope == identity { failure(error) } }
    }
    func present(_ kind: SpendKind) {
        guard canAct, confirmation == nil, let state else { return }
        guard (kind == .coins ? coinReason : tripleReason) == nil else { return }
        confirmation = Confirmation(kind: kind, before: state); error = nil; notice = nil
    }
    func cancelConfirmation() { if !busy { confirmation = nil } }
    /// A confirmation is bound to one account/video/snapshot. Recheck before spending;
    /// if anything changed, the user reviews a new confirmation instead of sending.
    func confirm(id: UUID, amount: Int = 1, alsoLike: Bool = false) async {
        guard canAct, let mid, let proposal = confirmation, proposal.id == id, proposal.before == state else { return }
        if proposal.kind == .coins {
            guard (1...2).contains(amount), amount <= proposal.before.available, !isOwnVideo else { error = ClientError.invalidCoinAmount.localizedDescription; return }
        } else { guard tripleReason == nil else { return } }
        let scope = identity; busy = true; error = nil; notice = nil
        defer { if scope == identity { busy = false; confirmation = nil } }
        let fresh: VideoInteractionState
        do {
            fresh = try await api.interactionState(mid: mid, aid: aid)
        } catch { if scope == identity { failure(error, beforeWrite: true) }; return }
        guard scope == identity else { return }
        guard fresh == proposal.before else {
            state = fresh; notice = "余额或互动状态已变化，请核对后重新确认。"; return
        }
        do {
            var updated = fresh
            if proposal.kind == .coins {
                let receipt = try await api.addCoins(mid: mid, aid: aid, bvid: bvid, amount: amount, alsoLike: alsoLike)
                guard scope == identity else { return }
                updated.coins += amount; updated.balance -= Double(amount); updated.liked = fresh.liked || receipt.liked
                state = updated
                notice = "已投 \(amount) 枚硬币" + (alsoLike && !updated.liked ? "；附加点赞未成功，可刷新后单独点赞。" : "")
            } else {
                let receipt = try await api.triple(mid: mid, aid: aid, bvid: bvid)
                guard scope == identity else { return }
                guard !receipt.coined || (receipt.coins > 0 && receipt.coins <= fresh.remaining) else { throw ClientError.writeUncertain }
                updated.liked = fresh.liked || receipt.liked; updated.favorited = fresh.favorited || receipt.favorited
                if receipt.coined { updated.coins += receipt.coins; updated.balance -= Double(receipt.coins) }
                state = updated
                if receipt.favorited { favoritesChanged(mid) }
                if updated.isTriple { notice = "已完成点赞、投币和收藏" }
                else {
                    needsRefresh = true
                    notice = "三连仅完成部分操作；已确认的结果已保留，请先刷新核对。"
                    error = "点赞\(updated.liked ? "已确认" : "未确认") · 投币 \(updated.coins) 枚 · 收藏\(updated.favorited ? "已确认" : "未确认")"
                }
            }
        } catch { if scope == identity { failure(error) } }
    }
    private func failure(_ error: any Error, beforeWrite: Bool = false) {
        self.error = error.localizedDescription; needsRefresh = true
        if beforeWrite { notice = "状态核对失败，本次没有提交投币或三连。" }
        else if case ClientError.writeUncertain = error { notice = "结果尚未确认。请先刷新核对，勿重复提交。" }
        else { notice = "请先刷新互动状态，再决定下一步操作。" }
    }
}
