import Foundation
import Observation
import BiliMacCore

@MainActor @Observable final class UserProfileStore {
    private let api: any UserServing
    private var account: Int?
    @ObservationIgnored private var models: [Int: UserProfileModel] = [:]
    init(api: any UserServing) { self.api = api }
    func setAccount(_ account: Int?) { models.values.forEach { $0.invalidate() }; models = [:]; self.account = account }
    func model(mid: Int) -> UserProfileModel {
        if let model = models[mid] { return model }
        let model = UserProfileModel(api: api, mid: mid, account: account); models[mid] = model; return model
    }
}

@MainActor @Observable final class UserProfileModel {
    let mid: Int
    let account: Int?
    private let api: any UserServing
    private var active = true
    private var identity = UUID()
    private var profileRequest = UUID()
    private var videoRequest = UUID()
    private var page = 0
    private var failedMore = false
    private(set) var profile: UserProfile?
    private(set) var videos: [Video] = []
    private(set) var total: Int?
    private(set) var profileLoading = false
    private(set) var videosLoading = false
    private(set) var videosLoaded = false
    private(set) var hasMore = false
    private(set) var order: UserVideoOrder = .latest
    private(set) var followBusy = false
    private(set) var needsRefresh = false
    private(set) var profileError: String?
    private(set) var videosError: String?
    private(set) var followError: String?
    private(set) var notice: String?
    var isSelf: Bool { account == mid }
    var canFollow: Bool { active && (account ?? 0) > 0 && !isSelf && profile?.followed != nil && !profileLoading && !followBusy && !needsRefresh }
    var officialURL: URL { URL(string: "https://space.bilibili.com/\(mid)/")! }
    init(api: any UserServing, mid: Int, account: Int?) { self.api = api; self.mid = mid; self.account = account }
    func invalidate() {
        active = false; identity = UUID(); profileRequest = UUID(); videoRequest = UUID()
        profile = nil; videos = []; total = nil; page = 0; hasMore = false; profileLoading = false; videosLoading = false; videosLoaded = false
        followBusy = false; needsRefresh = false; profileError = nil; videosError = nil; followError = nil; notice = nil
    }
    func ensureLoaded() async {
        let needProfile = profile == nil && !profileLoading, needVideos = !videosLoaded && !videosLoading
        async let details: Void = needProfile ? refreshProfile() : ()
        async let uploads: Void = needVideos ? loadVideos() : ()
        _ = await (details, uploads)
    }
    func refreshProfile() async {
        guard active, mid > 0, !followBusy else { return }
        profileRequest = UUID(); let request = profileRequest, token = identity
        profileLoading = true; profileError = nil
        defer { if token == identity, request == profileRequest { profileLoading = false } }
        do {
            let value = try await api.userProfile(mid: mid)
            guard token == identity, request == profileRequest, !Task.isCancelled else { return }
            guard value.user.mid == mid else { throw ClientError.invalidResponse }
            profile = value
            if account == nil || value.followed != nil { needsRefresh = false; followError = nil; notice = nil }
        } catch { if token == identity, request == profileRequest, !Task.isCancelled { profileError = error.localizedDescription } }
    }
    func changeOrder(_ order: UserVideoOrder) async {
        guard active, self.order != order else { return }
        self.order = order; videoRequest = UUID(); videos = []; total = nil; videosLoaded = false; page = 0
        await loadVideos()
    }
    func loadVideos(more: Bool = false) async {
        guard active, mid > 0, !more || (!videosLoading && hasMore) else { return }
        videoRequest = UUID(); let request = videoRequest, token = identity, next = more ? page + 1 : 1, order = order
        videosLoading = true; videosError = nil
        defer { if token == identity, request == videoRequest { videosLoading = false } }
        do {
            let value = try await api.userVideos(mid: mid, page: next, order: order)
            guard token == identity, request == videoRequest, !Task.isCancelled else { return }
            let combined = Video.unique((more ? videos : []) + value.items)
            if more && combined.count == videos.count && value.hasMore { throw ClientError.paginationStalled }
            videos = combined; total = value.total; page = next; hasMore = value.hasMore; videosLoaded = true
        } catch { if token == identity, request == videoRequest, !Task.isCancelled { videosError = error.localizedDescription; failedMore = more } }
    }
    func retryVideos() async { await loadVideos(more: failedMore) }
    func toggleFollow() async {
        guard canFollow, let account, let before = profile?.followed else { return }
        let token = identity; followBusy = true; followError = nil; notice = nil
        defer { if token == identity { followBusy = false } }
        do {
            try await api.setFollowing(account: account, target: mid, followed: !before)
            guard token == identity else { return }
            profile?.followed = !before; notice = before ? "已取消关注" : "已关注"
        } catch {
            guard token == identity else { return }
            followError = error.localizedDescription; needsRefresh = true
            notice = "请先刷新资料核对关注状态，不会自动重发请求。"
        }
    }
}
