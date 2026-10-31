import Foundation
import BiliMacMedia

public enum ClientError: LocalizedError {
    case invalidResponse, http(Int), server(Int, String), noPlayableMedia, invalidInput
    case authenticationRequired, writeUncertain, paginationStalled, invalidFolderName
    case invalidCoinAmount, invalidCommentText
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务返回的数据不完整，请稍后重试。"
        case .http(412): return "请求暂受限制，请稍后重试或登录。"
        case .http(let code): return "连接失败（HTTP \(code)），请重试。"
        case .server(-101, _): return "登录已失效，请重新扫码。"
        case .server(let code, _) where [-352, -401, -403].contains(code): return "请求被限制（\(code)），请在哔哩哔哩官方页面完成验证后刷新状态。"
        case .server(let code, let message): return "\(message)（\(code)）"
        case .noPlayableMedia: return "当前账号没有可播放的兼容媒体，请登录或选择其他视频。"
        case .invalidInput: return "请输入关键词、完整 BV 号或 B 站视频链接。"
        case .authenticationRequired: return "请先扫码登录，再使用账号操作。"
        case .writeUncertain: return "请求结果尚未确认，请先刷新状态核对，再决定是否继续操作。"
        case .paginationStalled: return "本页没有返回新的内容，请重试。"
        case .invalidFolderName: return "收藏夹名称需要 1–20 个字。"
        case .invalidCoinAmount: return "本次请选择 1 或 2 枚硬币，且不能超过余额或视频投币上限。"
        case .invalidCommentText: return "评论不能为空，且不能超过 1000 个字符。"
        }
    }
}

public struct Video: Identifiable, Codable, Hashable, Sendable {
    public var id: String { bvid }
    public let bvid: String
    public let aid: Int
    public let title: String
    public let cover: String
    public let author: String
    public let authorID: Int?
    public let duration: Int
    public let views: Int
    public let publishedAt: Date?
    public let categoryID: Int?
    public init(bvid: String, aid: Int = 0, title: String, cover: String = "", author: String, duration: Int, views: Int = 0, authorID: Int? = nil, publishedAt: Date? = nil, categoryID: Int? = nil) {
        self.bvid = bvid; self.aid = aid; self.title = title; self.cover = cover
        self.author = author; self.duration = duration; self.views = views; self.authorID = authorID
        self.publishedAt = publishedAt; self.categoryID = categoryID
    }
    public static func parse(_ row: [String: Any]) -> Self? {
        guard let bvid = row["bvid"] as? String, VideoInput.bvid(bvid) != nil else { return nil }
        let owner = row["owner"] as? [String: Any] ?? [:]
        let stat = row["stat"] as? [String: Any] ?? [:]
        let duration = row["duration"] as? Int ?? (row["duration"] as? String ?? row["length"] as? String ?? "0").split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        return Self(bvid: bvid, aid: integer(row["aid"]),
            title: (row["title"] as? String ?? "视频").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&"),
            cover: row["pic"] as? String ?? row["cover"] as? String ?? "",
            author: owner["name"] as? String ?? row["author"] as? String ?? "未知作者",
            duration: duration, views: integer(stat["view"] ?? row["play"]),
            authorID: integer(owner["mid"] ?? row["mid"]) > 0 ? integer(owner["mid"] ?? row["mid"]) : nil,
            publishedAt: integer(row["pubdate"] ?? row["ctime"]) > 0 ? Date(timeIntervalSince1970: Double(integer(row["pubdate"] ?? row["ctime"]))) : nil,
            categoryID: integer(row["tid"] ?? row["typeid"]) > 0 ? integer(row["tid"] ?? row["typeid"]) : nil)
    }
    public static func unique(_ items: [Video]) -> [Video] {
        var seen = Set<String>(); return items.filter { seen.insert($0.id).inserted }
    }
}

public struct VideoPage: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let duration: Int
    public init(id: Int, title: String, duration: Int) { self.id = id; self.title = title; self.duration = duration }
}
public struct VideoDetail: Sendable {
    public let video: Video
    public let description: String
    public let pages: [VideoPage]
    public init(video: Video, description: String, pages: [VideoPage]) { self.video = video; self.description = description; self.pages = pages }
}
public struct Account: Sendable {
    public let id: Int
    public let name: String
}
public struct PlaybackManifest: Sendable {
    public let videos: [MediaTrack]
    public let audio: MediaTrack
    public let qualityNames: [Int: String]
    public var qualities: [Int] { Array(Set(videos.map(\.id))).sorted(by: >) }
}
public struct QRCode: Sendable { public let key: String; public let url: String }
public enum QRStatus: Sendable { case waiting, scanned, expired, confirmed([String: String]) }

public enum VideoInput {
    public static func bvid(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil { return input }
        guard let url = URL(string: input), ["http", "https"].contains(url.scheme ?? ""),
              ["www.bilibili.com", "bilibili.com", "m.bilibili.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url.pathComponents.first { $0.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil }
    }
}
public enum DisplayFormat {
    public static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(seconds, 359_999))) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    public static func count(_ number: Int) -> String { number >= 10_000 ? String(format: "%.1f万", Double(number) / 10_000) : String(number) }
}
func integer(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0 }
