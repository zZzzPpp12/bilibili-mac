import SwiftUI
import BiliMacCore

enum AppSettings {
    static let domain = "dev.zzpp.BiliMac"
    static let defaults = makeDefaults(bundleIdentifier: Bundle.main.bundleIdentifier)
    // The application's own domain already belongs to .standard. Creating it
    // again as a suite can return nil in a packaged app, unlike an XCTest host.
    static func makeDefaults(bundleIdentifier: String?, standard: UserDefaults = .standard,
                             suiteFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) -> UserDefaults {
        guard bundleIdentifier != domain else { return standard }
        return suiteFactory(domain) ?? standard
    }
    static func register() { defaults.register(defaults: ["appearance":"system", "autoPlay":true, "rememberPosition":true, "danmakuEnabled":true, "danmakuOpacity":0.8, "playbackRate":1.0]) }
}
enum Destination: String, CaseIterable, Identifiable {
    case recommended = "推荐", popular = "热门", history = "观看记录"
    var id: Self { self }
    var icon: String { switch self { case .recommended: "sparkles"; case .popular: "flame"; case .history: "clock.arrow.circlepath" } }
    var subtitle: String { switch self { case .recommended: "发现值得停留的好内容"; case .popular: "看看大家此刻都在看什么"; case .history: "每一次好奇，都有迹可循" } }
}
@MainActor @Observable final class AppStore {
    let client = BilibiliClient()
    let player = PlayerController()
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    var destination: Destination = .recommended
    var query = ""
    var activeSearch = ""
    var videos: [Video] = []
    var history: [WatchRecord] = []
    var account: Account?
    var loading = false
    var hasMore = true
    var error: String?
    var accountMessage: String?
    var showPlayer = false
    var showLogin = false
    var searchFocus = 0
    private var page = 1
    private var feedTask: Task<Void, Never>?
    private var feedGeneration = UUID()
    private var accountGeneration = UUID()
    private var snapshots: [String: ([Video], Int, Bool)] = [:]
    private var historyRepository: HistoryRepository { HistoryRepository(file: isDemo ? FileManager.default.temporaryDirectory.appendingPathComponent("BiliMac-demo-history.json") : nil) }
    var title: String { activeSearch.isEmpty ? destination.rawValue : "搜索结果" }
    var subtitle: String { activeSearch.isEmpty ? destination.subtitle : "关于「\(activeSearch)」的内容" }
    init() {
        AppSettings.register()
        player.onProgress = { [weak self] video, cid, position in self?.record(video: video, cid: cid, position: position) }
    }
    func start() async {
        history = await Task.detached { [historyRepository] in historyRepository.load() }.value
        if isDemo { videos = DemoData.videos; hasMore = false; return }
        let identity = accountGeneration
        let cookies = await Task.detached { CredentialVault.load() }.value
        guard identity == accountGeneration else { return }
        await client.setCookies(cookies)
        reload()
        do { account = try await client.account() }
        catch { if identity == accountGeneration, !cookies.isEmpty { accountMessage = "账号暂未验证，可重新检查；本机登录已保留。" } }
    }
    func select(_ next: Destination) {
        if activeSearch.isEmpty && !videos.isEmpty { snapshots[destination.rawValue] = (videos, page, hasMore) }
        feedTask?.cancel(); feedGeneration = UUID(); loading = false
        player.saveProgress(); showPlayer = false; destination = next; activeSearch = ""; query = ""; error = nil
        guard next != .history else { return }
        if isDemo { videos = DemoData.videos; hasMore = false; return }
        if let snapshot = snapshots[next.rawValue] { (videos, page, hasMore) = snapshot }
        else { videos = []; reload() }
    }
    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if let bvid = VideoInput.bvid(term) { open(bvid); return }
        player.saveProgress(); showPlayer = false; activeSearch = term; videos = []; reload()
    }
    func reload() { fetch(more: false) }
    func loadMore() { guard !loading, hasMore else { return }; fetch(more: true) }
    private func fetch(more: Bool) {
        feedTask?.cancel(); feedGeneration = UUID(); let identity = feedGeneration
        if isDemo { videos = activeSearch.isEmpty ? DemoData.videos : DemoData.videos.filter { $0.title.localizedCaseInsensitiveContains(activeSearch) }; loading = false; hasMore = false; return }
        let next = more ? page + 1 : 1, term = activeSearch, recommended = destination == .recommended
        loading = true; error = nil
        feedTask = Task {
            do {
                let rows = try await (term.isEmpty ? client.feed(recommended: recommended, page: next) : client.search(term, page: next))
                guard identity == feedGeneration, !Task.isCancelled else { return }
                videos = Video.unique((more ? videos : []) + rows); page = next; hasMore = !rows.isEmpty; loading = false
            } catch {
                guard identity == feedGeneration, !Task.isCancelled else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    func open(_ bvid: String) {
        player.saveProgress(); showPlayer = true
        let previous = AppSettings.defaults.bool(forKey: "rememberPosition") ? history.first { $0.id == bvid } : nil
        if isDemo, let video = DemoData.videos.first(where: { $0.bvid == bvid }) { player.showDemo(video); return }
        player.open(bvid, client: client, record: previous)
    }
    func record(video: Video, cid: Int, position: Double) {
        guard position.isFinite, position >= 0, cid > 0 else { return }
        let positions = history.first { $0.id == video.id }?.positions ?? [:]
        history.removeAll { $0.id == video.id }
        history.insert(WatchRecord(video: video, cid: cid, position: position, positions: positions), at: 0)
        history = Array(history.prefix(200))
        persistHistory()
    }
    func persistHistory() {
        do { try historyRepository.save(history) } catch { accountMessage = "观看记录保存失败：\(error.localizedDescription)" }
    }
    func clearHistory() { history = []; persistHistory() }
    func closePlayer() { player.stop(); showPlayer = false }
    func leavePlayer() { player.saveProgress(); showPlayer = false }
    func completeLogin(_ cookies: [String: String]) async throws {
        let identity = accountGeneration
        try await Task.detached { try CredentialVault.save(cookies) }.value
        guard identity == accountGeneration, !Task.isCancelled else { throw CancellationError() }
        await client.setCookies(cookies)
        showLogin = false; snapshots = [:]; reload()
        do { let value = try await client.account(); if identity == accountGeneration { account = value; accountMessage = nil } }
        catch { if identity == accountGeneration { accountMessage = "登录已保存，账号信息暂不可用，请稍后检查。" } }
    }
    func checkAccount() async {
        let identity = accountGeneration
        do { let result = try await client.account(); guard identity == accountGeneration else { return }; account = result; accountMessage = result == nil ? "当前未登录，可扫码登录。" : nil }
        catch { if identity == accountGeneration { accountMessage = error.localizedDescription } }
    }
    func logout() async {
        do { try await Task.detached { try CredentialVault.clear() }.value }
        catch { accountMessage = "无法移除本机登录，请重试。"; return }
        accountGeneration = UUID(); await client.setCookies([:]); account = nil; snapshots = [:]; accountMessage = nil; reload()
    }
}

enum DemoData {
    static let videos: [Video] = [
        ("把时间交给山野，找回生活的节奏", "山间来信", 843, 249_000),
        ("用 SwiftUI，做一个让自己喜欢的应用", "代码与咖啡", 1265, 182_000),
        ("东京散步｜一场没有目的地的旅行", "游牧日记", 625, 381_000),
        ("深夜书桌：陪你专注的 30 分钟", "声音收藏家", 1800, 92_000),
        ("为什么我们总是仰望星空？", "宇宙观察室", 1360, 753_000),
        ("一口锅，也能做出好吃的晚餐", "今天吃什么", 491, 624_000),
        ("胶片里的秋天，和一点点好天气", "慢速摄影", 725, 128_000),
        ("从零整理一个舒服的工作空间", "桌面研究所", 1068, 419_000),
        ("城市醒来之前，去听一场海浪", "周末出走", 903, 205_000)
    ].enumerated().map { index, row in Video(bvid: "BV1xx411c7m\(index)", title: row.0, author: row.1, duration: row.2, views: row.3) }
}
