import Foundation
import Observation
import BiliMacCore

enum SearchKind: String, CaseIterable, Identifiable { case videos = "视频", users = "用户"; var id: Self { self } }

@MainActor @Observable final class SearchModel {
    struct Results {
        var videos: [Video] = []
        var users: [BiliUser] = []
        var total: Int?
        var page = 0
        var loaded = false
        var loading = false
        var hasMore = false
        var error: String?
        var failedMore = false
    }
    private let api: any SearchServing
    private var task: Task<Void, Never>?
    private var identity = UUID()
    private var results: [SearchKind: Results] = [:]
    private(set) var term = ""
    private(set) var kind: SearchKind = .videos
    var current: Results { results[kind] ?? Results() }
    init(api: any SearchServing) { self.api = api }
    func submit(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        cancel(); term = value; results = [:]; load()
    }
    func select(_ kind: SearchKind) {
        guard kind != self.kind else { return }
        cancel(); self.kind = kind
        if !current.loaded { load() }
    }
    func close() { cancel(); term = ""; results = [:] }
    private func cancel() {
        task?.cancel(); identity = UUID()
        if var old = results[kind] { old.loading = false; results[kind] = old }
    }
    func retry() { load(more: current.failedMore) }
    func load(more: Bool = false) {
        guard !term.isEmpty, !more || (!current.loading && current.hasMore) else { return }
        cancel(); let token = identity, term = term, kind = kind
        var state = current
        let page = more ? state.page + 1 : 1
        state.loading = true; state.error = nil; results[kind] = state
        task = Task {
            do {
                if kind == .videos {
                    let rows = try await api.search(term, page: page)
                    guard token == identity, !Task.isCancelled else { return }
                    let combined = Video.unique((more ? state.videos : []) + rows)
                    if more && combined.count == state.videos.count && !rows.isEmpty { throw ClientError.paginationStalled }
                    state.videos = combined; state.hasMore = !rows.isEmpty
                } else {
                    let response = try await api.searchUsers(term, page: page)
                    guard token == identity, !Task.isCancelled else { return }
                    let combined = BiliUser.unique((more ? state.users : []) + response.items)
                    if more && combined.count == state.users.count && response.hasMore { throw ClientError.paginationStalled }
                    state.users = combined; state.total = response.total; state.hasMore = response.hasMore
                }
                state.page = page; state.loaded = true
            } catch {
                guard token == identity, !Task.isCancelled else { return }
                state.error = error.localizedDescription; state.failedMore = more
            }
            guard token == identity, !Task.isCancelled else { return }
            state.loading = false; results[kind] = state
        }
    }
    func settled() async { await task?.value }
}

struct DemoSearchService: SearchServing {
    func search(_ term: String, page: Int) async throws -> [Video] {
        page == 1 ? DemoData.videos.filter { $0.title.localizedCaseInsensitiveContains(term) || $0.author.localizedCaseInsensitiveContains(term) } : []
    }
    func searchUsers(_ term: String, page: Int) async throws -> UserSearchPage { .init(items: [], total: 0, hasMore: false) }
}
