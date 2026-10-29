import Foundation
import Testing
import BiliMacMedia
import BiliMacCore
@testable import BiliMac

@Suite(.serialized) @MainActor struct NativeControllerTests {
    @Test func pausedResumeAndQualityRebuildRetainActualMediaPosition() async throws {
        let f = try MediaFixtures()
        func row(_ track:MediaTrack) -> [String:Any] {
            ["id":track.id,"codecs":track.codec,"base_url":track.primaryURL.absoluteString,
             "width":track.width,"height":track.height,"bandwidth":track.bandwidth,
             "segment_base":["initialization":"\(track.initialization.offset)-\(track.initialization.end)","index_range":"\(track.index.offset)-\(track.index.end)"]]
        }
        let bvid = "BV1xx411c7mD"
        ControllerAPIProtocol.setResponses([
            "/x/web-interface/nav":["code":0,"data":["isLogin":false,"wbi_img":["img_url":"https://i0.hdslb.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png","sub_url":"https://i0.hdslb.com/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png"]]],
            "/x/web-interface/wbi/view":["code":0,"data":["bvid":bvid,"aid":20,"title":"测试","owner":["name":"测试 UP","mid":10],"duration":8,"pages":[["cid":99,"part":"正片","duration":8]]]],
            "/x/player/playurl":["code":0,"data":["dash":["video":[row(f.video)],"audio":[row(f.audio)]]]]
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControllerAPIProtocol.self]
        configuration.httpCookieStorage = nil
        let apiSession = URLSession(configuration:configuration)
        let api = BilibiliClient(session:apiSession)
        AppSettings.register()
        let oldQuality = AppSettings.defaults.object(forKey:"quality")
        let controller = PlayerController(bridge:NativePlaybackBridge(reader:f.reader))
        defer {
            controller.stop(); apiSession.invalidateAndCancel(); ControllerAPIProtocol.setResponses([:])
            if let oldQuality { AppSettings.defaults.set(oldQuality,forKey:"quality") } else { AppSettings.defaults.removeObject(forKey:"quality") }
        }
        let video = Video(bvid:bvid,title:"测试",author:"测试 UP",duration:8)
        controller.open(bvid,client:api,record:.init(video:video,cid:99,position:3.2),playing:false)
        for _ in 0..<120 { if !controller.loading { break }; try await Task.sleep(for:.milliseconds(100)) }
        try #require(controller.error == nil); #expect(!controller.loading)
        #expect(abs(controller.player.currentTime().seconds-3.2) < 0.15)
        #expect(!controller.intendedPlaying); #expect(controller.player.rate == 0)
        controller.change(client:api,quality:80)
        for _ in 0..<120 { if !controller.loading && controller.player.currentItem?.status == .readyToPlay { break }; try await Task.sleep(for:.milliseconds(100)) }
        #expect(controller.error == nil)
        #expect(abs(controller.player.currentTime().seconds-3.2) < 0.15)
        #expect(!controller.intendedPlaying); #expect(controller.player.rate == 0)
    }
}

// Route by endpoint so concurrent danmaku requests cannot consume a queued
// playback response. Every unregistered request fails inside this session.
private final class ControllerAPIProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String:Data] = [:]
    static func setResponses(_ values: [String:[String:Any]]) {
        lock.lock(); defer { lock.unlock() }
        responses = values.mapValues { try! JSONSerialization.data(withJSONObject:$0) }
    }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let body = Self.responses[request.url?.path ?? ""]; Self.lock.unlock()
        guard request.httpMethod == "GET", let body else {
            client?.urlProtocol(self,didFailWithError:URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,
                                                         headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
