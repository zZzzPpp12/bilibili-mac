import Foundation
import Testing
import BiliMacCore
@testable import BiliMac

@MainActor private final class UserStub: SearchServing, UserServing {
    var videoSearch: ((String, Int) async throws -> [Video])?
    var userSearch: ((String, Int) async throws -> UserSearchPage)?
    var profileResult: (() async throws -> UserProfile)?
    var uploads: ((Int, UserVideoOrder) async throws -> UserVideoPage)?
    var followResult: (() async throws -> Void)?
    var searches: [String] = []
    var pages: [Int] = []
    var writes: [Bool] = []
    func search(_ term: String, page: Int) async throws -> [Video] {
        searches.append("video:\(term):\(page)"); return try await videoSearch?(term, page) ?? []
    }
    func searchUsers(_ term: String, page: Int) async throws -> UserSearchPage {
        searches.append("user:\(term):\(page)"); return try await userSearch?(term, page) ?? .init(items: [], total: 0, hasMore: false)
    }
    func userProfile(mid: Int) async throws -> UserProfile {
        try await profileResult?() ?? .init(user: .init(mid: mid, name: "测试 UP"), followed: false)
    }
    func userVideos(mid: Int, page: Int, order: UserVideoOrder) async throws -> UserVideoPage {
        pages.append(page); return try await uploads?(page, order) ?? .init(items: [], total: 0, hasMore: false)
    }
    func setFollowing(account: Int, target: Int, followed: Bool) async throws {
        writes.append(followed); try await followResult?()
    }
}

@Suite @MainActor struct UserModelTests {
    private let video = Video(bvid: "BV1xx411c7mD", title: "测试视频", author: "测试 UP", duration: 62, authorID: 123)
    private let user = BiliUser(mid: 123, name: "测试 UP")
    private func until(_ predicate: () -> Bool) async { for _ in 0..<1_000 { if predicate() { return }; await Task.yield() } }

    @Test func categoriesCacheTheirOwnPagesAndNewTermClearsBoth() async {
        let api = UserStub(); let model = SearchModel(api: api)
        api.videoSearch = { _, _ in [video] }
        api.userSearch = { _, _ in .init(items: [user], total: 1, hasMore: false) }
        model.submit(" UP "); await model.settled()
        #expect(model.term == "UP"); #expect(model.current.videos == [video])
        model.select(.users); await model.settled(); #expect(model.current.users == [user]); #expect(!model.current.hasMore)
        model.select(.videos); #expect(model.current.videos == [video]); #expect(api.searches.count == 2)
        model.submit("另一个"); #expect(model.current.videos.isEmpty); await model.settled()
        model.select(.users); await model.settled(); #expect(api.searches.last == "user:另一个:1")
    }
    @Test func newKeywordRejectsAnUncancelableLateSearch() async throws {
        let api = UserStub(); let model = SearchModel(api: api)
        var waiting: CheckedContinuation<[Video], any Error>?
        api.videoSearch = { _, _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        model.submit("旧词"); await until { waiting != nil }; let old = try #require(waiting)
        api.videoSearch = { term, _ in #expect(term == "新词"); return [] }
        model.submit("新词"); await model.settled(); old.resume(returning: [video]); await Task.yield()
        #expect(model.current.videos.isEmpty); #expect(model.current.loaded); #expect(!model.current.loading)
    }
    @Test func categorySwitchDropsLateResponseAndCloseDoesNotRepopulate() async throws {
        let api = UserStub(); let model = SearchModel(api: api)
        var waiting: CheckedContinuation<[Video], any Error>?
        api.videoSearch = { _, _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        model.submit("UP"); await until { waiting != nil }; let old = try #require(waiting)
        model.select(.users); await model.settled(); old.resume(returning: [video]); await Task.yield()
        #expect(model.kind == .users); #expect(model.current.users.isEmpty)
        model.close(); #expect(model.term.isEmpty); #expect(!model.current.loaded)
    }
    @Test func userPaginationUsesServerEndAndRetriesFailedPageWithoutLosingCards() async {
        let api = UserStub(); let model = SearchModel(api: api)
        api.userSearch = { _, page in if page == 1 { return .init(items:[user,user], total:2, hasMore:true) }; throw URLError(.timedOut) }
        model.select(.users); model.submit("UP"); await model.settled()
        #expect(model.current.users.count == 1)
        model.load(more:true); await model.settled(); #expect(model.current.error != nil); #expect(model.current.page == 1)
        api.userSearch = { _, page in #expect(page == 2); return .init(items:[.init(mid:456,name:"另一个")],total:2,hasMore:false) }
        model.retry(); await model.settled(); #expect(model.current.users.map(\.mid) == [123,456]); #expect(!model.current.hasMore)
        #expect(api.searches == ["user:UP:1","user:UP:2","user:UP:2"])
    }
    @Test func duplicatePageAndVerificationNeverBecomeEmptySuccess() async {
        let api = UserStub(); let model = SearchModel(api: api)
        api.userSearch = { _, _ in .init(items:[user],total:99,hasMore:true) }
        model.select(.users); model.submit("UP"); await model.settled()
        model.load(more:true); await model.settled(); #expect(model.current.error != nil); #expect(model.current.page == 1)
        api.userSearch = { _, _ in throw ClientError.server(-352,"官方验证") }
        model.submit("另一个"); await model.settled(); #expect(!model.current.loaded); #expect(model.current.error != nil)
        #expect(api.searches.count == 3)
    }
    @Test func refreshRetryStartsAtPageOne() async {
        let api = UserStub(); let model = SearchModel(api: api)
        api.videoSearch = { _, _ in [video] }; model.submit("UP"); await model.settled()
        api.videoSearch = { _, _ in throw URLError(.timedOut) }; model.load(); await model.settled()
        #expect(model.current.videos == [video])
        api.videoSearch = { _, page in #expect(page == 1); return [] }; model.retry(); await model.settled()
        #expect(model.current.videos.isEmpty); #expect(!model.current.hasMore)
    }
    @Test func profileAndUploadsFailIndependentlyAndRetrySeparately() async {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:nil)
        api.uploads = { _, _ in throw URLError(.timedOut) }; await model.ensureLoaded()
        #expect(model.profile?.user.mid == 123); #expect(model.videosError != nil); #expect(!model.videosLoaded)
        api.uploads = { _, _ in .init(items:[video],total:1,hasMore:false) }; await model.retryVideos()
        api.profileResult = { throw URLError(.timedOut) }; await model.refreshProfile()
        #expect(model.profile != nil); #expect(model.profileError != nil); #expect(model.videos == [video]); #expect(!model.videosLoading)
    }
    @Test func uploadsRetrySamePageAndRejectStalledPagination() async {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:nil)
        api.uploads = { _, _ in .init(items:[video],total:60,hasMore:true) }
        await model.loadVideos(); await model.loadVideos(more:true)
        #expect(model.videosError != nil); #expect(model.videos == [video])
        api.uploads = { page, _ in #expect(page == 2); return .init(items:[],total:1,hasMore:false) }
        await model.retryVideos(); #expect(!model.hasMore); #expect(api.pages == [1,2,2])
    }
    @Test func sortingDiscardsLateUploadsAndRetainsProfile() async throws {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:nil)
        await model.refreshProfile()
        var waiting: CheckedContinuation<UserVideoPage, any Error>?
        api.uploads = { _, _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        let task = Task { await model.loadVideos() }; await until { waiting != nil }; let old = try #require(waiting)
        api.uploads = { page, order in #expect(page == 1); #expect(order == .views); return .init(items:[],total:0,hasMore:false) }
        await model.changeOrder(.views); old.resume(returning:.init(items:[video],total:30,hasMore:true)); await task.value
        #expect(model.videos.isEmpty); #expect(model.profile != nil); #expect(model.order == .views); #expect(!model.hasMore)
    }
    @Test func guestSelfAndUnknownRelationshipCannotWrite() async {
        let api = UserStub()
        for account in [nil,123] as [Int?] {
            let model = UserProfileModel(api:api,mid:123,account:account); await model.ensureLoaded()
            #expect(!model.canFollow); await model.toggleFollow()
        }
        api.profileResult = { .init(user:user) }
        let unknown = UserProfileModel(api:api,mid:123,account:10); await unknown.refreshProfile(); await unknown.toggleFollow()
        #expect(!unknown.canFollow); #expect(api.writes.isEmpty)
    }
    @Test func followWaitsForReceiptAndDoubleClickSendsOnce() async throws {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:10); await model.refreshProfile()
        var waiting: CheckedContinuation<Void, any Error>?
        api.followResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let task = Task { await model.toggleFollow() }; await until { waiting != nil }; let receipt = try #require(waiting)
        #expect(model.profile?.followed == false); #expect(model.followBusy)
        await model.toggleFollow(); #expect(api.writes == [true])
        receipt.resume(); await task.value; #expect(model.profile?.followed == true); #expect(model.notice == "已关注")
        api.followResult = nil; await model.toggleFollow(); #expect(api.writes == [true,false]); #expect(model.profile?.followed == false)
    }
    @Test func uncertainFollowRequiresSuccessfulKnownReadBeforeAnotherWrite() async {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:10); await model.refreshProfile()
        api.followResult = { throw ClientError.writeUncertain }; await model.toggleFollow()
        #expect(model.needsRefresh); #expect(model.profile?.followed == false)
        await model.toggleFollow(); #expect(api.writes.count == 1)
        api.profileResult = { throw URLError(.timedOut) }; await model.refreshProfile(); #expect(model.needsRefresh)
        api.profileResult = { .init(user:user) }; await model.refreshProfile(); #expect(model.needsRefresh)
        api.profileResult = { .init(user:user,followed:true) }; await model.refreshProfile()
        #expect(!model.needsRefresh); #expect(model.canFollow); #expect(api.writes.count == 1)
    }
    @Test func profileRefreshRejectsWrongUser() async {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:10)
        api.profileResult = { .init(user:.init(mid:999,name:"错误用户"),followed:false) }; await model.refreshProfile()
        #expect(model.profile == nil); #expect(model.profileError != nil); #expect(!model.canFollow)
    }
    @Test func switchingAccountInvalidatesOldModelsAndLateFollowReceipt() async throws {
        let api = UserStub(); let store = UserProfileStore(api:api); store.setAccount(10)
        let model = store.model(mid:123); await model.refreshProfile(); #expect(store.model(mid:123) === model)
        var waiting: CheckedContinuation<Void, any Error>?
        api.followResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let task = Task { await model.toggleFollow() }; await until { waiting != nil }; let receipt = try #require(waiting)
        store.setAccount(99); receipt.resume(); await task.value
        #expect(model.profile == nil); #expect(!model.followBusy); #expect(model.notice == nil)
        let fresh = store.model(mid:123); #expect(fresh !== model); #expect(fresh.account == 99)
    }
    @Test func invalidatedProfileIgnoresLatePublicReads() async throws {
        let api = UserStub(); let model = UserProfileModel(api:api,mid:123,account:nil)
        var waiting: CheckedContinuation<UserProfile, any Error>?
        api.profileResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let task = Task { await model.refreshProfile() }; await until { waiting != nil }; let receipt = try #require(waiting)
        model.invalidate(); receipt.resume(returning:.init(user:user,followed:true)); await task.value
        #expect(model.profile == nil); #expect(!model.profileLoading); #expect(!model.hasMore)
    }
    @Test func profileRoutesReturnToSearchAndSidebarClearsThem() async {
        let scenario = APIScenario([]); let store = AppStore(client:scenario.client); store.player.onProgress = nil
        store.query = "影视"; store.search(); await store.searches.settled()
        store.openProfile(123); store.openProfile(123); #expect(store.profilePath.count == 1)
        store.openProfile(456); store.backFromProfile(); #expect(store.profilePath.last?.mid == 123)
        store.backFromProfile(); #expect(store.profilePath.isEmpty); #expect(store.activeSearch == "影视")
        store.openProfile(123); store.select(.history)
        #expect(store.profilePath.isEmpty); #expect(store.activeSearch.isEmpty); #expect(store.destination == .history)
        store.player.stop(); _ = scenario.finish()
    }
    @Test func returningFromAuthorRestoresPlayerAndClosedPlayerStaysClosed() {
        let scenario = APIScenario([]); let store = AppStore(client:scenario.client); store.player.onProgress = nil
        store.player.detail = .init(video:video,description:"",pages:[.init(id:20,title:"正片",duration:62)])
        store.player.cid = 20; store.player.position = 12; store.showPlayer = true
        store.openProfile(123); #expect(!store.showPlayer); #expect(store.profilePath.last?.returnRecord?.position == 12)
        store.backFromProfile(); #expect(store.showPlayer); #expect(store.player.position == 12)
        store.openProfile(123); store.closePlayer(); store.backFromProfile(); #expect(!store.showPlayer); #expect(!store.player.isOpen)
        _ = scenario.finish()
    }
}
