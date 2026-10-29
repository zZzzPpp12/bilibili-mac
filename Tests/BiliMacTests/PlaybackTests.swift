import Foundation
import AVFoundation
import Testing
import BiliMacMedia
import BiliMacCore
@testable import BiliMac

@Suite(.serialized) struct PlaybackTests {
    @Test @MainActor func stoppingReleasesCurrentItemAndSessionState() {
        let controller = PlayerController()
        controller.player.replaceCurrentItem(with:AVPlayerItem(url:URL(fileURLWithPath:"/tmp/nonexistent-fixture.mp4")))
        controller.stop()
        #expect(controller.player.currentItem == nil); #expect(!controller.isOpen); #expect(controller.danmaku.isEmpty)
    }
    @Test func virtualFragmentReturnsExactBytesAndRelativeRangeWithoutLeakingSource() async throws {
        let f = try MediaFixtures()
        let asset = try await NativePlaybackBridge(reader:f.reader).prepare(video:f.video,audio:f.audio)
        defer { asset.stop() }
        let client = MediaFixtures.session()
        let (master,response) = try await client.data(from:asset.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let main = String(decoding:master,as:UTF8.self)
        #expect(main.contains("#EXT-X-MEDIA:TYPE=AUDIO")); #expect(!main.contains("bilivideo.com"))
        let directory = URL(string:"v/index.m3u8",relativeTo:asset.url)!
        let (playlist,_) = try await client.data(from:directory)
        let text = String(decoding:playlist,as:UTF8.self)
        #expect(text.contains("#EXT-X-ENDLIST")); #expect(text.components(separatedBy:"#EXTINF:").count-1 == 8)
        #expect(text.contains("#EXT-X-MAP:URI=\"init.mp4\"")); #expect(!text.contains("I-FRAMES-ONLY"))
        let media = URL(string:"seg/0.m4s",relativeTo:directory)!
        let index = try SegmentIndex.decode(f.videoBytes.subdata(in:Int(f.video.index.offset)..<Int(f.video.index.offset+f.video.index.length)),fileOffset:f.video.index.offset,fileLength:Int64(f.videoBytes.count))
        let fragment = index.fragments[0].bytes
        let (body,_) = try await client.data(from:media)
        #expect(body == f.videoBytes.subdata(in:Int(fragment.offset)..<Int(fragment.offset+fragment.length)))
        var request = URLRequest(url:media); request.setValue("bytes=3-9",forHTTPHeaderField:"Range")
        let (partial,partialResponse) = try await client.data(for:request)
        #expect(partial == body.subdata(in:3..<10))
        #expect((partialResponse as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Range") == "bytes 3-9/\(body.count)")
        #expect((partialResponse as? HTTPURLResponse)?.statusCode == 206)
        request.setValue("bytes=9999999-",forHTTPHeaderField:"Range")
        let (_,invalid) = try await client.data(for:request); #expect((invalid as? HTTPURLResponse)?.statusCode == 416)
        request.httpMethod = "HEAD"; request.setValue(nil,forHTTPHeaderField:"Range")
        let before = await f.reader.reads.count
        let (empty,head) = try await client.data(for:request)
        #expect(empty.isEmpty); #expect((head as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Length") == String(body.count))
        #expect(await f.reader.reads.count == before)
    }
    @Test @MainActor func avPlayerDecodesOwnAudioVideoAndCanSeekWhilePaused() async throws {
        let f = try MediaFixtures()
        let asset = try await NativePlaybackBridge(reader:f.reader).prepare(video:f.video,audio:f.audio)
        defer { asset.stop() }
        let player = AVPlayer(url:asset.url); player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with:nil) }
        player.play()
        for _ in 0..<120 {
            if player.currentTime().seconds > 0.4 || player.currentItem?.status == .failed { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        #expect(player.currentItem?.status == .readyToPlay)
        #expect(player.currentTime().seconds > 0.4)
        #expect((player.currentItem?.presentationSize.width ?? 0) == 160)
        let item = try #require(player.currentItem)
        let audible = try #require(try await item.asset.loadMediaSelectionGroup(for:.audible))
        #expect(!audible.options.isEmpty)
        #expect(item.currentMediaSelection.selectedMediaOption(in:audible) != nil)
        let reads = await f.reader.reads
        #expect(reads.contains { $0.0 == f.audio.primaryURL && $0.1.offset > f.audio.index.end })
        player.pause()
        await withCheckedContinuation { continuation in
            player.seek(to:CMTime(seconds:3.2,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { _ in continuation.resume() }
        }
        #expect(abs(player.currentTime().seconds-3.2) < 0.15); #expect(player.rate == 0)
    }
    @Test func closedSessionCannotServeAndStopIsIdempotent() async throws {
        let f = try MediaFixtures()
        let asset = try await NativePlaybackBridge(reader:f.reader).prepare(video:f.video,audio:f.audio)
        let client = MediaFixtures.session()
        _ = try await client.data(from:asset.url)
        asset.stop(); asset.stop()
        await #expect(throws:(any Error).self) { try await client.data(from:asset.url) }
    }
}
