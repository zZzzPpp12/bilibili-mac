import Foundation
import Observation
import BiliMacCore

@MainActor @Observable final class DiscoveryModel {
    struct Key: Hashable { var source: DiscoverySource; var region: ContentRegion }
    @MainActor struct Page {
        var videos: [Video] = []
        var page = 0
        var loaded = false
        var loading = false
        var hasMore = false
        var error: String?
        var failedMore = false
        var scroll = ScrollMemory()
        var revision = 0
    }
    private let api: any DiscoveryServing
    private var task: Task<Void, Never>?
    private var rankingTask: Task<Void, Never>?
    private var rankingID = UUID()
    private var generation = UUID()
    private var pages: [Key: Page] = [:]
    private(set) var key = Key(source: .recommended, region: .all)
    private(set) var order: DiscoveryOrder = .official
    private(set) var duration: VideoDuration = .any
    private(set) var published: PublicationWindow = .any
    private(set) var useHistory = false
    private var history: [WatchRecord] = []
    private(set) var displayed: [Video] = []
    var current: Page { pages[key] ?? Page() }
    var scrollOffset: CGFloat {
        get { current.scroll.offset }
        set { guard newValue.isFinite, newValue >= 0 else { return }; current.scroll.offset = newValue }
    }
    init(api: any DiscoveryServing) { self.api = api }
    func select(_ source: DiscoverySource, region: ContentRegion? = nil) {
        cancel()
        key = Key(source: source, region: source == .regions ? region ?? (key.source == .regions ? key.region : .technology) : .all)
        rebuild(); if !current.loaded { load() }
    }
    func setOrder(_ value: DiscoveryOrder) { order = value; rebuild() }
    func setDuration(_ value: VideoDuration) { duration = value; resetPosition(); rebuild() }
    func setPublication(_ value: PublicationWindow) { published = value; resetPosition(); rebuild() }
    private func resetPosition() { var value = current; value.scroll = ScrollMemory(); value.revision += 1; pages[key] = value }
    func setUseHistory(_ value: Bool) { useHistory = value; rebuild() }
    func setHistory(_ value: [WatchRecord]) { history = Array(value.prefix(50)); if useHistory { rebuild() } }
    private func rebuild() {
        let now = Date()
        let candidates = current.videos.filter { duration.matches($0.duration) && published.matches($0.publishedAt, now: now) }
        rankingTask?.cancel(); rankingID = UUID()
        guard order != .official else { displayed = candidates; return }
        let token = rankingID, order = order, records = useHistory ? history : []
        displayed = candidates
        rankingTask = Task {
            let work = Task.detached { ContentRanking.discovery(candidates, order: order, history: records, now: now) }
            let sorted = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard token == rankingID, !Task.isCancelled else { return }
            displayed = sorted
        }
    }
    func suspend() { cancel() }
    func reset() { cancel(); rankingTask?.cancel(); rankingID = UUID(); pages = [:]; history = []; displayed = [] }
    private func cancel() {
        task?.cancel(); generation = UUID()
        var value = current; value.loading = false; pages[key] = value
    }
    func retry() { load(more: current.failedMore) }
    func load(more: Bool = false) {
        guard !more || (!current.loading && current.hasMore) else { return }
        cancel(); let token = generation, key = key
        var state = current; let page = more ? state.page + 1 : 1
        state.loading = true; state.error = nil; pages[key] = state
        task = Task {
            do {
                let result = try await api.discovery(source: key.source, region: key.region, page: page)
                guard token == generation, !Task.isCancelled else { return }
                let combined = Video.unique((more ? state.videos : []) + result.items)
                if more && combined.count == state.videos.count && result.hasMore { throw ClientError.paginationStalled }
                state.videos = Array(combined.prefix(600)); state.hasMore = result.hasMore && combined.count < 600
                state.page = page; state.loaded = true; if !more { state.scroll = ScrollMemory(); state.revision += 1 }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                state.error = error.localizedDescription; state.failedMore = more
            }
            guard token == generation, !Task.isCancelled else { return }
            if more || state.error != nil { state.scroll = current.scroll; state.revision = current.revision }
            state.loading = false; pages[key] = state; rebuild()
        }
    }
    func settled() async { await task?.value; await rankingTask?.value }
}

struct DemoDiscoveryService: DiscoveryServing {
    func discovery(source: DiscoverySource, region: ContentRegion, page: Int) async throws -> VideoSearchPage {
        .init(items: page == 1 ? DemoData.videos : [], total: DemoData.videos.count, hasMore: false)
    }
}
