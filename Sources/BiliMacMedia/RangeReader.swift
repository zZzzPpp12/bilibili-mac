import Foundation

public struct MediaSlice: Sendable {
    public let bytes: Data
    public let completeLength: Int64
    public init(bytes: Data, completeLength: Int64) { self.bytes = bytes; self.completeLength = completeLength }
}
public protocol MediaReading: Sendable {
    func read(url: URL, span: ByteSpan, completeLength: Int64?, headers: [String:String]) async throws -> MediaSlice
}

/// First implementation buffers one bounded virtual fragment, never a movie.
/// Headers are validated before accepting any body. A service holds its delivery
/// permit until the downstream send finishes, so slow readers cannot build a queue
/// of fully downloaded fragments. Streaming/cache refinements can keep this API.
public struct HTTPMediaReader: MediaReading {
    private let configuration: @Sendable () -> URLSessionConfiguration
    public init() { configuration = { .ephemeral } }
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) { self.configuration = configuration }
    public func read(url: URL, span: ByteSpan, completeLength: Int64? = nil, headers: [String:String] = [:]) async throws -> MediaSlice {
        guard MediaOrigin.allows(url) else { throw MediaFailure.untrustedSource }
        guard span.length <= 16*1_024*1_024 else { throw MediaFailure.oversizedResource }
        let transfer = RangeTransfer(url:url,span:span,expectedLength:completeLength,headers:headers,configuration:configuration)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); return try await transfer.run()
        } onCancel: { transfer.cancel() }
    }
}

struct RangeReceipt {
    let total: Int64
    static func check(_ response: HTTPURLResponse, span: ByteSpan, total: Int64?) throws -> RangeReceipt {
        guard response.statusCode == 206 else { throw MediaFailure.http(response.statusCode) }
        let encoding = response.value(forHTTPHeaderField:"Content-Encoding")?.lowercased() ?? "identity"
        guard encoding == "identity", let field = response.value(forHTTPHeaderField:"Content-Range"), field.hasPrefix("bytes ") else { throw MediaFailure.invalidResponse }
        let parts = field.dropFirst(6).split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count == 2, let complete = Int64(parts[1]), complete > 0 else { throw MediaFailure.invalidResponse }
        let bounds = parts[0].split(separator:"-",omittingEmptySubsequences:false)
        guard bounds.count == 2, Int64(bounds[0]) == span.offset, Int64(bounds[1]) == span.end,
              span.end < complete, total == nil || total == complete else { throw MediaFailure.invalidResponse }
        if let text = response.value(forHTTPHeaderField:"Content-Length") {
            guard Int64(text) == span.length else { throw MediaFailure.invalidResponse }
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard ["video/mp4","audio/mp4","application/octet-stream","video/iso.segment"].contains(mime) else { throw MediaFailure.invalidResponse }
        return .init(total:complete)
    }
}

private final class RangeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL, span: ByteSpan, expectedLength: Int64?, headers: [String:String]
    private let configuration: @Sendable () -> URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaSlice,any Error>?
    private var result: Result<MediaSlice,any Error>?
    private var session: URLSession?
    private var receipt: RangeReceipt?
    private var buffer = Data()
    init(url: URL, span: ByteSpan, expectedLength: Int64?, headers: [String:String], configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.configuration = configuration
        self.url = url; self.span = span; self.expectedLength = expectedLength; self.headers = headers
    }
    func run() async throws -> MediaSlice {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with:result); return }
            self.continuation = continuation
            let config = configuration()
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40
            let session = URLSession(configuration:config,delegate:self,delegateQueue:nil); self.session = session
            var request = URLRequest(url:url)
            for (name,value) in headers where ["user-agent","referer"].contains(name.lowercased()) && !value.contains(where: { $0.isNewline }) {
                request.setValue(value,forHTTPHeaderField:name)
            }
            request.setValue(span.header,forHTTPHeaderField:"Range"); request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            let task = session.dataTask(with:request)
            lock.unlock(); task.resume()
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<MediaSlice,any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; buffer = Data(); lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with:result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw MediaFailure.invalidResponse }
            let value = try RangeReceipt.check(response,span:span,total:expectedLength)
            lock.lock(); receipt = value; let open = result == nil; lock.unlock()
            completionHandler(open ? .allow : .cancel)
        } catch { completionHandler(.cancel); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard receipt != nil, data.count <= Int(span.length)-buffer.count else {
            lock.unlock(); finish(.failure(MediaFailure.invalidResponse)); return
        }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let output: Result<MediaSlice,any Error>
        if let error { output = .failure(error) }
        else if let receipt, buffer.count == Int(span.length) { output = .success(.init(bytes:buffer,completeLength:receipt.total)) }
        else { output = .failure(MediaFailure.invalidResponse) }
        lock.unlock(); finish(output)
    }
}

actor DeliveryBudget {
    private var active = 0
    private var waiting: [(UUID,CheckedContinuation<Void,any Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,any Error>) in
                if Task.isCancelled { continuation.resume(throwing:CancellationError()) }
                else { waiting.append((id,continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        if !waiting.isEmpty { waiting.removeFirst().1.resume() }
        else { active -= 1 }
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at:index).1.resume(throwing:CancellationError()) }
    }
}
