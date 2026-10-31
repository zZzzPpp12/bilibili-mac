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
    case recommended = "推荐", popular = "热门", regions = "分区发现", favorites = "我的收藏", later = "稍后再看", history = "观看记录"
    var id: Self { self }
    var icon: String { switch self { case .recommended: "sparkles"; case .popular: "flame"; case .regions: "square.grid.2x2"; case .favorites: "star"; case .later: "clock.badge.checkmark"; case .history: "clock.arrow.circlepath" } }
    var subtitle: String { switch self { case .recommended: "发现值得停留的好内容"; case .popular: "看看大家此刻都在看什么"; case .regions: "按兴趣探索 B 站分区榜单"; case .favorites: "把喜欢的内容，放进自己的收藏夹"; case .later: "留给有空的自己"; case .history: "每一次好奇，都有迹可循" } }
}
@MainActor @Observable final class AppStore {
    let client: BilibiliClient
    let library: LibraryModel
    let comments: CommentsModel
    let commentActions: CommentActionsStore
    let searches: SearchModel
    let searchAssistance: SearchAssistanceModel
    let discovery: DiscoveryModel
    let profiles: UserProfileStore
    let interactions: InteractionStore
    let player = PlayerController()
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    var destination: Destination = .recommended
    var query = ""
    var activeSearch: String { searches.term }
    struct ProfileRoute: Identifiable {
        let id = UUID()
        let mid: Int
        let returnRecord: WatchRecord?
        let returnPlaying: Bool
    }
    var profilePath: [ProfileRoute] = []
    var history: [WatchRecord] = []
    var account: Account? {
        didSet {
            if oldValue?.id != account?.id {
                searchAssistance.setAccount(account?.id); searches.resetAccount(); discovery.reset()
                library.setAccount(account?.id); comments.reset(); interactions.setAccount(account?.id); commentActions.setAccount(account?.id); profiles.setAccount(account?.id)
                if [.recommended, .popular, .regions].contains(destination), activeSearch.isEmpty { reload() }
            }
        }
    }
    var loading: Bool { discovery.current.loading }
    var accountMessage: String?
    var showPlayer = false
    var showLogin = false
    var searchFocus = 0
    private var accountGeneration = UUID()
    private var historyRepository: HistoryRepository { HistoryRepository(file: isDemo ? FileManager.default.temporaryDirectory.appendingPathComponent("BiliMac-demo-history.json") : nil) }
    var title: String { activeSearch.isEmpty ? destination.rawValue : "搜索结果" }
    var subtitle: String { activeSearch.isEmpty ? destination.subtitle : "关于「\(activeSearch)」的内容" }
    init(client: BilibiliClient = BilibiliClient(), searchHistoryDefaults: UserDefaults? = nil) {
        self.client = client
        searches = SearchModel(api: ProcessInfo.processInfo.arguments.contains("--demo") ? DemoSearchService() : client)
        searchAssistance = SearchAssistanceModel(api: ProcessInfo.processInfo.arguments.contains("--demo") ? DemoSuggestService() : client,
                                                defaults: ProcessInfo.processInfo.arguments.contains("--demo") ? nil : searchHistoryDefaults)
        discovery = DiscoveryModel(api: ProcessInfo.processInfo.arguments.contains("--demo") ? DemoDiscoveryService() : client)
        profiles = UserProfileStore(api: client)
        let library = LibraryModel(api: client); self.library = library; comments = CommentsModel(api: client)
        commentActions = CommentActionsStore(api: client)
        interactions = InteractionStore(api: client) { [weak library] mid in
            Task {
                guard let library, library.mid == mid else { return }
                await library.loadFolders()
                guard library.mid == mid else { return }
                if library.loaded { await library.loadFavorites() }
            }
        }
        AppSettings.register()
        player.onProgress = { [weak self] video, cid, position in self?.record(video: video, cid: cid, position: position) }
    }
    func start() async {
        history = await Task.detached { [historyRepository] in historyRepository.load() }.value
        if isDemo { discovery.load(); return }
        let identity = accountGeneration
        let cookies = await Task.detached { CredentialVault.load() }.value
        guard identity == accountGeneration else { return }
        await client.setCookies(cookies)
        reload()
        do { let result = try await client.account(); if identity == accountGeneration { account = result } }
        catch { if identity == accountGeneration, !cookies.isEmpty { accountMessage = "账号暂未验证，可重新检查；本机登录已保留。" } }
    }
    func select(_ next: Destination) {
        discovery.suspend(); searchAssistance.dismiss()
        player.saveProgress(); showPlayer = false; destination = next; searches.close(); profilePath = []; query = ""
        guard [.recommended, .popular, .regions].contains(next) else { return }
        discovery.setHistory(history)
        discovery.select(next == .recommended ? .recommended : next == .popular ? .popular : .regions)
    }
    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard term.utf16.count <= 100 else { accountMessage = "搜索词最多 100 个字符。"; return }
        searchAssistance.dismiss()
        if let bvid = VideoInput.bvid(term) { open(bvid); return }
        if let mid = UserInput.mid(term) { openProfile(mid); return }
        discovery.suspend(); searchAssistance.record(term)
        player.saveProgress(); showPlayer = false; profilePath = []; searches.submit(term)
    }
    func reload() {
        if !showPlayer, let route = profilePath.last {
            let profile = profiles.model(mid: route.mid)
            Task { await profile.refreshProfile(); await profile.loadVideos() }; return
        }
        if !activeSearch.isEmpty { searches.load(); return }
        if activeSearch.isEmpty {
            if destination == .history { return }
            if destination == .favorites {
                if !isDemo { Task { await library.loadFolders(); await library.loadFavorites() } }; return
            }
            if destination == .later { if !isDemo { Task { await library.loadLater() } }; return }
        }
        discovery.setHistory(history); discovery.load()
    }
    func loadMore() { discovery.load(more: true) }
    func open(_ bvid: String) {
        comments.reset()
        player.saveProgress(); showPlayer = true
        let previous = AppSettings.defaults.bool(forKey: "rememberPosition") ? history.first { $0.id == bvid } : nil
        if isDemo, let video = DemoData.videos.first(where: { $0.bvid == bvid }) { player.showDemo(video); return }
        player.open(bvid, client: client, record: previous)
    }
    func openProfile(_ mid: Int) {
        guard mid > 0 else { return }
        if isDemo { accountMessage = "演示模式不请求用户主页，请正常启动后使用。"; return }
        if !showPlayer, profilePath.last?.mid == mid { return }
        player.saveProgress()
        let record: WatchRecord? = showPlayer ? player.detail.flatMap { detail in
            guard player.cid > 0 else { return nil }
            return WatchRecord(video: detail.video, cid: player.cid, position: player.position,
                               positions: history.first(where: { $0.id == detail.video.id })?.positions ?? [:])
        } : nil
        profilePath.append(ProfileRoute(mid: mid, returnRecord: record, returnPlaying: player.intendedPlaying))
        showPlayer = false
    }
    func backFromProfile() {
        guard let route = profilePath.popLast() else { return }
        guard let record = route.returnRecord, player.isOpen else { return }
        if player.detail?.video.bvid != record.video.bvid || player.cid != record.cid {
            player.saveProgress(); comments.reset()
            player.open(record.video.bvid, client: client, record: record, playing: route.returnPlaying)
        }
        showPlayer = true
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
    func clearHistory() { history = []; discovery.setHistory([]); persistHistory() }
    func closePlayer() { player.stop(); showPlayer = false }
    func leavePlayer() { player.saveProgress(); discovery.setHistory(history); showPlayer = false }
    func completeLogin(_ cookies: [String: String]) async throws {
        accountGeneration = UUID(); let identity = accountGeneration
        try await Task.detached { try CredentialVault.save(cookies) }.value
        guard identity == accountGeneration, !Task.isCancelled else { throw CancellationError() }
        await client.setCookies(cookies)
        guard identity == accountGeneration else { throw CancellationError() }
        library.setAccount(nil); comments.reset(); interactions.setAccount(nil); commentActions.setAccount(nil); profiles.setAccount(nil)
        showLogin = false; discovery.reset(); searches.resetAccount(); searchAssistance.dismiss(); reload()
        do {
            let value = try await client.account()
            if identity == accountGeneration { account = value; library.setAccount(value?.id); interactions.setAccount(value?.id); commentActions.setAccount(value?.id); profiles.setAccount(value?.id); accountMessage = nil }
        }
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
        accountGeneration = UUID(); await client.setCookies([:]); account = nil; discovery.reset(); searches.resetAccount(); accountMessage = nil; reload()
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
