import Foundation
import Observation
import BiliMacCore

@MainActor @Observable final class CommentsModel {
    let api: any CommentServing
    private(set) var aid = 0
    private(set) var sort: CommentSort = .hot
    private var identity = UUID()
    private var requestIdentity = UUID()
    private var threadIdentity = UUID()
    private(set) var items: [Comment] = []
    private(set) var total = 0
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var hasMore = false
    private var offset: String?
    var error: String?
    private var failedMore = false
    struct Thread {
        var items: [Comment] = []
        var page = 0
        var hasMore = true
        var loading = false
        var error: String?
    }
    private(set) var threads: [Int: Thread] = [:]
    init(api: any CommentServing) { self.api = api }
    func reset(aid: Int = 0, sort: CommentSort = .hot) {
        identity = UUID(); requestIdentity = UUID(); threadIdentity = UUID(); self.aid = aid; self.sort = sort
        items = []; total = 0; loaded = false; loading = false; hasMore = false; offset = nil; error = nil; failedMore = false; threads = [:]
    }
    func open(aid: Int) async {
        guard aid > 0 else { reset(); return }
        if self.aid != aid { reset(aid: aid) }
        if !loaded { await load() }
    }
    func changeSort(_ sort: CommentSort) async {
        guard sort != self.sort else { return }
        reset(aid: aid, sort: sort); await load()
    }
    func load(more: Bool = false) async {
        guard aid > 0, !more || (!loading && hasMore) else { return }
        let session = identity; requestIdentity = UUID(); let token = requestIdentity
        let next = more ? offset : nil
        loading = true; error = nil
        defer { if session == identity && token == requestIdentity { loading = false } }
        do {
            let result = try await api.comments(aid: aid, sort: sort, offset: next)
            guard session == identity, token == requestIdentity, !Task.isCancelled else { return }
            let combined = Comment.unique((more ? items : []) + result.items)
            // Opaque tokens may repeat. Only a page with no new content stalls.
            if more && combined.count == items.count && result.next != nil { throw ClientError.paginationStalled }
            items = combined; total = result.total; offset = result.next; hasMore = result.next != nil; loaded = true
            if !more { threadIdentity = UUID(); threads = [:] }
        } catch {
            if session == identity, token == requestIdentity, !Task.isCancelled { self.error = error.localizedDescription; failedMore = more }
        }
    }
    func retry() async { await load(more: failedMore) }
    func loadThread(_ root: Comment) async {
        var thread = threads[root.id] ?? Thread()
        guard !thread.loading, thread.hasMore else { return }
        let session = identity, list = threadIdentity, next = thread.page + 1
        thread.loading = true; thread.error = nil; threads[root.id] = thread
        do {
            let result = try await api.commentThread(aid: aid, root: root.id, page: next)
            guard session == identity, list == threadIdentity, !Task.isCancelled else { return }
            let combined = Comment.unique(thread.items + result.items)
            if result.hasMore && combined.count == thread.items.count { throw ClientError.paginationStalled }
            thread.items = combined; thread.page = next; thread.hasMore = result.hasMore
        } catch {
            guard session == identity, list == threadIdentity else { return }
            thread.error = error.localizedDescription
        }
        guard session == identity, list == threadIdentity else { return }
        thread.loading = false; threads[root.id] = thread
    }
}
