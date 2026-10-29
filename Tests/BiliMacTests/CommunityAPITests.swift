import Foundation
import Testing
import BiliMacCore

/// Each session gets its own scenario, so parallel tests never share replies.
private final class CommunityProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body: [String: Any]
        var failure: URLError?
    }
    private struct Scenario { var replies: [Reply]; var requests: [URLRequest] = [] }
    private static let lock = NSLock()
    private static var scenarios: [String: Scenario] = [:]
    static func register(_ id: String, _ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }; scenarios[id] = Scenario(replies: replies)
    }
    static func finish(_ id: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return scenarios.removeValue(forKey: id)?.requests ?? []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let id = request.value(forHTTPHeaderField: "X-Community-Test") ?? ""
        var scenario = Self.scenarios[id]
        scenario?.requests.append(request)
        let reply = scenario?.replies.isEmpty == false ? scenario?.replies.removeFirst() : nil
        Self.scenarios[id] = scenario; Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct APIScenario {
    let id = UUID().uuidString
    let client: BilibiliClient
    init(_ bodies: [[String: Any]]) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommunityProtocol.self]; config.httpAdditionalHeaders = ["X-Community-Test":id]
        client = BilibiliClient(session: URLSession(configuration: config))
        CommunityProtocol.register(id, bodies.map { .init(body: $0) })
    }
    func login() async { await client.setCookies(["SESSDATA":"fixture-session", "bili_jct":"fixture+csrf&token", "DedeUserID":"10"]) }
    func finish() -> [URLRequest] { CommunityProtocol.finish(id) }
}
private func query(_ request: URLRequest) -> [String: String] {
    Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}
private func form(_ request: URLRequest) -> [String: String] {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024); var result = Data()
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }; data = result
    }
    let raw = String(decoding: data ?? Data(), as: UTF8.self)
    return Dictionary(raw.split(separator: "&").compactMap { part -> (String, String)? in
        let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }; return (String(pair[0]).removingPercentEncoding ?? "", String(pair[1]).removingPercentEncoding ?? "")
    }, uniquingKeysWith: { a, _ in a })
}

@Suite struct CommunityAPITests {
    @Test func accountMismatchAndMissingCSRFNeverSendLibraryRequests() async {
        let scenario = APIScenario([])
        await #expect(throws: (any Error).self) { try await scenario.client.watchLater(mid: 10) }
        await scenario.login()
        await #expect(throws: (any Error).self) { try await scenario.client.favoriteFolders(mid: 99) }
        await #expect(throws: (any Error).self) { try await scenario.client.setWatchLater(mid: 99, aid: 20, saved: true) }
        await scenario.client.setCookies(["SESSDATA":"fixture", "DedeUserID":"10"])
        await #expect(throws: (any Error).self) { try await scenario.client.setWatchLater(mid: 10, aid: 20, saved: true) }
        #expect(scenario.finish().isEmpty)
    }
    @Test func libraryParsesFoldersResourcesUnavailableRowsAndServerPagination() async throws {
        let scenario = APIScenario([
            ["code":0, "data":["list":[["id":1, "title":"私密", "media_count":2, "attr":3, "fav_state":1]]]],
            ["code":0, "data":["medias":[["id":20, "bvid":"BV1xx411c7mD", "title":"收藏", "upper":["name":"UP"], "cnt_info":["play":99]], ["id":21, "bvid":"BV1xx411c7mE", "title":"已失效视频", "attr":9]], "has_more":true]],
            ["code":0, "data":["list":[["aid":20, "bvid":"BV1xx411c7mD", "title":"稍后", "owner":["name":"UP"], "duration":60]]]]
        ])
        await scenario.login()
        let folders = try await scenario.client.favoriteFolders(mid: 10, aid: 20)
        #expect(folders.first?.isPrivate == true); #expect(folders.first?.containsVideo == true)
        let page = try await scenario.client.favorites(mid: 10, folder: 1, page: 2)
        #expect(page.hasMore); #expect(page.items.count == 2); #expect(page.items[0].video?.author == "UP")
        #expect(page.items[0].video?.views == 99); #expect(page.items[1].video == nil)
        #expect(try await scenario.client.watchLater(mid: 10).first?.id == 20)
        let requests = scenario.finish()
        #expect(query(requests[0])["rid"] == "20"); #expect(query(requests[0])["type"] == "2")
        #expect(query(requests[1])["media_id"] == "1"); #expect(query(requests[1])["pn"] == "2")
        #expect(requests[2].url?.path == "/x/v2/history/toview")
    }
    @Test func malformedPaginationCannotBecomeSilentEndOfList() async {
        let scenario = APIScenario([
            ["code":0, "data":["medias":[]]],
            ["code":0, "data":["wbi_img":["img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c49.png", "sub_url":"https://i0.hdslb.com/bfs/wbi/3caff0ff746eab6f01bf08b70ac45.png"], "isLogin":false]],
            ["code":0, "data":["cursor":["is_end":false], "replies":[]]]
        ])
        await scenario.login()
        await #expect(throws: (any Error).self) { try await scenario.client.favorites(mid: 10, folder: 1, page: 1) }
        await #expect(throws: (any Error).self) { try await scenario.client.comments(aid: 20, sort: .hot, offset: nil) }
        #expect(scenario.finish().count == 3)
    }
    @Test func writesEncodeChineseNamesCSRFAndFavoriteDeltasWithoutExtraRequests() async throws {
        let scenario = APIScenario([
            ["code":0], ["code":0], ["code":0], ["code":0, "data":["id":3, "title":"学习 + A&B", "attr":1]]
        ])
        await scenario.login()
        try await scenario.client.changeFavorites(mid: 10, aid: 20, changes: .init(original: [1, 2], selected: [2, 3]))
        try await scenario.client.changeFavorites(mid: 10, aid: 20, changes: .init(original: [2], selected: [2]))
        try await scenario.client.setWatchLater(mid: 10, aid: 20, saved: true)
        try await scenario.client.setWatchLater(mid: 10, aid: 20, saved: false)
        let folder = try await scenario.client.createFolder(mid: 10, title: "  学习 + A&B  ", isPrivate: true)
        #expect(folder.id == 3)
        let requests = scenario.finish(); #expect(requests.count == 4)
        #expect(form(requests[0])["add_media_ids"] == "3"); #expect(form(requests[0])["del_media_ids"] == "1")
        #expect(form(requests[0])["rid"] == "20"); #expect(form(requests[0])["type"] == "2")
        #expect(requests[1].url?.path.hasSuffix("/add") == true); #expect(requests[2].url?.path.hasSuffix("/del") == true)
        #expect(form(requests[3])["title"] == "学习 + A&B"); #expect(form(requests[3])["privacy"] == "1")
        for request in requests {
            #expect(request.httpMethod == "POST"); #expect(form(request)["csrf"] == "fixture+csrf&token")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.bilibili.com")
            #expect(request.url?.host == "api.bilibili.com"); #expect(query(request).isEmpty)
        }
    }
    @Test func invalidFolderNamesAndResourceIDsDoNotWrite() async {
        let scenario = APIScenario([]); await scenario.login()
        for name in [" \n ", String(repeating: "中", count: 21)] {
            await #expect(throws: (any Error).self) { try await scenario.client.createFolder(mid: 10, title: name, isPrivate: false) }
        }
        await #expect(throws: (any Error).self) { try await scenario.client.setWatchLater(mid: 10, aid: 0, saved: true) }
        #expect(scenario.finish().isEmpty)
    }
    @Test func businessRejectionDiffersFromAmbiguousTransportAndIncompleteCreate() async throws {
        let scenario = APIScenario([]); await scenario.login()
        CommunityProtocol.register(scenario.id, [
            .init(body: ["code":90001, "message":"列表已满"]),
            .init(status: 500, body: ["code":0]),
            .init(body: [:], failure: URLError(.timedOut)),
            .init(body: ["code":0])
        ])
        do { try await scenario.client.setWatchLater(mid: 10, aid: 20, saved: true); Issue.record("应拒绝已满列表") }
        catch ClientError.server(let code, _) { #expect(code == 90001) }
        for _ in 0..<2 {
            do { try await scenario.client.setWatchLater(mid: 10, aid: 20, saved: true); Issue.record("应标记结果未知") }
            catch ClientError.writeUncertain {} catch { Issue.record(error) }
        }
        do { _ = try await scenario.client.createFolder(mid: 10, title: "学习", isPrivate: false); Issue.record("缺少新建结果") }
        catch ClientError.writeUncertain {} catch { Issue.record(error) }
        #expect(scenario.finish().count == 4)
    }
    @Test func signedCommentsPreserveOpaqueCursorAndDeduplicatePinnedReplies() async throws {
        let row: [String: Any] = ["rpid":1, "member":["uname":"作者"], "content":["message":"评论"], "rcount":2, "replies":[["rpid":2, "content":["message":"回复"]]]]
        let offset = "{\"cursor\":\"a+b&c\"}"
        let scenario = APIScenario([
            ["code":0, "data":["wbi_img":["img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c49.png", "sub_url":"https://i0.hdslb.com/bfs/wbi/3caff0ff746eab6f01bf08b70ac45.png"], "isLogin":false]],
            ["code":0, "data":["cursor":["is_end":false, "all_count":3, "pagination_reply":["next_offset":offset]], "top":["upper":row], "top_replies":[row], "replies":[row]]],
            ["code":0, "data":["cursor":["is_end":true, "all_count":3], "replies":[]]],
            ["code":0, "data":["page":["count":21, "size":20], "replies":[row]]]
        ])
        let first = try await scenario.client.comments(aid: 20, sort: .hot, offset: nil)
        #expect(first.items.count == 1); #expect(first.items[0].children.first?.id == 2); #expect(first.next == offset)
        #expect(try await scenario.client.comments(aid: 20, sort: .latest, offset: offset).next == nil)
        #expect(try await scenario.client.commentThread(aid: 20, root: 1, page: 1).hasMore)
        let requests = scenario.finish()
        #expect(query(requests[1])["mode"] == "3"); #expect(query(requests[2])["mode"] == "2")
        #expect(query(requests[1])["w_rid"]?.count == 32)
        let raw = try #require(query(requests[2])["pagination_str"]?.data(using: .utf8))
        #expect((try JSONSerialization.jsonObject(with: raw) as? [String: String])?["offset"] == offset)
        #expect(query(requests[3])["root"] == "1"); #expect(query(requests[3])["pn"] == "1")
    }
}
