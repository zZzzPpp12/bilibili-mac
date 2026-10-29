import Foundation

public enum MediaFailure: LocalizedError, Equatable {
    case invalidRange, invalidIndex, unsupportedIndex, invalidContainer, incompatibleTimeline
    case untrustedSource, invalidResponse, http(Int), oversizedResource, closed, localService
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "媒体字节范围无效。"
        case .invalidIndex: return "媒体分段索引不完整或越界。"
        case .unsupportedIndex: return "暂不支持这种媒体索引结构，请切换视频或画质。"
        case .invalidContainer: return "媒体初始化格式不兼容，请切换画质。"
        case .incompatibleTimeline: return "音视频时间轴不兼容，请切换画质。"
        case .untrustedSource: return "媒体地址不在允许的官方来源范围内。"
        case .invalidResponse: return "媒体服务器未返回所请求的完整字节范围。"
        case .http(let code): return "媒体读取失败（HTTP \(code)），请重试或切换画质。"
        case .oversizedResource: return "这个媒体分段超出当前播放桥的资源上限，请选择较低画质。"
        case .closed: return "播放会话已关闭。"
        case .localService: return "本机播放通道未能启动，请重试。"
        }
    }
}

public struct ByteSpan: Hashable, Sendable {
    public let offset: Int64
    public let length: Int64
    public var end: Int64 { offset + length - 1 }
    public var header: String { "bytes=\(offset)-\(end)" }
    public init(offset: Int64, length: Int64) throws {
        guard offset >= 0, length > 0, !offset.addingReportingOverflow(length).overflow else { throw MediaFailure.invalidRange }
        self.offset = offset; self.length = length
    }
    public static func parse(_ text: String, size: Int64) throws -> ByteSpan {
        guard size > 0, text.hasPrefix("bytes="), !text.contains(",") else { throw MediaFailure.invalidRange }
        let pieces = text.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        func number(_ text: Substring) -> Int64? { !text.isEmpty && text.utf8.allSatisfy({ (48...57).contains($0) }) ? Int64(text) : nil }
        guard pieces.count == 2 else { throw MediaFailure.invalidRange }
        if pieces[0].isEmpty {
            guard let suffix = number(pieces[1]), suffix > 0 else { throw MediaFailure.invalidRange }
            let length = min(suffix,size); return try ByteSpan(offset:size-length,length:length)
        }
        guard let first = number(pieces[0]), first < size else { throw MediaFailure.invalidRange }
        let last: Int64
        if pieces[1].isEmpty { last = size - 1 }
        else { guard let value = number(pieces[1]), value >= first else { throw MediaFailure.invalidRange }; last = min(value,size-1) }
        return try ByteSpan(offset:first,length:last-first+1)
    }
}

public enum MediaOrigin {
    public static func normalizedURL(_ raw: String) -> URL? {
        guard var c = URLComponents(string:raw), c.user == nil, c.password == nil, c.fragment == nil,
              let scheme = c.scheme?.lowercased(), ["http","https"].contains(scheme),
              let host = c.host?.lowercased(), ["bilivideo.com","bilivideo.cn","hdslb.com"].contains(where: { host == $0 || host.hasSuffix("."+$0) }),
              c.port == nil || c.port == 443 || (scheme == "http" && c.port == 80) else { return nil }
        c.scheme = "https"; c.host = host; c.port = nil
        return c.url
    }
    static func allows(_ url: URL) -> Bool { normalizedURL(url.absoluteString) == url && url.scheme == "https" }
}
public enum TrackKind: Sendable { case video, audio }
public struct MediaTrack: Sendable {
    public let id: Int
    public let kind: TrackKind
    public let codec: String
    public let bandwidth: Int
    public let width: Int
    public let height: Int
    public let urls: [URL]
    public let initialization: ByteSpan
    public let index: ByteSpan
    public var primaryURL: URL { urls[0] }
    public init(id: Int, kind: TrackKind, codec: String, bandwidth: Int = 0, width: Int = 0, height: Int = 0,
                urls: [URL], initialization: ByteSpan, index: ByteSpan) throws {
        guard !urls.isEmpty, urls.count <= 16, urls.allSatisfy(MediaOrigin.allows),
              codec.range(of:"^[A-Za-z0-9]+(?:\\.[A-Za-z0-9]+)*$",options:.regularExpression) != nil,
              bandwidth >= 0, width >= 0, height >= 0 else { throw MediaFailure.untrustedSource }
        self.id = id; self.kind = kind; self.codec = codec; self.bandwidth = bandwidth
        self.width = width; self.height = height; self.urls = urls; self.initialization = initialization; self.index = index
    }
}

/// No account cookies, source URLs or signature strings are exposed to the player.
public final class PreparedStream: @unchecked Sendable {
    public let url: URL
    private let failure: @Sendable () -> String?
    public var lastFailure: String? { failure() }
    private let close: @Sendable () -> Void
    init(url: URL, failure: @escaping @Sendable () -> String? = { nil }, close: @escaping @Sendable () -> Void) { self.url = url; self.failure = failure; self.close = close }
    public func stop() { close() }
    deinit { close() }
}
public protocol PlaybackPreparing: Sendable {
    func prepare(video: MediaTrack, audio: MediaTrack, headers: [String:String], start: Double?) async throws -> PreparedStream
}
