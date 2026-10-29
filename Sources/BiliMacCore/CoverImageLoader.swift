import Foundation
import CoreGraphics
import ImageIO

/// A decoded, downsampled image. Successful images are shared across list cells.
public final class CoverImage: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }
}

public enum CoverImageError: Error, Equatable, Sendable {
    case missingSource, unsupportedSource, invalidImage, tooLarge
    case http(Int), network(URLError.Code)

    public var canRetry: Bool { self != .missingSource && self != .unsupportedSource }
    public var message: String {
        switch self {
        case .missingSource: return "这个视频没有提供封面"
        case .unsupportedSource: return "这个视频的封面地址不可用"
        case .network(.timedOut): return "加载超时，请重试"
        case .network(.cancelled): return "加载已中断，请重试"
        case .network: return "网络连接异常，请重试"
        case .http: return "封面暂时无法访问，请重试"
        case .invalidImage, .tooLarge: return "封面暂时无法显示，请重试"
        }
    }
}

public struct CoverImageSource: Sendable {
    public let candidates: [URL]
    public init(_ value: String, avatar: Bool = false) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CoverImageError.missingSource }
        guard var parts = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value),
              let host = parts.host?.lowercased(),
              ["hdslb.com", "biliimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else {
            throw CoverImageError.unsupportedSource
        }
        parts.scheme = "https"
        parts.fragment = nil
        guard let original = parts.url else { throw CoverImageError.unsupportedSource }
        // Preserve signed queries and existing CDN transforms verbatim. Try the
        // unmodified source if our optional resize is unavailable or undecodable.
        if parts.query == nil, !parts.path.contains("@"),
           let resized = URL(string: original.absoluteString + (avatar ? "@160w_160h_1c.webp" : "@640w_360h_1c.webp")) {
            candidates = [resized, original]
        } else { candidates = [original] }
    }
}

public protocol CoverImageServing: Sendable {
    func image(for source: String) async throws -> CoverImage
}

public actor CoverImageLoader: CoverImageServing {
    public static let shared = CoverImageLoader()
    private let session: URLSession
    private let cache = NSCache<NSString, CoverImage>()
    private var pending: [String: Task<CoverImage, Error>] = [:]

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    public func image(for source: String) async throws -> CoverImage {
        try await load(CoverImageSource(source).candidates)
    }
    public func avatar(for source: String) async throws -> CoverImage {
        try await load(CoverImageSource(source, avatar: true).candidates)
    }
    private func load(_ candidates: [URL]) async throws -> CoverImage {
        let key = candidates[0].absoluteString
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = pending[key] { return try await task.value }
        let session = session
        // Unstructured work deliberately outlives any one LazyVGrid cell's task.
        // Cancelling an offscreen consumer must not cancel a shared download or
        // leave that cell permanently in AsyncImage's -999 failure phase.
        let task = Task.detached(priority: .utility) {
            var failure: CoverImageError = .invalidImage
            for url in candidates {
                do { return try await Self.download(url, session: session) }
                catch let error as CoverImageError { failure = error }
                catch let error as URLError { failure = .network(error.code) }
                catch { failure = .network(.unknown) }
            }
            throw failure
        }
        pending[key] = task
        defer { pending[key] = nil }
        let image = try await task.value
        cache.setObject(image, forKey: key as NSString, cost: image.image.bytesPerRow * image.image.height)
        return image
    }

    private nonisolated static func download(_ url: URL, session: URLSession) async throws -> CoverImage {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        BilibiliClient.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("image/webp,image/*;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoverImageError.invalidImage }
        guard (200..<300).contains(http.statusCode) else { throw CoverImageError.http(http.statusCode) }
        guard bytes.count <= 20 * 1024 * 1024 else { throw CoverImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CoverImageError.invalidImage }
        return CoverImage(image)
    }
}
