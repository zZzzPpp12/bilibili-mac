import Foundation
import Testing
import BiliMacMedia

actor FixtureMediaReader: MediaReading {
    let files: [URL:Data]
    private(set) var reads: [(URL,ByteSpan)] = []
    var delay: Duration = .zero
    var fail = false
    init(files: [URL:Data]) { self.files = files }
    func read(url: URL, span: ByteSpan, completeLength: Int64?, headers: [String:String]) async throws -> MediaSlice {
        reads.append((url,span))
        if fail { throw MediaFailure.invalidResponse }
        if delay > .zero { try await Task.sleep(for:delay) }
        let file = try #require(files[url]); #expect(completeLength == nil || completeLength == Int64(file.count))
        guard span.end < file.count else { throw MediaFailure.invalidRange }
        return .init(bytes:file.subdata(in:Int(span.offset)..<Int(span.offset+span.length)),completeLength:Int64(file.count))
    }
    func setFailure() { fail = true }
    func setDelay(_ value: Duration) { delay = value }
}
struct MediaFixtures {
    let video: MediaTrack
    let audio: MediaTrack
    let reader: FixtureMediaReader
    let videoBytes: Data
    init() throws {
        func load(_ name: String, id: Int, kind: TrackKind) throws -> (MediaTrack,Data) {
            let file = try #require(Bundle.module.url(forResource:name,withExtension:"base64",subdirectory:"Fixtures"))
            let data = try #require(Data(base64Encoded:Data(contentsOf:file),options:.ignoreUnknownCharacters))
            var index: (Int,Int)?, position = 0
            while position+8 <= data.count {
                let length = data[position..<position+4].reduce(0) { $0*256+Int($1) }
                guard length >= 8, length <= data.count-position else { throw MediaFailure.invalidIndex }
                if String(decoding:data[position+4..<position+8],as:UTF8.self) == "sidx" { index = (position,length); break }
                position += length
            }
            let span = try #require(index)
            let codec: String
            if kind == .video {
                let avc = try #require(data.range(of:Data("avcC".utf8)))
                let values = data[avc.upperBound+1..<avc.upperBound+4]
                codec = "avc1."+values.map { String(format:"%02x",$0) }.joined()
            } else { codec = "mp4a.40.2" }
            let track = try MediaTrack(id:id,kind:kind,codec:codec,bandwidth:kind == .video ? 120000:96000,
                                      width:kind == .video ? 160:0,height:kind == .video ? 96:0,
                                      urls:[URL(string:"https://fixture.bilivideo.com/own/\(name)")!],
                                      initialization:ByteSpan(offset:0,length:Int64(span.0)),index:ByteSpan(offset:Int64(span.0),length:Int64(span.1)))
            return (track,data)
        }
        let v = try load("bilimac-colors.mp4",id:80,kind:.video), a = try load("bilimac-beeps.mp4",id:30280,kind:.audio)
        video = v.0; audio = a.0; videoBytes = v.1; reader = FixtureMediaReader(files:[v.0.primaryURL:v.1,a.0.primaryURL:a.1])
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.urlCache = nil; config.timeoutIntervalForRequest = 3
        return URLSession(configuration:config)
    }
}
