import Foundation
import BiliMacMedia

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A credential-bearing API request must never follow an off-host redirect.
        completionHandler(task.originalRequest?.httpMethod != "POST" && request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}

public actor BilibiliClient {
    public static let mediaHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36", "Referer": "https://www.bilibili.com/"]
    let session: URLSession
    private var cookies: [String: String] = [:]
    private var key: String?
    private var generation = UUID()
    var authenticationID: UUID { generation }
    public init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        self.session = session ?? URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }
    public func setCookies(_ values: [String: String]) {
        let allowed: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
        cookies = values.filter { allowed.contains($0.key) && !$0.value.isEmpty && $0.value.count < 8192 && !$0.value.contains(where: { $0 == ";" || $0.isNewline }) }
        generation = UUID(); key = nil
    }
    func request(_ path: String, query: [String: String] = [:], signed: Bool = false, passport: Bool = false) async throws -> (data: [String: Any], response: HTTPURLResponse) {
        let identity = generation
        var values = query
        if signed {
            if key == nil { _ = try await account() }
            guard identity == generation else { throw CancellationError() }
            guard let key else { throw ClientError.invalidResponse }
            values = WBISigning.sign(values, key: key)
        }
        var components = URLComponents(string: (passport ? "https://passport.bilibili.com" : "https://api.bilibili.com") + path)!
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if path == "/x/space/wbi/arc/search", let mid = query["mid"], (Int(mid) ?? 0) > 0 {
            request.setValue("https://space.bilibili.com/\(mid)/upload/video", forHTTPHeaderField: "Referer")
        }
        request.setValue(cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard identity == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard response.statusCode == 200 else { throw ClientError.http(response.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let code = root["code"] as? Int else { throw ClientError.invalidResponse }
        guard code == 0 || (path == "/x/web-interface/nav" && code == -101) else {
            throw ClientError.server(code, root["message"] as? String ?? "请求未成功")
        }
        let result = root["data"] as? [String: Any] ?? [:]
        if (result["v_voucher"] as? String)?.isEmpty == false || result["need_captcha"] as? Bool == true {
            throw ClientError.server(-352, "需要完成官方验证")
        }
        return (result, response)
    }
    func requireAccount(_ mid: Int) throws {
        guard mid > 0, cookies["SESSDATA"] != nil, Int(cookies["DedeUserID"] ?? "") == mid else { throw ClientError.authenticationRequired }
    }
    // Only explicitly supported account writes can carry credentials.
    // Transport failures are ambiguous: a server may already have applied the write.
    func postAuthenticated(_ path: String, values: [String: String], mid: Int, bvid: String? = nil) async throws -> [String: Any] {
        try requireAccount(mid)
        guard ["/x/v3/fav/resource/deal", "/x/v3/fav/folder/add", "/x/v2/history/toview/add", "/x/v2/history/toview/del",
               "/x/web-interface/archive/like", "/x/web-interface/coin/add", "/x/web-interface/archive/like/triple",
               "/x/v2/reply/add", "/x/v2/reply/action", "/x/v2/reply/del", "/x/relation/modify"].contains(path),
              let csrf = cookies["bili_jct"], !csrf.isEmpty else { throw ClientError.authenticationRequired }
        try Task.checkCancellation()
        let identity = generation
        var request = URLRequest(url: URL(string: "https://api.bilibili.com" + path)!)
        request.httpMethod = "POST"
        var form = values; form["csrf"] = csrf
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let bvid, VideoInput.bvid(bvid) == bvid { request.setValue("https://www.bilibili.com/video/" + bvid + "/", forHTTPHeaderField: "Referer") }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await session.data(for: request)
            guard identity == generation else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let code = root["code"] as? Int else { throw ClientError.writeUncertain }
            guard code == 0 else { throw ClientError.server(code, root["message"] as? String ?? "操作未成功") }
            let result = root["data"] as? [String: Any] ?? [:]
            if result["need_captcha"] as? Bool == true || (result["v_voucher"] as? String)?.isEmpty == false {
                throw ClientError.server(-352, "需要完成官方验证")
            }
            return result
        } catch {
            guard identity == generation else { throw CancellationError() }
            if case ClientError.server = error { throw error }
            throw ClientError.writeUncertain
        }
    }
    func prepareInteraction(mid: Int) async throws {
        try requireAccount(mid)
        guard cookies["bili_jct"] != nil else { throw ClientError.authenticationRequired }
        try await prepareBrowsingIdentifier()
    }
    func prepareBrowsingIdentifier() async throws {
        guard cookies["buvid3"] == nil else { return }
        let identity = generation
        let result = try await request("/x/frontend/finger/spi").data
        try Task.checkCancellation()
        guard identity == generation else { throw CancellationError() }
        func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count < 8192 && !value.contains(where: { $0 == ";" || $0.isNewline }) }
        guard let id = result["b_3"] as? String, valid(id) else { throw ClientError.invalidResponse }
        cookies["buvid3"] = id
        if let id = result["b_4"] as? String, valid(id) { cookies["buvid4"] = id }
    }
    public func account() async throws -> Account? {
        let data = try await request("/x/web-interface/nav").data
        if let wbi = data["wbi_img"] as? [String: String], let image = wbi["img_url"].flatMap(URL.init(string:)), let sub = wbi["sub_url"].flatMap(URL.init(string:)) {
            key = WBISigning.mixin(image.deletingPathExtension().lastPathComponent + sub.deletingPathExtension().lastPathComponent)
        }
        guard data["isLogin"] as? Bool == true else { return nil }
        return Account(id: integer(data["mid"]), name: data["uname"] as? String ?? "已登录")
    }
    public func feed(recommended: Bool, page: Int) async throws -> [Video] {
        let data: [String: Any]
        if recommended {
            data = try await request("/x/web-interface/wbi/index/top/feed/rcmd", query: ["ps":"24", "fresh_idx":"\(page)", "fresh_idx_1h":"\(page)", "fresh_type":"3", "feed_version":"V8", "homepage_ver":"1", "y_num":"4"], signed: true).data
        } else { data = try await request("/x/web-interface/popular", query: ["pn":"\(page)", "ps":"24"]).data }
        guard let rows = data[recommended ? "item" : "list"] as? [[String: Any]] else { throw ClientError.invalidResponse }
        return Video.unique(rows.compactMap(Video.parse))
    }
    public func search(_ term: String, page: Int) async throws -> [Video] {
        let data = try await request("/x/web-interface/wbi/search/type", query: ["search_type":"video", "keyword":term, "page":"\(page)", "page_size":"24"], signed: true).data
        return Video.unique((data["result"] as? [[String: Any]] ?? []).compactMap(Video.parse))
    }
    public func detail(_ bvid: String) async throws -> VideoDetail {
        let data = try await request("/x/web-interface/wbi/view", query: ["bvid": bvid], signed: true).data
        guard let video = Video.parse(data) else { throw ClientError.invalidResponse }
        let pages = (data["pages"] as? [[String: Any]] ?? []).compactMap { row -> VideoPage? in
            let cid = integer(row["cid"]); guard cid > 0 else { return nil }
            return VideoPage(id: cid, title: row["part"] as? String ?? "正片", duration: integer(row["duration"]))
        }
        guard !pages.isEmpty else { throw ClientError.noPlayableMedia }
        return VideoDetail(video: video, description: data["desc"] as? String ?? "", pages: pages)
    }
    public func manifest(bvid: String, cid: Int) async throws -> PlaybackManifest {
        let data = try await request("/x/player/playurl", query: ["bvid":bvid, "cid":"\(cid)", "qn":"127", "fnval":"4048", "fnver":"0", "fourk":"1", "try_look":cookies["SESSDATA"] == nil ? "1" : "0"]).data
        return try Self.parseManifest(data)
    }
    public static func parseManifest(_ data: [String: Any]) throws -> PlaybackManifest {
        guard let dash = data["dash"] as? [String: Any] else { throw ClientError.noPlayableMedia }
        func parse(_ row: [String: Any], kind: TrackKind) -> MediaTrack? {
            let raw = [row["baseUrl"] as? String, row["base_url"] as? String].compactMap { $0 } + (row["backupUrl"] as? [String] ?? []) + (row["backup_url"] as? [String] ?? [])
            var seen = Set<URL>()
            let urls = raw.compactMap { MediaOrigin.normalizedURL($0) }.filter { seen.insert($0).inserted }
            guard let first = urls.first, let segment = row["SegmentBase"] as? [String: Any] ?? row["segment_base"] as? [String: Any] else { return nil }
            func range(_ value: Any?) -> ByteSpan? {
                let parts = (value as? String ?? "").split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]) else { return nil }
                guard start >= 0, end >= start, end < Int64.max else { return nil }
                return try? ByteSpan(offset: start, length: end-start+1)
            }
            guard let initial = range(segment["Initialization"] ?? segment["initialization"]), let index = range(segment["indexRange"] ?? segment["index_range"]) else { return nil }
            let codec = row["codecs"] as? String ?? ""
            guard kind == .video ? codec.hasPrefix("avc1") : codec.hasPrefix("mp4a") else { return nil }
            let width = integer(row["width"]), height = integer(row["height"])
            if kind == .video && (width <= 0 || height <= 0) { return nil }
            return try? MediaTrack(id: integer(row["id"]), kind: kind, codec: codec,
                bandwidth: max(0, integer(row["bandwidth"])), width: width, height: height,
                urls: [first] + Array(urls.dropFirst()), initialization: initial, index: index)
        }
        let videos = (dash["video"] as? [[String: Any]] ?? []).compactMap { parse($0, kind: .video) }.sorted { $0.id > $1.id }
        let audios = (dash["audio"] as? [[String: Any]] ?? []).compactMap { parse($0, kind: .audio) }
        guard !videos.isEmpty, let audio = audios.max(by: { $0.bandwidth < $1.bandwidth }) else { throw ClientError.noPlayableMedia }
        var names: [Int: String] = [:]
        for row in data["support_formats"] as? [[String: Any]] ?? [] { names[integer(row["quality"])] = row["new_description"] as? String ?? row["display_desc"] as? String }
        return PlaybackManifest(videos: videos, audio: audio, qualityNames: names)
    }
    public func qrCode() async throws -> QRCode {
        let data = try await request("/x/passport-login/web/qrcode/generate", passport: true).data
        guard let key = data["qrcode_key"] as? String, let url = data["url"] as? String,
              let parsed = URL(string: url), parsed.scheme == "https", parsed.user == nil, parsed.password == nil,
              ["passport.bilibili.com", "account.bilibili.com"].contains(parsed.host?.lowercased() ?? "") else { throw ClientError.invalidResponse }
        return QRCode(key: key, url: url)
    }
    public func pollQR(_ key: String) async throws -> QRStatus {
        let result = try await request("/x/passport-login/web/qrcode/poll", query: ["qrcode_key":key], passport: true)
        switch integer(result.data["code"]) {
        case 86101: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            let fields = result.response.allHeaderFields.reduce(into: [String: String]()) { if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v } }
            var cookies = Dictionary(HTTPCookie.cookies(withResponseHeaderFields: fields, for: URL(string: "https://passport.bilibili.com/")!).map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b })
            if let url = result.data["url"] as? String, let components = URLComponents(string: url) {
                for item in components.queryItems ?? [] { if cookies[item.name] == nil { cookies[item.name] = item.value } }
            }
            let allowed: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
            cookies = cookies.filter { allowed.contains($0.key) && !$0.value.isEmpty && !$0.value.contains(where: { $0 == ";" || $0.isNewline }) }
            guard cookies["SESSDATA"] != nil, cookies["bili_jct"] != nil, cookies["DedeUserID"] != nil else { throw ClientError.invalidResponse }
            return .confirmed(cookies)
        default: throw ClientError.invalidResponse
        }
    }
    public func danmaku(cid: Int, segment: Int) async throws -> [Danmaku] {
        var url = URLComponents(string: "https://api.bilibili.com/x/v2/dm/web/seg.so")!
        url.queryItems = [URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "oid", value: "\(cid)"), URLQueryItem(name: "segment_index", value: "\(segment)")]
        var request = URLRequest(url: url.url!); Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 16 * 1024 * 1024 else { throw ClientError.invalidResponse }
        return try DanmakuDecoder.decode(data)
    }
}
