import Foundation

public struct BiliUser: Identifiable, Hashable, Sendable {
    public var id: Int { mid }
    public let mid: Int
    public let name: String
    public let avatar: String
    public let signature: String
    public let fans: Int?
    public let videos: Int?
    public let verification: String?
    public init(mid: Int, name: String, avatar: String = "", signature: String = "", fans: Int? = nil, videos: Int? = nil, verification: String? = nil) {
        self.mid = mid; self.name = name; self.avatar = avatar; self.signature = signature
        self.fans = fans; self.videos = videos; self.verification = verification
    }
    static func parse(_ row: [String: Any]) -> Self? {
        let mid = integer(row["mid"]); guard mid > 0, let name = row["uname"] as? String ?? row["name"] as? String, !name.isEmpty else { return nil }
        let verify = row["official_verify"] as? [String: Any] ?? row["official"] as? [String: Any] ?? [:]
        let description = verify["desc"] as? String ?? verify["title"] as? String ?? ""
        return Self(mid: mid, name: name.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                    avatar: row["upic"] as? String ?? row["face"] as? String ?? "",
                    signature: row["usign"] as? String ?? row["sign"] as? String ?? "",
                    fans: count(row["fans"]), videos: count(row["videos"]), verification: description.isEmpty ? nil : description)
    }
    public static func unique(_ rows: [Self]) -> [Self] { var ids = Set<Int>(); return rows.filter { ids.insert($0.mid).inserted } }
}

public struct UserProfile: Sendable {
    public let user: BiliUser
    public let followingCount: Int?
    public var followed: Bool?
    public init(user: BiliUser, followingCount: Int? = nil, followed: Bool? = nil) { self.user = user; self.followingCount = followingCount; self.followed = followed }
}
public struct UserSearchPage: Sendable {
    public let items: [BiliUser]
    public let total: Int
    public let hasMore: Bool
    public init(items: [BiliUser], total: Int, hasMore: Bool) { self.items = items; self.total = total; self.hasMore = hasMore }
}
public struct UserVideoPage: Sendable {
    public let items: [Video]
    public let total: Int
    public let hasMore: Bool
    public init(items: [Video], total: Int, hasMore: Bool) { self.items = items; self.total = total; self.hasMore = hasMore }
}
public enum UserVideoOrder: String, CaseIterable, Identifiable, Sendable {
    case latest = "最新发布", views = "最多播放"
    public var id: Self { self }
    var query: String { self == .latest ? "pubdate" : "click" }
}
public protocol SearchServing: Sendable {
    func search(_ term: String, page: Int) async throws -> [Video]
    func searchVideos(_ term: String, page: Int, options: VideoSearchOptions) async throws -> VideoSearchPage
    func searchUsers(_ term: String, page: Int) async throws -> UserSearchPage
}
extension SearchServing {
    public func searchVideos(_ term: String, page: Int, options: VideoSearchOptions) async throws -> VideoSearchPage {
        let rows = try await search(term, page: page)
        return .init(items: rows, total: nil, hasMore: !rows.isEmpty)
    }
}
public protocol UserServing: Sendable {
    func userProfile(mid: Int) async throws -> UserProfile
    func userVideos(mid: Int, page: Int, order: UserVideoOrder) async throws -> UserVideoPage
    func setFollowing(account: Int, target: Int, followed: Bool) async throws
}

public enum UserInput {
    public static func mid(_ value: String) -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var number: String?
        if value.range(of: "(?i)^uid\\s*[:：]\\s*[0-9]+$", options: .regularExpression) != nil {
            number = value.split(whereSeparator: { $0 == ":" || $0 == "：" }).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        } else if let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.lowercased() == "space.bilibili.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443 {
            number = url.path.split(separator: "/").first.map(String.init)
        }
        guard let number, !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }), let mid = Int(number), mid > 0 else { return nil }
        return mid
    }
}

extension BilibiliClient: SearchServing, UserServing {
    public func searchUsers(_ term: String, page: Int) async throws -> UserSearchPage {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, (1...1_000_000).contains(page) else { throw ClientError.invalidInput }
        let scope = authenticationID; try await prepareBrowsingIdentifier()
        guard scope == authenticationID else { throw CancellationError() }
        let data = try await request("/x/web-interface/wbi/search/type", query: ["search_type": "bili_user", "keyword": term, "page": "\(page)", "page_size": "24"], signed: true).data
        guard let rows = data["result"] as? [[String: Any]] ?? (data["result"] is NSNull ? [] : nil),
              let total = count(data["numResults"]), let pages = count(data["numPages"]) else { throw ClientError.invalidResponse }
        let items = BiliUser.unique(rows.compactMap(BiliUser.parse))
        guard rows.isEmpty || !items.isEmpty else { throw ClientError.invalidResponse }
        return .init(items: items, total: total, hasMore: page < pages)
    }
    public func userProfile(mid: Int) async throws -> UserProfile {
        guard mid > 0 else { throw ClientError.invalidInput }
        let data = try await request("/x/web-interface/card", query: ["mid": "\(mid)", "photo": "true"]).data
        guard var card = data["card"] as? [String: Any] else { throw ClientError.invalidResponse }
        card["videos"] = data["archive_count"]
        guard let user = BiliUser.parse(card), user.mid == mid else { throw ClientError.invalidResponse }
        return .init(user: user, followingCount: count(card["attention"]), followed: data["following"] as? Bool)
    }
    public func userVideos(mid: Int, page: Int, order: UserVideoOrder = .latest) async throws -> UserVideoPage {
        guard mid > 0, (1...1_000_000).contains(page) else { throw ClientError.invalidInput }
        let scope = authenticationID; try await prepareBrowsingIdentifier()
        guard scope == authenticationID else { throw CancellationError() }
        let data = try await request("/x/space/wbi/arc/search", query: ["mid": "\(mid)", "pn": "\(page)", "ps": "30", "order": order.query, "platform": "web", "web_location": "1550101"], signed: true).data
        guard let info = data["page"] as? [String: Any], let total = count(info["count"]), let size = count(info["ps"]), size > 0,
              let list = data["list"] as? [String: Any], let rows = list["vlist"] as? [[String: Any]] ?? (list["vlist"] is NSNull ? [] : nil) else { throw ClientError.invalidResponse }
        let items = Video.unique(rows.compactMap { row -> Video? in
            var source = row
            if integer(source["mid"]) <= 0 { source["mid"] = mid }
            return Video.parse(source)
        })
        guard rows.isEmpty || !items.isEmpty else { throw ClientError.invalidResponse }
        return .init(items: items, total: total, hasMore: total > 0 && page <= (total - 1) / size)
    }
    public func setFollowing(account: Int, target: Int, followed: Bool) async throws {
        guard target > 0, target != account else { throw ClientError.invalidInput }
        let scope = authenticationID; try await prepareInteraction(mid: account)
        guard scope == authenticationID else { throw CancellationError() }
        _ = try await postAuthenticated("/x/relation/modify", values: ["fid": "\(target)", "act": followed ? "1" : "2", "re_src": "11"], mid: account)
    }
}

private func count(_ value: Any?) -> Int? {
    guard value != nil, !(value is NSNull) else { return nil }
    guard let number = (value as? NSNumber)?.intValue ?? Int(value as? String ?? ""), number >= 0 else { return nil }
    return number
}
