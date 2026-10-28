import Foundation
import Testing
import BiliModels
import BiliMacCore

@Suite struct CoreTests {
    @Test func wbiMatchesPublishedVector() {
        let key = WBISigning.mixin("7cd084941338484aae1ad9425b84077c4932caff0ff746eab6f01bf08b70ac45")
        #expect(key == "ea1db124af3c7062474693fa704f4ff8")
        let result = WBISigning.sign(["foo":"114", "bar":"514", "baz":"1919810"],key:key,timestamp:1_702_204_169)
        #expect(result["w_rid"] == "6149fdadf571698ca7e6a567265cd0ee")
    }
    @Test func videoInputRejectsLookalikeHostsAndIncompleteIDs() {
        #expect(VideoInput.bvid("https://www.bilibili.com/video/BV1xx411c7mD/?p=2") == "BV1xx411c7mD")
        #expect(VideoInput.bvid(" BV1xx411c7mD ") == "BV1xx411c7mD")
        #expect(VideoInput.bvid("https://bilibili.com.evil.test/video/BV1xx411c7mD") == nil)
        #expect(VideoInput.bvid("BV123") == nil)
        #expect(VideoInput.bvid("普通搜索关键词") == nil)
    }
    @Test func parserHandlesSearchAndFeedShapeDifferences() throws {
        let video = try #require(Video.parse(["bvid":"BV1xx411c7mD", "title":"<em>Swift</em> &amp; macOS", "author":"作者", "duration":"12:34", "play":"10001"]))
        #expect(video.title == "Swift & macOS")
        #expect(video.duration == 754)
        #expect(video.views == 10001)
        #expect(Video.unique([video,video]).count == 1)
    }
    @Test func resumeRestartsNearEndAndRejectsInvalidValues() {
        #expect(WatchRecord.resumePosition(.nan,duration:100) == 0)
        #expect(WatchRecord.resumePosition(98,duration:100) == 0)
        #expect(WatchRecord.resumePosition(45,duration:100) == 45)
        #expect(WatchRecord.resumePosition(-5,duration:100) == 0)
    }
    @Test func historyRoundTripAndLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let repository = HistoryRepository(file:directory.appendingPathComponent("history.json"))
        let video = Video(bvid:"BV1xx411c7mD",title:"测试",author:"作者",duration:100)
        try repository.save((0..<205).map { WatchRecord(video:video,cid:$0+1,position:45) })
        #expect(repository.load().count == 200)
        #expect(repository.load()[0].position == 45)
        #expect(repository.load()[0].positions["1"] == 45)
        try Data("bad json".utf8).write(to:repository.file)
        #expect(repository.load().isEmpty)
    }
    @Test func protobufDecodesMillisecondsAndSkipsUnknownFields() throws {
        // Outer repeated element, ID=1, progress=1500, mode=1, text=hi; unknown field 15=9.
        let bytes: [UInt8] = [10,13,8,1,16,220,11,24,1,58,2,104,105,120,9]
        let result = try DanmakuDecoder.decode(Data(bytes))
        #expect(result.count == 1)
        #expect(result.first?.time == 1.5)
        #expect(result.first?.text == "hi")
        #expect(throws:(any Error).self) { try DanmakuDecoder.decode(Data([10,100,8])) }
        #expect(throws:(any Error).self) { try DanmakuDecoder.decode(Data([0])) }
    }
    @Test func motionUsesMediaTimeAtBothEdges() {
        #expect(DanmakuMotion.x(width:1000,textWidth:200,elapsed:0) == 1000)
        #expect(DanmakuMotion.x(width:1000,textWidth:200,elapsed:8) == -200)
        #expect(DanmakuMotion.x(width:1000,textWidth:200,elapsed:0,reverse:true) == -200)
    }
    @Test func manifestKeepsValidBackupsAndHighestBitrateAudio() throws {
        func row(id:Int,codec:String,rate:Int) -> [String:Any] {
            ["id":id,"codecs":codec,"base_url":"https://localhost/private","backup_url":["https://media.bilivideo.com/\(id).mp4"], "width":1920,"height":1080,"bandwidth":rate,"segment_base":["initialization":"0-100","index_range":"101-200"]]
        }
        let result = try BilibiliClient.parseManifest(["dash":["video":[row(id:80,codec:"avc1.4d401f",rate:100000)], "audio":[row(id:30232,codec:"mp4a.40.2",rate:100),row(id:30280,codec:"mp4a.40.2",rate:200)]]])
        #expect(result.audio.id == 30280)
        #expect(result.videos.first?.primaryURL.host == "media.bilivideo.com")
        #expect(throws:(any Error).self) { try BilibiliClient.parseManifest([:]) }
    }
}

@Suite(.serialized) struct NetworkTests {
    @Test func httpAndBusinessFailuresAreSurfaced() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let client = BilibiliClient(session:URLSession(configuration:config))
        FixtureProtocol.reply = (412, ["code":0])
        await #expect(throws:(any Error).self) { try await client.feed(recommended:false,page:1) }
        FixtureProtocol.reply = (200, ["code":-352,"message":"请求受限"])
        await #expect(throws:(any Error).self) { try await client.feed(recommended:false,page:1) }
        FixtureProtocol.reply = (200, ["code":0,"data":["list":[]]])
        #expect(try await client.feed(recommended:false,page:1).isEmpty)
    }
    @Test func sessionCookieAllowlistRejectsHeaderInjection() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let client = BilibiliClient(session:URLSession(configuration:config))
        await client.setCookies(["SESSDATA":"abc", "bili_jct":"bad\nvalue", "unknown":"secret"])
        FixtureProtocol.reply = (200, ["code":0,"data":["list":[]]])
        _ = try await client.feed(recommended:false,page:1)
        #expect(FixtureProtocol.lastCookie == "SESSDATA=abc")
    }
    @Test func qrAcceptsCurrentOfficialAccountHostAndRejectsLookalikes() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let client = BilibiliClient(session:URLSession(configuration:config))
        FixtureProtocol.reply = (200,["code":0,"data":["qrcode_key":"fixture-key","url":"https://account.bilibili.com/h5/passport/qrcode"]])
        #expect(try await client.qrCode().key == "fixture-key")
        FixtureProtocol.reply = (200,["code":0,"data":["qrcode_key":"fixture-key","url":"https://account.bilibili.com.evil.test/login"]])
        await #expect(throws:(any Error).self) { try await client.qrCode() }
    }
}
private final class FixtureProtocol: URLProtocol {
    static var reply: (Int,[String:Any]) = (200,[:])
    static var lastCookie: String?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastCookie = request.value(forHTTPHeaderField:"Cookie")
        let response = HTTPURLResponse(url:request.url!,statusCode:Self.reply.0,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:Self.reply.1))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
