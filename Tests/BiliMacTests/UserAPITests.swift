import Foundation
import Testing
@testable import BiliMacCore

@Suite struct UserAPITests {
    private let spi: [String: Any] = ["code":0,"data":["b_3":"official-fixture-id"]]
    private let nav: [String: Any] = ["code":0,"data":["isLogin":false,"wbi_img":["img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c49.png","sub_url":"https://i0.hdslb.com/bfs/wbi/3caff0ff746eab6f01bf08b70ac45.png"]]]
    @Test func userLinksRequireExactHostOrExplicitUIDPrefix() {
        for value in ["https://space.bilibili.com/123/upload/video?x=1", " UID:123 ", "uid： 123"] { #expect(UserInput.mid(value) == 123) }
        for value in ["123", "用户名", "UID:0", "UID:-1", "UID:999999999999999999999999", "https://space.bilibili.com.evil.test/123", "https://user:pass@space.bilibili.com/123", "https://space.bilibili.com:8080/123", "file:///123", "https://space.bilibili.com/用户名"] { #expect(UserInput.mid(value) == nil) }
    }
    @Test func legacyHistoryStillDecodesAndFreshVideosPreserveAuthorUID() throws {
        let raw = Data("{\"bvid\":\"BV1xx411c7mD\",\"aid\":20,\"title\":\"旧视频\",\"cover\":\"\",\"author\":\"UP\",\"duration\":60,\"views\":10}".utf8)
        #expect(try JSONDecoder().decode(Video.self, from: raw).authorID == nil)
        #expect(Video.parse(["bvid":"BV1xx411c7mD","owner":["mid":123,"name":"UP"]])?.authorID == 123)
        #expect(Video.parse(["bvid":"BV1xx411c7mD","mid":"456","author":"UP"])?.authorID == 456)
    }
    @Test func squareAvatarPreservesOriginalFallbackAndSignedQueries() throws {
        #expect(try CoverImageSource("//i0.hdslb.com/face.jpg", avatar: true).candidates.map(\.absoluteString) == ["https://i0.hdslb.com/face.jpg@160w_160h_1c.webp", "https://i0.hdslb.com/face.jpg"])
        #expect(try CoverImageSource("https://i0.hdslb.com/face.jpg?token=one", avatar: true).candidates.count == 1)
    }
    @Test func userSearchIsSignedUsesOfficialIdentifierAndServerPagination() async throws {
        let row: [String: Any] = ["mid":123,"uname":"<em>名字</em>","usign":"签名","upic":"//i0.hdslb.com/face.jpg","fans":900,"videos":8]
        let scenario = APIScenario([spi, nav,
            ["code":0,"data":["result":[row,row],"numResults":25,"numPages":2]],
            ["code":0,"data":["result":[],"numResults":25,"numPages":2]]])
        let first = try await scenario.client.searchUsers(" 名字 + A&B ", page: 1)
        #expect(first.items.count == 1); #expect(first.items[0].name == "名字"); #expect(first.hasMore); #expect(first.total == 25)
        #expect(try await !scenario.client.searchUsers("名字", page: 2).hasMore)
        let requests = scenario.finish(); #expect(requests.count == 4)
        #expect(query(requests[2])["search_type"] == "bili_user"); #expect(query(requests[2])["keyword"] == "名字 + A&B")
        #expect(query(requests[2])["w_rid"]?.count == 32); #expect(query(requests[3])["page"] == "2")
        #expect(requests[2].value(forHTTPHeaderField:"Cookie")?.contains("buvid3=official-fixture-id") == true)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func profileMetadataAndMissingCountsDoNotFabricateZeroOrFollowing() async throws {
        let scenario = APIScenario([
            ["code":0,"data":["card":["mid":"123","name":"UP","face":"//i0.hdslb.com/f.jpg","sign":"介绍","fans":100,"attention":5,"official_verify":["desc":"认证说明"]],"archive_count":8,"following":true]],
            ["code":0,"data":["card":["mid":123,"name":"UP"]]]])
        let first = try await scenario.client.userProfile(mid: 123)
        #expect(first.user.videos == 8); #expect(first.user.fans == 100); #expect(first.followingCount == 5); #expect(first.followed == true)
        #expect(first.user.verification == "认证说明")
        let second = try await scenario.client.userProfile(mid: 123)
        #expect(second.user.fans == nil); #expect(second.user.videos == nil); #expect(second.followed == nil)
        #expect(scenario.finish().count == 2)
    }
    @Test func uploadsKeepOwnerAndUseSpaceRefererSortAndServerCount() async throws {
        let row: [String: Any] = ["bvid":"BV1xx411c7mD","title":"投稿","author":"UP","length":"1:02"]
        let scenario = APIScenario([spi, nav,
            ["code":0,"data":["list":["vlist":[row]],"page":["count":31,"ps":30]]],
            ["code":0,"data":["list":["vlist":[row]],"page":["count":31,"ps":30]]]])
        let first = try await scenario.client.userVideos(mid: 123, page: 1)
        #expect(first.hasMore); #expect(first.items[0].authorID == 123); #expect(first.total == 31); #expect(first.items[0].duration == 62)
        #expect(try await !scenario.client.userVideos(mid:123, page:2, order:.views).hasMore)
        let requests = scenario.finish()
        #expect(query(requests[2])["order"] == "pubdate"); #expect(query(requests[3])["order"] == "click")
        #expect(requests[2].value(forHTTPHeaderField:"Referer") == "https://space.bilibili.com/123/upload/video")
        #expect(query(requests[3])["pn"] == "2"); #expect(query(requests[3])["w_rid"]?.count == 32)
    }
    @Test func malformedPaginationOrWrongUserDoesNotBecomeEmptySuccess() async {
        let scenario = APIScenario([spi, nav,
            ["code":0,"data":["result":[]]],
            ["code":0,"data":["list":["vlist":[]],"page":["count":99]]],
            ["code":0,"data":["card":["mid":999,"name":"错误用户"]]]])
        await #expect(throws:(any Error).self) { try await scenario.client.searchUsers("UP", page:1) }
        await #expect(throws:(any Error).self) { try await scenario.client.userVideos(mid:123,page:1) }
        await #expect(throws:(any Error).self) { try await scenario.client.userProfile(mid:123) }
        #expect(scenario.finish().count == 5)
    }
    @Test func voucherIsAnExplicitVerificationErrorAndNeverAutoRetried() async throws {
        let scenario = APIScenario([spi,nav,["code":0,"data":["v_voucher":"fixture-voucher"]]])
        do { _ = try await scenario.client.searchUsers("UP",page:1); Issue.record("不能伪装为空结果") }
        catch ClientError.server(let code, _) { #expect(code == -352) }
        #expect(scenario.finish().count == 3)
    }
    @Test func invalidUIDAccountSelfFollowAndMissingCSRFSendNoRequests() async {
        let scenario = APIScenario([])
        await #expect(throws:(any Error).self) { try await scenario.client.userProfile(mid:0) }
        await #expect(throws:(any Error).self) { try await scenario.client.searchUsers(" ",page:1) }
        await #expect(throws:(any Error).self) { try await scenario.client.setFollowing(account:10,target:123,followed:true) }
        await scenario.login()
        await #expect(throws:(any Error).self) { try await scenario.client.setFollowing(account:99,target:123,followed:true) }
        await #expect(throws:(any Error).self) { try await scenario.client.setFollowing(account:10,target:10,followed:true) }
        await #expect(throws:(any Error).self) { try await scenario.client.userVideos(mid:123,page:0) }
        await scenario.client.setCookies(["SESSDATA":"fixture","DedeUserID":"10"])
        await #expect(throws:(any Error).self) { try await scenario.client.setFollowing(account:10,target:123,followed:true) }
        #expect(scenario.finish().isEmpty)
    }
    @Test func followAndUnfollowAreExplicitSinglePostsWithCSRF() async throws {
        let scenario = APIScenario([spi,["code":0],["code":0]])
        await scenario.login()
        try await scenario.client.setFollowing(account:10,target:123,followed:true)
        try await scenario.client.setFollowing(account:10,target:123,followed:false)
        let requests = scenario.finish(); #expect(requests.count == 3)
        #expect(form(requests[1])["act"] == "1"); #expect(form(requests[2])["act"] == "2")
        for request in requests.dropFirst() {
            #expect(request.url?.path == "/x/relation/modify"); #expect(request.httpMethod == "POST")
            #expect(form(request)["fid"] == "123"); #expect(form(request)["csrf"] == "fixture+csrf&token")
            #expect(form(request)["re_src"] == "11")
        }
    }
    @Test func successfulCodeWithVerificationVoucherIsNotAFollowReceipt() async throws {
        let scenario = APIScenario([spi,["code":0,"data":["v_voucher":"fixture-voucher"]]])
        await scenario.login()
        do { try await scenario.client.setFollowing(account:10,target:123,followed:true); Issue.record("验证凭据不能视为关注成功") }
        catch ClientError.server(let code, _) { #expect(code == -352) }
        #expect(scenario.finish().count == 2)
    }
    @Test func followBusinessErrorsAndUnknownTransportAreNotAutoRetried() async throws {
        let scenario = APIScenario([])
        CommunityProtocol.register(scenario.id,[.init(body:spi),.init(body:["code":-352,"message":"需要验证"]),.init(body:[:],failure:URLError(.networkConnectionLost))])
        await scenario.login()
        do { try await scenario.client.setFollowing(account:10,target:123,followed:true); Issue.record("应拒绝") } catch ClientError.server(let code, _) { #expect(code == -352) }
        do { try await scenario.client.setFollowing(account:10,target:123,followed:true); Issue.record("结果应不明") } catch ClientError.writeUncertain {}
        #expect(scenario.finish().count == 3)
    }
}
