import Foundation
import Observation
import BiliMacCore

enum SearchKind: String, CaseIterable, Identifiable { case videos = "视频", users = "用户"; var id: Self { self } }

@MainActor @Observable final class SearchModel {
    @MainActor struct Results {
        var videos: [Video] = []
        var rawVideos: [Video] = []
        var users: [BiliUser] = []
        var total: Int?
        var page = 0
        var loaded = false
        var loading = false
        var hasMore = false
        var error: String?
        var failedMore = false
        var scroll = ScrollMemory()
        var limited = false
        var revision = 0
    }
    private let api: any SearchServing
    private var task: Task<Void, Never>?
    private var identity = UUID()
    private var results: [SearchKind: Results] = [:]
    private(set) var term = ""
    private(set) var kind: SearchKind = .videos
    private(set) var options = VideoSearchOptions()
    var scrollOffset: CGFloat {
        get { current.scroll.offset }
        set { guard newValue.isFinite, newValue >= 0 else { return }; current.scroll.offset = newValue }
    }
    var current: Results { results[kind] ?? Results() }
    init(api: any SearchServing) { self.api = api }
    func submit(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 100 else { return }
        cancel(); term = value; results = [:]; load()
    }
    func select(_ kind: SearchKind) {
        guard kind != self.kind else { return }
        cancel(); self.kind = kind
        if !current.loaded { load() }
    }
    func close() { cancel(); term = ""; results = [:] }
    func resetAccount() { cancel(); results = [:]; if !term.isEmpty { load() } }
    func setOptions(_ value: VideoSearchOptions) {
        guard value != options else { return }
        cancel(); options = value; results[.videos] = nil
        if kind == .videos { load() }
    }
    private func cancel() {
        task?.cancel(); identity = UUID()
        if var old = results[kind] { old.loading = false; results[kind] = old }
    }
    func retry() { load(more: current.failedMore) }
    func load(more: Bool = false) {
        guard !term.isEmpty, !more || (!current.loading && current.hasMore) else { return }
        cancel(); let token = identity, term = term, kind = kind, options = options
        var state = current
        let page = more ? state.page + 1 : 1
        state.loading = true; state.error = nil; results[kind] = state
        task = Task {
            do {
                if kind == .videos {
                    let response = try await api.searchVideos(term, page: page, options: options)
                    guard token == identity, !Task.isCancelled else { return }
                    let combined = Video.unique((more ? state.rawVideos : []) + response.items)
                    if more && combined.count == state.rawVideos.count && response.hasMore { throw ClientError.paginationStalled }
                    let bounded = Array(combined.prefix(600))
                    state.rawVideos = bounded
                    if options.order == .smart {
                        let work = Task.detached { ContentRanking.search(bounded, term: term) }
                        state.videos = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
                    } else { state.videos = bounded }
                    state.total = response.total; state.hasMore = response.hasMore && combined.count < 600
                    state.limited = response.hasMore && combined.count >= 600
                } else {
                    let response = try await api.searchUsers(term, page: page)
                    guard token == identity, !Task.isCancelled else { return }
                    let combined = BiliUser.unique((more ? state.users : []) + response.items)
                    if more && combined.count == state.users.count && response.hasMore { throw ClientError.paginationStalled }
                    state.users = combined; state.total = response.total; state.hasMore = response.hasMore
                }
                state.page = page; state.loaded = true; if !more { state.scroll = ScrollMemory(); state.revision += 1 }
            } catch {
                guard token == identity, !Task.isCancelled else { return }
                state.error = error.localizedDescription; state.failedMore = more
            }
            guard token == identity, !Task.isCancelled else { return }
            if more || state.error != nil { state.scroll = current.scroll; state.revision = current.revision }
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
