import Foundation
import AVFoundation
import Testing
import BiliModels
import BiliNetworking
import BiliPlayback
import BiliMacCore
@testable import BiliMac

@Suite(.serialized) struct PlaybackTests {
    @Test @MainActor func stoppingReleasesCurrentItemAndSessionState() {
        let controller = PlayerController()
        controller.player.replaceCurrentItem(with:AVPlayerItem(url:URL(fileURLWithPath:"/tmp/nonexistent-fixture.mp4")))
        controller.stop()
        #expect(controller.player.currentItem == nil)
        #expect(!controller.isOpen)
        #expect(controller.danmaku.isEmpty)
    }
    @Test func bridgeBuildsCompletePlaylistAndServesExactRange() async throws {
        let (video,audio,source) = try fixtures()
        let asset = try await DASHToHLSBridge(mediaStreamer:source).prepare(video:video,audio:audio,headers:[:])
        defer { asset.stop() }
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration:config)
        let (master, response) = try await session.data(from:asset.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = String(decoding:master,as:UTF8.self)
        #expect(text.contains("#EXT-X-STREAM-INF"))
        let playlist = try #require(text.split(separator:"\n").first { !$0.hasPrefix("#") && $0.contains("video/") })
        let playlistURL = try #require(URL(string:String(playlist),relativeTo:asset.url))
        let (data,_) = try await session.data(from:playlistURL)
        let content = String(decoding:data,as:UTF8.self)
        #expect(content.contains("#EXT-X-ENDLIST"))
        #expect(content.components(separatedBy:"#EXTINF:").count-1 == 4)
        #expect(content.contains("#EXT-X-BYTERANGE"))
    }
    @Test @MainActor func avPlayerActuallyAdvancesThroughSyntheticHLS() async throws {
        let (video,audio,source) = try fixtures()
        let asset = try await DASHToHLSBridge(mediaStreamer:source).prepare(video:video,audio:audio,headers:[:])
        defer { asset.stop() }
        let player = AVPlayer(url:asset.url)
        defer { player.pause(); player.replaceCurrentItem(with:nil) }
        player.play()
        for _ in 0..<80 {
            if player.currentTime().seconds > 0.4 { break }
            if player.currentItem?.status == .failed { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        #expect(player.currentItem?.status == .readyToPlay)
        #expect(player.currentTime().seconds > 0.4)
        #expect((player.currentItem?.presentationSize.width ?? 0) > 0)
    }
    private func fixtures() throws -> (MediaRepresentation,MediaRepresentation,FixtureStream) {
        func track(_ name:String,id:Int,kind:MediaKind,codec:String) throws -> (MediaRepresentation,Data) {
            let url = try #require(Bundle.module.url(forResource:name,withExtension:"base64",subdirectory:"Fixtures"))
            let data = try #require(Data(base64Encoded:Data(contentsOf:url),options:.ignoreUnknownCharacters))
            var offset = 0; var sidx: (Int,Int)?
            while offset+8 <= data.count {
                let size = data[offset..<offset+4].reduce(0) { $0*256+Int($1) }
                guard size >= 8, offset+size <= data.count else { break }
                if String(decoding:data[offset+4..<offset+8],as:UTF8.self) == "sidx" { sidx = (offset,size); break }
                offset += size
            }
            let index = try #require(sidx)
            let attributes = kind == .video ? try VideoRepresentationAttributes(width:128,height:72,frameRate:24) : nil
            let representation = MediaRepresentation(id:id,kind:kind,codecs:codec,mimeType:kind == .video ? "video/mp4":"audio/mp4",bandwidth:kind == .video ? 100000:32000,videoAttributes:attributes,primaryURL:URL(string:"https://fixture.bilivideo.com/\(id).mp4")!,backupURLs:[],segmentBase:SegmentBase(initialization:try MediaByteRange(start:0,endInclusive:Int64(index.0-1)),index:try MediaByteRange(start:Int64(index.0),endInclusive:Int64(index.0+index.1-1))))
            return (representation,data)
        }
        let (v,vd) = try track("video-avc-128x72-4s-global-sidx.mp4",id:80,kind:.video,codec:"avc1.4d400b")
        let (a,ad) = try track("audio-aac-4s-global-sidx.mp4",id:30280,kind:.audio,codec:"mp4a.40.2")
        return (v,a,FixtureStream(data:[v.primaryURL:vd,a.primaryURL:ad]))
    }
}
private struct FixtureStream: HTTPRangeStreaming {
    let data: [URL:Data]
    func stream(from url:URL,rangeHeader:String,expectedRange:HTTPByteRange,expectedCompleteLength:Int64?,headers:[String:String],allowedContentTypes:Set<String>?,requiresContentLength:Bool,onResponse:@escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,onChunk:@escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
        let bytes = try #require(data[url]); let lower = Int(expectedRange.start), upper = Int(expectedRange.endInclusive)+1
        guard lower >= 0, upper <= bytes.count else { throw ClientError.invalidResponse }
        try await onResponse(HTTPRangeStreamResponse(contentRange:HTTPContentRange(start:expectedRange.start,endInclusive:expectedRange.endInclusive,completeLength:Int64(bytes.count)),contentLength:expectedRange.length,contentType:url.path.contains("30280") ? "audio/mp4":"video/mp4"))
        try await onChunk(bytes.subdata(in:lower..<upper))
        return HTTPRangeStreamResult(byteCount:expectedRange.length)
    }
}
