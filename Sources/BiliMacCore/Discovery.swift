import Foundation

public enum ContentRegion: Int, CaseIterable, Identifiable, Sendable, Codable {
    case all = 0, animation = 1, music = 3, games = 4, dance = 129, knowledge = 36, technology = 188
    case life = 160, food = 211, animals = 217, fashion = 155, entertainment = 5, cinema = 181
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .all: "全部"; case .animation: "动画"; case .music: "音乐"; case .games: "游戏"; case .dance: "舞蹈"
        case .knowledge: "知识"; case .technology: "科技"; case .life: "生活"; case .food: "美食"
        case .animals: "动物圈"; case .fashion: "时尚"; case .entertainment: "娱乐"; case .cinema: "影视"
        }
    }
}
public enum VideoSearchOrder: String, CaseIterable, Identifiable, Sendable, Codable {
    case official = "综合排序", smart = "智能相关", views = "最多播放", latest = "最新发布", danmaku = "最多弹幕", favorites = "最多收藏"
    public var id: Self { self }
    var query: String { switch self { case .official, .smart: "totalrank"; case .views: "click"; case .latest: "pubdate"; case .danmaku: "dm"; case .favorites: "stow" } }
}
public enum VideoDuration: Int, CaseIterable, Identifiable, Sendable, Codable {
    case any = 0, short = 1, medium = 2, long = 3, veryLong = 4
    public var id: Self { self }
    public var title: String { switch self { case .any: "不限时长"; case .short: "10 分钟以内"; case .medium: "10–30 分钟"; case .long: "30–60 分钟"; case .veryLong: "60 分钟以上" } }
    public func matches(_ seconds: Int) -> Bool {
        switch self { case .any: true; case .short: seconds > 0 && seconds < 600; case .medium: (600..<1800).contains(seconds); case .long: (1800..<3600).contains(seconds); case .veryLong: seconds >= 3600 }
    }
}
public enum PublicationWindow: Int, CaseIterable, Identifiable, Sendable, Codable {
    case any = 0, day = 1, week = 7, month = 30, year = 365
    public var id: Self { self }
    public var title: String { switch self { case .any: "不限时间"; case .day: "最近一天"; case .week: "最近一周"; case .month: "最近一月"; case .year: "最近一年" } }
    public func matches(_ date: Date?, now: Date) -> Bool {
        self == .any || date.map { $0 <= now && $0 >= now.addingTimeInterval(-Double(rawValue) * 86400) } == true
    }
}
public enum VideoCopyright: Int, CaseIterable, Identifiable, Sendable, Codable {
    case any = 0, original = 1, repost = 2
    public var id: Self { self }
    public var title: String { switch self { case .any: "全部来源"; case .original: "原创"; case .repost: "转载" } }
}
public struct VideoSearchOptions: Hashable, Sendable {
    public var order: VideoSearchOrder = .official
    public var duration: VideoDuration = .any
    public var published: PublicationWindow = .any
    public var region: ContentRegion = .all
    public var copyright: VideoCopyright = .any
    public init() {}
}
public struct VideoSearchPage: Sendable {
    public let items: [Video]
    public let total: Int?
    public let hasMore: Bool
    public init(items: [Video], total: Int?, hasMore: Bool) { self.items = items; self.total = total; self.hasMore = hasMore }
}
public enum DiscoverySource: String, Hashable, Sendable { case recommended, popular, regions }
public enum DiscoveryOrder: String, CaseIterable, Identifiable, Sendable {
    case official = "B 站原序", balanced = "多样发现", latest = "最新发布", views = "最多播放"
    public var id: Self { self }
}
public protocol DiscoveryServing: Sendable {
    func discovery(source: DiscoverySource, region: ContentRegion, page: Int) async throws -> VideoSearchPage
}
public protocol SearchSuggesting: Sendable {
    func suggestions(_ term: String) async throws -> [String]
}

extension BilibiliClient: DiscoveryServing, SearchSuggesting {
    public func searchVideos(_ term: String, page: Int, options: VideoSearchOptions) async throws -> VideoSearchPage {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf16.count <= 100, (1...1_000_000).contains(page) else { throw ClientError.invalidInput }
        let scope = authenticationID
        try await prepareBrowsingIdentifier()
        guard scope == authenticationID else { throw CancellationError() }
        var query = ["search_type": "video", "keyword": term, "page": "\(page)", "page_size": "24", "order": options.order.query,
                     "duration": "\(options.duration.rawValue)", "tids": "\(options.region.rawValue)", "copyright": "\(options.copyright.rawValue)"]
        if options.published != .any {
            let now = Date().timeIntervalSince1970
            query["pubtime_begin_s"] = String(Int(now - Double(options.published.rawValue) * 86400))
            query["pubtime_end_s"] = String(Int(now))
        }
        let data = try await request("/x/web-interface/wbi/search/type", query: query, signed: true).data
        guard let rows = data["result"] as? [[String: Any]] ?? (data["result"] is NSNull ? [] : nil),
              let total = (data["numResults"] as? NSNumber)?.intValue, total >= 0,
              let pages = (data["numPages"] as? NSNumber)?.intValue, pages >= 0 else { throw ClientError.invalidResponse }
        let items = Video.unique(rows.compactMap(Video.parse))
        guard rows.isEmpty || !items.isEmpty else { throw ClientError.invalidResponse }
        return .init(items: items, total: total, hasMore: page < pages)
    }
    public func discovery(source: DiscoverySource, region: ContentRegion, page: Int) async throws -> VideoSearchPage {
        guard (1...1_000_000).contains(page) else { throw ClientError.invalidInput }
        if source == .regions {
            guard page == 1 else { throw ClientError.invalidInput }
            let data = try await request("/x/web-interface/ranking/v2", query: ["rid": "\(region.rawValue)", "type": "all"]).data
            guard let rows = data["list"] as? [[String: Any]] else { throw ClientError.invalidResponse }
            let items = Video.unique(rows.compactMap(Video.parse))
            guard rows.isEmpty || !items.isEmpty else { throw ClientError.invalidResponse }
            return .init(items: items, total: items.count, hasMore: false)
        }
        let rows = try await feed(recommended: source == .recommended, page: page)
        return .init(items: rows, total: nil, hasMore: !rows.isEmpty)
    }
    public func suggestions(_ term: String) async throws -> [String] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf16.count <= 100 else { throw ClientError.invalidInput }
        var url = URLComponents(string: "https://s.search.bilibili.com/main/suggest")!
        url.queryItems = ["term": term, "main_ver": "v1", "func": "suggest", "suggest_type": "accurate", "sub_type": "tag", "tag_num": "8"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        // This endpoint receives only the query, never account cookies.
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard response.statusCode == 200 else { throw ClientError.http(response.statusCode) }
        guard bytes.count <= 256 * 1024, let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              root["code"] as? Int == 0, let result = root["result"] as? [String: Any], let rows = result["tag"] as? [[String: Any]] else { throw ClientError.invalidResponse }
        var seen = Set<String>()
        return Array(rows.compactMap { $0["value"] as? String }.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 100 && seen.insert(TextMatching.normalize($0)).inserted
        }.prefix(8))
    }
}
