import Foundation
import Testing
@testable import BiliMacCore

@Suite struct CommentWritingAPITests {
    private let bvid = "BV1xx411c7mD"
    private let preparation: [String: Any] = ["code": 0, "data": ["b_3": "fixture-buvid"]]
    @Test func commentParsingPreservesOwnershipRootAndKnownLikeState() throws {
        let row = try #require(Comment.parse(["rpid": 3, "root": 1, "member": ["mid": "10", "uname": "自己"], "content": ["message": "回复"], "action": 1, "like": 4]))
        #expect(row.mid == 10); #expect(row.root == 1); #expect(row.liked == true); #expect(row.likes == 4)
        #expect(Comment.parse(["rpid": 4])?.liked == nil)
        #expect(Comment.parse(["rpid": 5, "action": 0])?.liked == false)
        #expect(Comment.parse(["rpid": 6, "action": 99])?.liked == nil)
    }
    @Test func textValidationRejectsEmptyAndOversizedUnicodeButPreservesLines() throws {
        #expect(try CommentText.normalized(" \n中文 + A&B\n第二行 😺 \n") == "中文 + A&B\n第二行 😺")
        #expect(try CommentText.normalized(String(repeating: "好", count: 1000)).count == 1000)
        for text in [" \n\t", String(repeating: "好", count: 1001), String(repeating: "😺", count: 501)] {
            #expect(throws: (any Error).self) { try CommentText.normalized(text) }
        }
    }
    @Test func topLevelAndNestedReplyEncodeExactTargetAndCSRF() async throws {
        let scenario = APIScenario([preparation, ["code": 0, "data": ["rpid": 100]], ["code": 0, "data": ["reply": ["rpid": 101]]]])
        await scenario.login()
        #expect(try await scenario.client.addComment(mid: 10, aid: 20, bvid: bvid, message: " 中文 + A&B\n第二行😺 ").id == 100)
        #expect(try await scenario.client.addComment(mid: 10, aid: 20, bvid: bvid, message: "回复", root: 100, parent: 105).id == 101)
        let requests = scenario.finish(); #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/x/frontend/finger/spi")
        let top = form(requests[1]), child = form(requests[2])
        #expect(top["message"] == "中文 + A&B\n第二行😺"); #expect(top["root"] == nil); #expect(top["parent"] == nil)
        #expect(child["root"] == "100"); #expect(child["parent"] == "105")
        for request in requests.dropFirst() {
            #expect(request.url?.host == "api.bilibili.com"); #expect(request.url?.path == "/x/v2/reply/add")
            #expect(request.httpMethod == "POST"); #expect(query(request).isEmpty)
            #expect(form(request)["type"] == "1"); #expect(form(request)["oid"] == "20"); #expect(form(request)["plat"] == "1")
            #expect(form(request)["csrf"] == "fixture+csrf&token")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/video/\(bvid)/")
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=fixture-buvid") == true)
        }
    }
    @Test func guestWrongAccountMissingCSRFBadTextAndInvalidTargetsSendNothing() async {
        let scenario = APIScenario([])
        await #expect(throws: (any Error).self) { try await scenario.client.addComment(mid: 10, aid: 20, bvid: bvid, message: "游客") }
        await scenario.login()
        await #expect(throws: (any Error).self) { try await scenario.client.addComment(mid: 99, aid: 20, bvid: bvid, message: "错号") }
        for (aid, video, text, root, parent) in [(0, bvid, "内容", 0, 0), (20, "bad", "内容", 0, 0), (20, bvid, "  ", 0, 0), (20, bvid, "内容", 1, 0), (20, bvid, "内容", 0, 2), (20, bvid, "内容", -1, 2)] {
            await #expect(throws: (any Error).self) { try await scenario.client.addComment(mid: 10, aid: aid, bvid: video, message: text, root: root, parent: parent) }
        }
        await #expect(throws: (any Error).self) { try await scenario.client.deleteComment(mid: 10, aid: 20, bvid: bvid, comment: .init(id: 1, name: "他人", message: "内容", mid: 99)) }
        await #expect(throws: (any Error).self) { try await scenario.client.likeComment(mid: 10, aid: 20, bvid: bvid, id: 0, liked: true) }
        await scenario.client.setCookies(["SESSDATA": "fixture", "DedeUserID": "10"])
        await #expect(throws: (any Error).self) { try await scenario.client.addComment(mid: 10, aid: 20, bvid: bvid, message: "无 CSRF") }
        #expect(scenario.finish().isEmpty)
    }
    @Test func likeUnlikeAndOwnDeletionUseDistinctExplicitOperations() async throws {
        let scenario = APIScenario([preparation, ["code": 0], ["code": 0], ["code": 0]])
        await scenario.login()
        try await scenario.client.likeComment(mid: 10, aid: 20, bvid: bvid, id: 3, liked: true)
        try await scenario.client.likeComment(mid: 10, aid: 20, bvid: bvid, id: 3, liked: false)
        try await scenario.client.deleteComment(mid: 10, aid: 20, bvid: bvid, comment: .init(id: 3, name: "自己", message: "内容", mid: 10))
        let requests = scenario.finish()
        #expect(requests.count == 4); #expect(form(requests[1])["action"] == "1"); #expect(form(requests[2])["action"] == "0")
        #expect(requests[3].url?.path == "/x/v2/reply/del"); #expect(form(requests[3])["rpid"] == "3")
        #expect(form(requests[3])["oid"] == "20"); #expect(form(requests[3])["csrf"] == "fixture+csrf&token")
    }
    @Test func serverRejectionsAndCaptchaDoNotBecomeSuccessOrAutoRetry() async throws {
        let scenario = APIScenario([preparation, ["code": 12002, "message": "评论区已关闭"], ["code": 0, "data": ["need_captcha": true]], ["code": -101, "message": "未登录"]])
        await scenario.login()
        for expected in [12002, -352, -101] {
            do { _ = try await scenario.client.addComment(mid: 10, aid: 20, bvid: bvid, message: "测试"); Issue.record("不应成功") }
            catch ClientError.server(let code, _) { #expect(code == expected) }
        }
        #expect(scenario.finish().count == 4)
    }
    @Test func missingContradictoryReceiptsAndTransportFailuresStayUncertain() async throws {
        let scenario = APIScenario([])
        CommunityProtocol.register(scenario.id, [
            .init(body: preparation), .init(body: ["code": 0]),
            .init(body: ["code": 0, "data": ["rpid": 1, "reply": ["rpid": 2]]]),
            .init(status: 503, body: [:]), .init(body: [:], failure: URLError(.networkConnectionLost))
        ])
        await scenario.login()
        for _ in 0..<4 {
            do { _ = try await scenario.client.addComment(mid: 10, aid: 20, bvid: bvid, message: "不自动重发"); Issue.record("结果应待核对") }
            catch ClientError.writeUncertain {} catch { Issue.record(error) }
        }
        #expect(scenario.finish().count == 5)
    }
}
