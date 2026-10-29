import Foundation
import Testing
import BiliMacCore

@Suite struct VideoActionsAPITests {
    private let bvid = "BV1xx411c7mD"
    private let finger: [String: Any] = ["code":0, "data":["b_3":"official-fixture-buvid", "b_4":"official-fixture-buvid4"]]
    private var stateBodies: [[String: Any]] { [
        ["code":0, "data":["aid":20, "copyright":1, "owner":["mid":99]]],
        ["code":0, "data":["like":true, "coin":1, "favorite":false]],
        ["code":0, "data":["mid":10, "isLogin":true, "money":8.5]]
    ] }
    @Test func snapshotReadsBalanceRelationAndCopyrightInOneAccountScope() async throws {
        let scenario = APIScenario(stateBodies); await scenario.login()
        let state = try await scenario.client.interactionState(mid: 10, aid: 20)
        #expect(state.liked); #expect(state.coins == 1); #expect(!state.favorited)
        #expect(state.balance == 8.5); #expect(state.coinLimit == 2); #expect(state.ownerID == 99)
        let requests = scenario.finish()
        #expect(requests.map { $0.url!.path } == ["/x/web-interface/view", "/x/web-interface/archive/relation", "/x/web-interface/nav"])
        #expect(query(requests[1])["aid"] == "20")
        var bodies = stateBodies; bodies[0] = ["code":0, "data":["aid":20, "copyright":2, "owner":["mid":99]]]
        let repost = APIScenario(bodies); await repost.login()
        #expect(try await repost.client.interactionState(mid: 10, aid: 20).coinLimit == 1)
        #expect(repost.finish().count == 3)
    }
    @Test func malformedSnapshotAndWrongAccountNeverEnableSpending() async {
        for replacement in [
            ["code":0, "data":["isLogin":false]] as [String: Any],
            ["code":0, "data":["isLogin":true, "mid":99, "money":3]],
            ["code":0, "data":["isLogin":true, "mid":10]],
            ["code":0, "data":["isLogin":true, "mid":10, "money":-1]]
        ] {
            var bodies = stateBodies; bodies[2] = replacement
            let scenario = APIScenario(bodies); await scenario.login()
            await #expect(throws: (any Error).self) { try await scenario.client.interactionState(mid: 10, aid: 20) }
            #expect(scenario.finish().allSatisfy { $0.httpMethod == "GET" })
        }
    }
    @Test func guestAccountMismatchInvalidIDAndMissingCSRFSendNoWrites() async {
        let scenario = APIScenario([])
        await #expect(throws: (any Error).self) { try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: true) }
        await scenario.login()
        await #expect(throws: (any Error).self) { try await scenario.client.addCoins(mid: 99, aid: 20, bvid: bvid, amount: 1, alsoLike: false) }
        await #expect(throws: (any Error).self) { try await scenario.client.triple(mid: 10, aid: 0, bvid: bvid) }
        await #expect(throws: (any Error).self) { try await scenario.client.triple(mid: 10, aid: 20, bvid: "https://evil.test/") }
        for amount in [0, -1, 3] {
            await #expect(throws: (any Error).self) { try await scenario.client.addCoins(mid: 10, aid: 20, bvid: bvid, amount: amount, alsoLike: false) }
        }
        await scenario.client.setCookies(["SESSDATA":"fixture", "DedeUserID":"10"])
        await #expect(throws: (any Error).self) { try await scenario.client.triple(mid: 10, aid: 20, bvid: bvid) }
        #expect(scenario.finish().isEmpty)
    }
    @Test func likesPrepareOfficialIdentifierOnceAndUseExplicitLikeAndUnlike() async throws {
        let scenario = APIScenario([finger, ["code":0], ["code":0]])
        await scenario.login()
        try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: true)
        try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: false)
        let requests = scenario.finish(); #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/x/frontend/finger/spi")
        #expect(form(requests[1])["like"] == "1"); #expect(form(requests[2])["like"] == "2")
        for request in requests.dropFirst() {
            #expect(request.httpMethod == "POST"); #expect(request.url?.host == "api.bilibili.com")
            #expect(form(request)["csrf"] == "fixture+csrf&token"); #expect(form(request)["aid"] == "20")
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=official-fixture-buvid") == true)
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/video/\(bvid)/")
        }
    }
    @Test func coinsAndTripleUseSinglePOSTAndParseIndependentResults() async throws {
        let scenario = APIScenario([finger, ["code":0, "data":["like":false]],
                                    ["code":0, "data":["like":true, "coin":false, "fav":true, "multiply":2]]])
        await scenario.login()
        #expect(try await scenario.client.addCoins(mid: 10, aid: 20, bvid: bvid, amount: 1, alsoLike: true).liked == false)
        let triple = try await scenario.client.triple(mid: 10, aid: 20, bvid: bvid)
        #expect(triple.liked); #expect(!triple.coined); #expect(triple.favorited)
        let requests = scenario.finish(); #expect(requests.count == 3)
        #expect(requests[1].url?.path == "/x/web-interface/coin/add")
        #expect(form(requests[1])["multiply"] == "1"); #expect(form(requests[1])["select_like"] == "1")
        #expect(requests[2].url?.path == "/x/web-interface/archive/like/triple")
        #expect(form(requests[2]).keys.sorted() == ["aid", "csrf"])
    }
    @Test func malformedWriteReceiptsAreAmbiguousRatherThanSuccess() async {
        let scenario = APIScenario([finger, ["code":0], ["code":0, "data":["like":true, "coin":true, "multiply":2]],
                                    ["code":0, "data":["like":true, "coin":true, "fav":true, "multiply":0]]])
        await scenario.login()
        do { _ = try await scenario.client.addCoins(mid: 10, aid: 20, bvid: bvid, amount: 2, alsoLike: false); Issue.record("缺少投币回执") }
        catch ClientError.writeUncertain {} catch { Issue.record(error) }
        for _ in 0..<2 {
            do { _ = try await scenario.client.triple(mid: 10, aid: 20, bvid: bvid); Issue.record("应标记三连结果未知") }
            catch ClientError.writeUncertain {} catch { Issue.record(error) }
        }
        #expect(scenario.finish().count == 4)
    }
    @Test func malformedIdentifierStopsBeforePOSTAndReauthenticationDropsIt() async throws {
        let scenario = APIScenario([["code":0, "data":["b_3":"bad;injected=1"]], finger, ["code":0], finger, ["code":0]])
        await scenario.login()
        await #expect(throws: (any Error).self) { try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: true) }
        try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: true)
        await scenario.login()
        try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: false)
        let requests = scenario.finish()
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(requests.filter { $0.url?.path == "/x/frontend/finger/spi" }.count == 3)
    }
    @Test func riskAndInsufficientBalanceStayBusinessFailuresWithoutAutomaticRetries() async throws {
        let scenario = APIScenario([finger, ["code":-352, "message":"需要验证"], ["code":-104, "message":"硬币不足"]])
        await scenario.login()
        do { try await scenario.client.setVideoLike(mid: 10, aid: 20, bvid: bvid, liked: true); Issue.record("应拒绝风控") }
        catch ClientError.server(let code, _) { #expect(code == -352) }
        do { _ = try await scenario.client.addCoins(mid: 10, aid: 20, bvid: bvid, amount: 2, alsoLike: false); Issue.record("应拒绝余额不足") }
        catch ClientError.server(let code, _) { #expect(code == -104) }
        #expect(scenario.finish().count == 3)
    }
}
