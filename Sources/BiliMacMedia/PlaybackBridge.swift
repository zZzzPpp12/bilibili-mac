import Foundation

struct RemoteSlice: Sendable {
    let url: URL
    let span: ByteSpan
    let total: Int64
    let headers: [String:String]
}
enum LocalResource: Sendable {
    case memory(Data,String)
    case fragment(RemoteSlice,String)
    var length: Int64 { switch self { case .memory(let data,_): Int64(data.count); case .fragment(let source,_): source.span.length } }
    var mime: String { switch self { case .memory(_,let mime), .fragment(_,let mime): mime } }
}

public struct NativePlaybackBridge: PlaybackPreparing {
    private let reader: any MediaReading
    public init(reader: any MediaReading = HTTPMediaReader()) { self.reader = reader }
    public func prepare(video: MediaTrack, audio: MediaTrack, headers: [String:String] = [:], start: Double? = nil) async throws -> PreparedStream {
        guard video.kind == .video, audio.kind == .audio,
              video.codec.hasPrefix("avc1"), audio.codec.hasPrefix("mp4a") else { throw MediaFailure.invalidContainer }
        async let visual = load(video,headers:headers)
        async let audible = load(audio,headers:headers)
        let (v,a) = try await (visual,audible)
        try Task.checkCancellation()
        guard abs(v.index.startSeconds-a.index.startSeconds) <= 0.1,
              abs(v.index.duration-a.index.duration) <= 1 else { throw MediaFailure.incompatibleTimeline }
        var routes: [String:LocalResource] = [:]
        add(v,under:"v",headers:headers,to:&routes); add(a,under:"a",headers:headers,to:&routes)
        let rate = min(1_000_000_000,max(1,peak(v)+peak(a)))
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if let start, start.isFinite, start > 0 {
            master += "#EXT-X-START:TIME-OFFSET=\(decimal(min(start,max(0,min(v.index.duration,a.index.duration)-0.1)))),PRECISE=YES\n"
        }
        master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"原始音轨\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a/index.m3u8\"\n"
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(rate),CODECS=\"\(video.codec),\(audio.codec)\",AUDIO=\"sound\""
        if video.width > 0, video.height > 0 { master += ",RESOLUTION=\(video.width)x\(video.height)" }
        master += "\nv/index.m3u8\n"
        routes["main.m3u8"] = .memory(Data(master.utf8),"application/vnd.apple.mpegurl")
        let server = LocalMediaService(routes:routes,reader:reader)
        do {
            let url = try await server.open()
            try Task.checkCancellation()
            return PreparedStream(url:url,failure:{ server.lastFailure },close:{ server.close() })
        } catch { server.close(); throw error }
    }
    private struct Loaded: Sendable {
        let track: MediaTrack
        let url: URL
        let total: Int64
        let initialization: Data
        let index: SegmentIndex
    }
    private func load(_ track: MediaTrack, headers: [String:String]) async throws -> Loaded {
        guard track.initialization.length <= 2_097_152, track.index.length <= 2_097_152 else { throw MediaFailure.oversizedResource }
        var last: any Error = MediaFailure.invalidResponse
        for url in track.urls.prefix(3) {
            try Task.checkCancellation()
            do {
                let index = try await reader.read(url:url,span:track.index,completeLength:nil,headers:headers)
                let parsed = try SegmentIndex.decode(index.bytes,fileOffset:track.index.offset,fileLength:index.completeLength)
                let initial = try await reader.read(url:url,span:track.initialization,completeLength:index.completeLength,headers:headers)
                try SegmentIndex.validateInitialization(initial.bytes)
                return Loaded(track:track,url:url,total:index.completeLength,initialization:initial.bytes,index:parsed)
            } catch { try Task.checkCancellation(); last = error }
        }
        throw last
    }
    private func peak(_ value: Loaded) -> Int {
        let largest = value.index.fragments.map { Double($0.bytes.length)*8*Double(value.index.timescale)/Double($0.ticks) }.max() ?? 1
        return Int(min(500_000_000,max(Double(value.track.bandwidth),largest*1.1)))
    }
    private func add(_ loaded: Loaded, under prefix: String, headers: [String:String], to routes: inout [String:LocalResource]) {
        let mime = loaded.track.kind == .video ? "video/mp4" : "audio/mp4"
        routes[prefix+"/init.mp4"] = .memory(loaded.initialization,mime)
        let maxDuration = loaded.index.fragments.map { Double($0.ticks)/Double(loaded.index.timescale) }.max() ?? 1
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:\(Int(ceil(maxDuration)))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (number,fragment) in loaded.index.fragments.enumerated() {
            let path = "seg/\(number).m4s"
            routes[prefix+"/"+path] = .fragment(.init(url:loaded.url,span:fragment.bytes,total:loaded.total,headers:headers),mime)
            playlist += "#EXTINF:\(decimal(Double(fragment.ticks)/Double(loaded.index.timescale))),\n\(path)\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        routes[prefix+"/index.m3u8"] = .memory(Data(playlist.utf8),"application/vnd.apple.mpegurl")
    }
    private func decimal(_ value: Double) -> String { String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),value) }
}
