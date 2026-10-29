import Foundation
@preconcurrency import Network

/// Minimal, session-scoped HTTP surface. No filesystem or arbitrary URL routes.
final class LocalMediaService: @unchecked Sendable {
    private let routes: [String:LocalResource]
    private let reader: any MediaReading
    private let budget = DeliveryBudget()
    private let token = UUID().uuidString+UUID().uuidString
    private let queue = DispatchQueue(label:"dev.zzpp.BiliMac.media",qos:.userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var host = ""
    private var closed = false
    private var starter: CheckedContinuation<URL,any Error>?
    private var connections: [UUID:NWConnection] = [:]
    private var tasks: [UUID:Task<Void,Never>] = [:]
    private var failure: String?
    var lastFailure: String? { locked { failure } }
    init(routes: [String:LocalResource], reader: any MediaReading) { self.routes = routes; self.reader = reader }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func open() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
                    let listener = try NWListener(using:parameters)
                    listener.stateUpdateHandler = { [weak self,weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port else { self.close(); return }
                            let output = self.locked { () -> CheckedContinuation<URL,any Error>? in
                                guard !self.closed else { return nil }
                                self.host = "127.0.0.1:\(port.rawValue)"; let value = self.starter; self.starter = nil; return value
                            }
                            if let output { output.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/\(self.token)/main.m3u8")!) }
                        case .failed, .cancelled: self.close()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    let accepted = locked { () -> Bool in
                        guard !closed else { return false }
                        starter = continuation; self.listener = listener; listener.start(queue:queue); return true
                    }
                    if !accepted { listener.cancel(); continuation.resume(throwing:MediaFailure.closed) }
                } catch { continuation.resume(throwing:MediaFailure.localService) }
            }
        } onCancel: { self.close() }
    }
    func close() {
        let old = locked { () -> (NWListener?,CheckedContinuation<URL,any Error>?,[NWConnection],[Task<Void,Never>]) in
            guard !closed else { return (nil,nil,[],[]) }
            closed = true
            let values = (listener,starter,Array(connections.values),Array(tasks.values))
            listener = nil; starter = nil; connections = [:]; tasks = [:]; return values
        }
        old.0?.cancel(); old.1?.resume(throwing:MediaFailure.closed)
        old.3.forEach { $0.cancel() }; old.2.forEach { $0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let accepted = locked { () -> Bool in
            guard !closed, connections.count < 12 else { return false }
            connections[id] = connection; connection.start(queue:queue)
            tasks[id] = Task { [self] in
                defer { locked { connections[id] = nil; tasks[id] = nil }; connection.cancel() }
                let deadline = Task { try? await Task.sleep(for:.seconds(35)); if !Task.isCancelled { connection.cancel() } }
                defer { deadline.cancel() }
                do { try await respond(connection) }
                catch { connection.cancel() }
            }
            return true
        }
        if !accepted { connection.cancel() }
    }
    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength:1,maximumLength:4_096) { data,_,end,error in
                if let error { continuation.resume(throwing:error) }
                else if let data, !data.isEmpty { continuation.resume(returning:data) }
                else { continuation.resume(throwing:end ? MediaFailure.closed : MediaFailure.invalidResponse) }
            }
        }
    }
    private func send(_ data: Data, on connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,any Error>) in
            connection.send(content:data,completion:.contentProcessed { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            })
        }
    }
    private func respond(_ connection: NWConnection) async throws {
        let headerDeadline = Task { try? await Task.sleep(for:.seconds(5)); if !Task.isCancelled { connection.cancel() } }
        defer { headerDeadline.cancel() }
        var data = Data()
        let ending = Data([13,10,13,10])
        while data.range(of:ending) == nil {
            data.append(try await receive(connection))
            guard data.count <= 16_384 else { try await status(431,on:connection); return }
        }
        headerDeadline.cancel()
        let request: MediaRequest
        do { request = try MediaRequest.decode(data) }
        catch { try await status(400,on:connection); return }
        guard request.headers["host"] == locked({ host }) else { try await status(403,on:connection); return }
        guard ["GET","HEAD"].contains(request.method) else { try await status(405,on:connection); return }
        let prefix = "/"+token+"/"
        guard request.target.hasPrefix(prefix), let resource = routes[String(request.target.dropFirst(prefix.count))] else {
            try await status(404,on:connection); return
        }
        let range: ByteSpan
        do { range = try request.headers["range"].map { try ByteSpan.parse($0,size:resource.length) } ?? ByteSpan(offset:0,length:resource.length) }
        catch { try await status(416,on:connection,extra:"Content-Range: bytes */\(resource.length)\r\n"); return }
        let partial = request.headers["range"] != nil
        let header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(resource.mime)\r\nContent-Length: \(range.length)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n" + (partial ? "Content-Range: bytes \(range.offset)-\(range.end)/\(resource.length)\r\n" : "") + "\r\n"
        if request.method == "HEAD" { try await send(Data(header.utf8),on:connection); return }
        switch resource {
        case .memory(let bytes,_):
            try await send(Data(header.utf8),on:connection)
            try await send(bytes.subdata(in:Int(range.offset)..<Int(range.offset+range.length)),on:connection)
        case .fragment(let source,_):
            try await budget.acquire()
            do {
                try Task.checkCancellation()
                let upstream = try ByteSpan(offset:source.span.offset+range.offset,length:range.length)
                let slice: MediaSlice
                do {
                    slice = try await reader.read(url:source.url,span:upstream,completeLength:source.total,headers:source.headers)
                    guard slice.bytes.count == Int(range.length), slice.completeLength == source.total else { throw MediaFailure.invalidResponse }
                } catch {
                    locked { failure = (error as? MediaFailure)?.localizedDescription ?? "媒体传输中断，请重试。" }
                    try await status(502,on:connection); await budget.release(); return
                }
                try await send(Data(header.utf8),on:connection)
                for lower in stride(from:0,to:slice.bytes.count,by:65_536) {
                    try await send(slice.bytes.subdata(in:lower..<min(lower+65_536,slice.bytes.count)),on:connection)
                }
                await budget.release()
            } catch { await budget.release(); throw error }
        }
    }
    private func status(_ code: Int, on connection: NWConnection, extra: String = "") async throws {
        try await send(Data("HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\(extra)\r\n".utf8),on:connection)
    }
    deinit { close() }
}

struct MediaRequest {
    let method: String
    let target: String
    let headers: [String:String]
    static func decode(_ data: Data) throws -> MediaRequest {
        guard let text = String(data:data,encoding:.utf8), text.hasSuffix("\r\n\r\n"),
              !text.utf8.contains(0) else { throw MediaFailure.invalidResponse }
        let lines = text.components(separatedBy:"\r\n")
        let first = lines[0].split(separator:" ",omittingEmptySubsequences:false)
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"),
              !first[1].contains("%"), !first[1].contains(".."), !first[1].contains("?"), !first[1].contains("#") else { throw MediaFailure.invalidResponse }
        var headers: [String:String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of:":") else { throw MediaFailure.invalidResponse }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil else { throw MediaFailure.invalidResponse }
            let value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !value.contains(where: { $0.isNewline }) else { throw MediaFailure.invalidResponse }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0" else { throw MediaFailure.invalidResponse }
        return .init(method:String(first[0]),target:String(first[1]),headers:headers)
    }
}
