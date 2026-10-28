import Testing
import Foundation
import AVFoundation
import BiliPlayback
import BiliMacCore

@Suite struct LiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_TEST"] == "1"))
    func publicEndpointsAndQR() async throws {
        let client = BilibiliClient()
        let feed = try await client.feed(recommended:false,page:1)
        let video = try #require(feed.first)
        let detail = try await client.detail(video.bvid)
        #expect(!detail.pages.isEmpty)
        let qr = try await client.qrCode()
        #expect(!qr.key.isEmpty)
        print("LIVE: public feed, signed detail and QR generation succeeded; no account loaded")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_PLAYBACK"] == "1")) @MainActor
    func publicVideoActuallyPlays() async throws {
        let client = BilibiliClient()
        let feed = try await client.feed(recommended:false,page:1)
        let video = try #require(feed.first)
        let detail = try await client.detail(video.bvid)
        let manifest = try await client.manifest(bvid:video.bvid,cid:detail.pages[0].id)
        let representation = try #require(manifest.videos.filter { $0.codecs.hasPrefix("avc1") }.last)
        let asset = try await DASHToHLSBridge().prepare(video:representation,audio:manifest.audio,headers:BilibiliClient.mediaHeaders)
        defer { asset.stop() }
        let player = AVPlayer(url:asset.url)
        defer { player.pause(); player.replaceCurrentItem(with:nil) }
        player.play()
        for _ in 0..<120 {
            if player.currentTime().seconds > 0.5 || player.currentItem?.status == .failed { break }
            try await Task.sleep(for:.milliseconds(250))
        }
        #expect(player.currentTime().seconds > 0.5)
        #expect((player.currentItem?.presentationSize.width ?? 0) > 0)
        print("LIVE: public video media clock and decoded picture size verified; no credentials used")
    }
}
