import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import BiliMacCore
@testable import BiliMac

private func coverPNG(width: Int = 2, height: Int = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct CoverReply {
    var status = 200
    var bytes = Data()
    var error: URLError?
    var held = false
}

private final class CoverScenario: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var replies: [CoverReply]
    private var requests: [URLRequest] = []
    private var held: [CoverProtocol] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stops = 0

    init(_ replies: [CoverReply]) { self.replies = replies; CoverProtocol.register(self) }
    func loader() -> CoverImageLoader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoverProtocol.self]
        config.httpAdditionalHeaders = ["X-Cover-Test": id]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return CoverImageLoader(session: URLSession(configuration: config))
    }
    var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func stopped() { lock.lock(); stops += 1; lock.unlock() }
    func serve(_ source: CoverProtocol) {
        lock.lock()
        requests.append(source.request)
        let reply = replies.isEmpty ? CoverReply(status: 500) : replies.removeFirst()
        if reply.held { held.append(source) }
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        lock.unlock()
        ready.forEach { $0.1.resume() }
        if !reply.held { source.complete(reply) }
    }
    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requests.count >= count { lock.unlock(); continuation.resume() }
            else { waiters.append((count, continuation)); lock.unlock() }
        }
    }
    func release(_ reply: CoverReply) {
        lock.lock(); let pending = held; held = []; lock.unlock()
        pending.forEach { $0.complete(reply) }
    }
}

private final class CoverProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var scenarios: [String: CoverScenario] = [:]
    static func register(_ scenario: CoverScenario) {
        lock.lock(); scenarios[scenario.id] = scenario; lock.unlock()
    }
    private var scenario: CoverScenario? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return request.value(forHTTPHeaderField: "X-Cover-Test").flatMap { Self.scenarios[$0] }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Cover-Test") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { scenario?.serve(self) }
    override func stopLoading() { scenario?.stopped() }
    func complete(_ reply: CoverReply) {
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CoverImageTests {
    @Test func validatesAndNormalizesOfficialImageURLs() throws {
        let source = try CoverImageSource("  //i0.hdslb.com/bfs/archive/a.jpg\n")
        #expect(source.candidates.map(\.absoluteString) == ["https://i0.hdslb.com/bfs/archive/a.jpg@640w_360h_1c.webp", "https://i0.hdslb.com/bfs/archive/a.jpg"])
        #expect(try CoverImageSource("http://archive.biliimg.com/a.png").candidates.last?.scheme == "https")
        #expect(throws: CoverImageError.missingSource) { try CoverImageSource(" \n") }
        for url in ["https://hdslb.com.evil.test/a.jpg", "file:///tmp/a.jpg", "https://evil.test/a.jpg",
                    "https://user:password@i0.hdslb.com/a.jpg", "https://i0.hdslb.com:80/a.jpg"] {
            #expect(throws: CoverImageError.unsupportedSource) { try CoverImageSource(url) }
        }
    }
    @Test func keepsExistingTransformsAndSignedQueries() throws {
        for url in ["https://i0.hdslb.com/a.jpg@320w_180h.webp", "https://i0.hdslb.com/a.jpg?token=x%2By&size=2"] {
            #expect(try CoverImageSource(url).candidates.map(\.absoluteString) == [url])
        }
    }
    @Test(arguments: [false, true]) func resizeFailureFallsBackToDecodableOriginal(invalidData: Bool) async throws {
        let scenario = CoverScenario([invalidData ? .init(bytes: Data("not an image".utf8)) : .init(status: 403), .init(bytes: try coverPNG())])
        let image = try await scenario.loader().image(for: "https://i0.hdslb.com/a.jpg")
        #expect(image.image.width == 2); #expect(image.image.height == 1)
        let requests = scenario.recorded
        #expect(requests.map { $0.url!.absoluteString } == ["https://i0.hdslb.com/a.jpg@640w_360h_1c.webp", "https://i0.hdslb.com/a.jpg"])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/")
            #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
    @Test func retryIsANewRequestAndOnlySuccessIsCached() async throws {
        let scenario = CoverScenario([.init(error: URLError(.timedOut)), .init(status: 503), .init(bytes: try coverPNG())])
        let loader = scenario.loader()
        let url = "https://i0.hdslb.com/retry.jpg"
        await #expect(throws: CoverImageError.http(503)) { try await loader.image(for: url) }
        let recovered = try await loader.image(for: url)
        let cached = try await loader.image(for: url)
        #expect(recovered === cached); #expect(scenario.recorded.count == 3)
    }
    @Test func cancelledCellDoesNotCancelSharedDownloadOrPoisonReappearance() async throws {
        let scenario = CoverScenario([.init(held: true)])
        let loader = scenario.loader(); let url = "https://i0.hdslb.com/scroll.jpg"
        let offscreenCell = Task { try await loader.image(for: url) }
        await scenario.waitForRequests(1)
        offscreenCell.cancel()
        let visibleCell = Task { try await loader.image(for: url) }
        #expect(scenario.stopCount == 0)
        scenario.release(.init(bytes: try coverPNG()))
        let first = try await offscreenCell.value
        let second = try await visibleCell.value
        let reappeared = try await loader.image(for: url)
        #expect(first === second); #expect(second === reappeared)
        #expect(scenario.recorded.count == 1)
    }
    @Test func invalidImagesAndNetworkErrorsProduceRetryableFailures() async throws {
        let invalid = CoverScenario([.init(bytes: Data("html".utf8))])
        await #expect(throws: CoverImageError.invalidImage) { try await invalid.loader().image(for: "https://i0.hdslb.com/a.jpg?original=1") }
        let cancelled = CoverScenario([.init(error: URLError(.cancelled))])
        await #expect(throws: CoverImageError.network(.cancelled)) { try await cancelled.loader().image(for: "https://i0.hdslb.com/a.jpg?original=1") }
        #expect(CoverImageError.network(.cancelled).canRetry)
        #expect(CoverImageError.network(.timedOut).message.contains("超时"))
        #expect(!CoverImageError.missingSource.canRetry); #expect(!CoverImageError.unsupportedSource.canRetry)
    }
    @Test func downsamplesLargeSources() async throws {
        let scenario = CoverScenario([.init(bytes: try coverPNG(width: 2560, height: 1440))])
        let image = try await scenario.loader().image(for: "https://i0.hdslb.com/large.png")
        #expect(image.image.width == 1280); #expect(image.image.height == 720)
    }
}

private actor ControlledCoverLoader: CoverImageServing {
    private var pending: [String: CheckedContinuation<CoverImage, Error>] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    func image(for source: String) async throws -> CoverImage {
        try await withCheckedThrowingContinuation {
            pending[source] = $0; waiting.removeValue(forKey: source)?.resume()
        }
    }
    func waitForRequest(_ source: String) async {
        if pending[source] != nil { return }
        await withCheckedContinuation { waiting[source] = $0 }
    }
    func resolve(_ source: String, _ result: Result<CoverImage, Error>) { pending.removeValue(forKey: source)?.resume(with: result) }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct ThumbnailModelTests {
    private func image() throws -> CoverImage {
        let source = try #require(CGImageSourceCreateWithData(try coverPNG() as CFData, nil))
        return CoverImage(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }
    @Test func oldResponseCannotReplaceANewURL() async throws {
        let loader = ControlledCoverLoader(); let model = ThumbnailModel(loader: loader)
        let old = Task { await model.load("old") }; await loader.waitForRequest("old")
        let new = Task { await model.load("new") }; await loader.waitForRequest("new")
        let newest = try image(); await loader.resolve("new", .success(newest)); await new.value
        await loader.resolve("old", .failure(CoverImageError.network(.timedOut))); await old.value
        #expect(model.image === newest); #expect(model.failure == nil); #expect(!model.loading)
    }
    @Test func cancellationIsIgnoredAndReappearanceCanRecover() async throws {
        let loader = ControlledCoverLoader(); let model = ThumbnailModel(loader: loader)
        let offscreen = Task { await model.load("same") }; await loader.waitForRequest("same")
        offscreen.cancel(); await loader.resolve("same", .failure(CoverImageError.network(.cancelled))); await offscreen.value
        #expect(model.failure == nil); #expect(!model.loading)
        let visible = Task { await model.load("same") }; await loader.waitForRequest("same")
        let recovered = try image(); await loader.resolve("same", .success(recovered)); await visible.value
        #expect(model.image === recovered); #expect(model.failure == nil)
    }
    @Test func failureRetryClearsMessageThenDisplaysNewImage() async throws {
        let loader = ControlledCoverLoader(); let model = ThumbnailModel(loader: loader)
        let failed = Task { await model.load("retry") }; await loader.waitForRequest("retry")
        await loader.resolve("retry", .failure(CoverImageError.network(.timedOut))); await failed.value
        #expect(model.failure == .network(.timedOut)); #expect(model.image == nil); #expect(!model.loading)
        let retry = Task { await model.load("retry") }; await loader.waitForRequest("retry")
        #expect(model.loading); #expect(model.failure == nil)
        await loader.resolve("retry", .success(try image())); await retry.value
        #expect(model.image != nil); #expect(model.failure == nil); #expect(!model.loading)
    }
}
