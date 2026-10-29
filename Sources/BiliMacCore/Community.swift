import Foundation

public struct FavoriteFolder: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let count: Int
    public let isPrivate: Bool
    public let containsVideo: Bool
    public init(id: Int, title: String, count: Int = 0, isPrivate: Bool = false, containsVideo: Bool = false) {
        self.id = id; self.title = title; self.count = count; self.isPrivate = isPrivate; self.containsVideo = containsVideo
    }
    static func parse(_ row: [String: Any]) -> Self? {
        let id = integer(row["id"]); guard id > 0 else { return nil }
        return Self(id: id, title: row["title"] as? String ?? "收藏夹", count: integer(row["media_count"]),
                    isPrivate: integer(row["attr"]) & 1 != 0, containsVideo: integer(row["fav_state"]) == 1)
    }
}

/// Keep unavailable resources visible, including their aid for removal from watch later.
public struct SavedVideo: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let cover: String
    public let video: Video?
    public init(id: Int, title: String, cover: String = "", video: Video?) {
        self.id = id; self.title = title; self.cover = cover; self.video = video
    }
    static func parse(_ row: [String: Any], favorite: Bool) -> Self? {
        let aid = integer(favorite ? row["id"] : row["aid"]); guard aid > 0 else { return nil }
        var source = row
        source["aid"] = aid; source["owner"] = row["owner"] ?? row["upper"]
        if let counts = row["cnt_info"] as? [String: Any], row["stat"] == nil { source["stat"] = ["view":integer(counts["play"])] }
        let title = row["title"] as? String ?? "已失效视频"
        let unavailable = (favorite && integer(row["attr"]) & 1 != 0) || (!favorite && integer(row["state"]) < 0) || title == "已失效视频" || title == "视频已失效"
        return Self(id: aid, title: title, cover: row["cover"] as? String ?? row["pic"] as? String ?? "",
                    video: unavailable ? nil : Video.parse(source))
    }
    public static func unique(_ rows: [Self]) -> [Self] {
        var ids = Set<Int>(); return rows.filter { ids.insert($0.id).inserted }
    }
}
public struct SavedPage: Sendable {
    public let items: [SavedVideo]
    public let hasMore: Bool
    public init(items: [SavedVideo], hasMore: Bool) { self.items = items; self.hasMore = hasMore }
}
public struct FavoriteChanges: Equatable, Sendable {
    public let added: [Int]
    public let removed: [Int]
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    public init(original: Set<Int>, selected: Set<Int>) {
        added = selected.subtracting(original).sorted(); removed = original.subtracting(selected).sorted()
    }
}
public protocol LibraryServing: Sendable {
    func favoriteFolders(mid: Int, aid: Int?) async throws -> [FavoriteFolder]
    func favorites(mid: Int, folder: Int, page: Int) async throws -> SavedPage
    func watchLater(mid: Int) async throws -> [SavedVideo]
    func changeFavorites(mid: Int, aid: Int, changes: FavoriteChanges) async throws
    func createFolder(mid: Int, title: String, isPrivate: Bool) async throws -> FavoriteFolder
    func setWatchLater(mid: Int, aid: Int, saved: Bool) async throws
}

public enum CommentSort: String, CaseIterable, Identifiable, Sendable {
    case hot = "最热", latest = "最新"
    public var id: Self { self }
}
public struct Comment: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let message: String
    public let date: Date
    public let location: String
    public let likes: Int
    public let replyCount: Int
    public let children: [Comment]
    public init(id: Int, name: String, message: String, date: Date = .distantPast, location: String = "", likes: Int = 0, replyCount: Int = 0, children: [Comment] = []) {
        self.id = id; self.name = name; self.message = message; self.date = date; self.location = location
        self.likes = likes; self.replyCount = replyCount; self.children = children
    }
    static func parse(_ row: [String: Any], depth: Int = 0) -> Self? {
        let id = integer(row["rpid"]); guard id > 0 else { return nil }
        let member = row["member"] as? [String: Any] ?? [:], content = row["content"] as? [String: Any] ?? [:]
        let message = content["message"] as? String ?? ""
        return Self(id: id, name: member["uname"] as? String ?? "用户", message: message.isEmpty ? "[图片或其他内容]" : message,
                    date: Date(timeIntervalSince1970: Double(integer(row["ctime"]))),
                    location: (row["reply_control"] as? [String: Any])?["location"] as? String ?? "", likes: integer(row["like"]), replyCount: integer(row["rcount"]),
                    children: depth == 0 ? unique((row["replies"] as? [[String: Any]] ?? []).compactMap { parse($0, depth: 1) }) : [])
    }
    public static func unique(_ rows: [Self]) -> [Self] {
        var ids = Set<Int>(); return rows.filter { ids.insert($0.id).inserted }
    }
}
public struct CommentPage: Sendable {
    public let items: [Comment]
    public let total: Int
    public let next: String?
    public init(items: [Comment], total: Int, next: String?) { self.items = items; self.total = total; self.next = next }
    static func parse(_ data: [String: Any], first: Bool) throws -> Self {
        guard let cursor = data["cursor"] as? [String: Any], let end = cursor["is_end"] as? Bool else { throw ClientError.invalidResponse }
        let pagination = cursor["pagination_reply"] as? [String: Any] ?? [:]
        let offset = pagination["next_offset"] as? String ?? (pagination["next_offset"] as? NSNumber)?.stringValue
        guard end || offset?.isEmpty == false else { throw ClientError.invalidResponse }
        var rows: [[String: Any]] = []
        if first {
            let top = data["top"] as? [String: Any] ?? [:]
            rows += [top["admin"], top["upper"], (data["upper"] as? [String: Any])?["top"]].compactMap { $0 as? [String: Any] }
            rows += data["top_replies"] as? [[String: Any]] ?? []
        }
        rows += data["replies"] as? [[String: Any]] ?? []
        return Self(items: Comment.unique(rows.compactMap { Comment.parse($0) }), total: integer(cursor["all_count"]), next: end ? nil : offset)
    }
}
public struct CommentThreadPage: Sendable {
    public let items: [Comment]
    public let hasMore: Bool
    public init(items: [Comment], hasMore: Bool) { self.items = items; self.hasMore = hasMore }
}
public protocol CommentServing: Sendable {
    func comments(aid: Int, sort: CommentSort, offset: String?) async throws -> CommentPage
    func commentThread(aid: Int, root: Int, page: Int) async throws -> CommentThreadPage
}

extension BilibiliClient: LibraryServing, CommentServing {
    public func favoriteFolders(mid: Int, aid: Int? = nil) async throws -> [FavoriteFolder] {
        try requireAccount(mid)
        var query = ["up_mid": "\(mid)"]
        if let aid { guard aid > 0 else { throw ClientError.invalidInput }; query["rid"] = "\(aid)"; query["type"] = "2" }
        let data = try await request("/x/v3/fav/folder/created/list-all", query: query).data
        guard let rows = data["list"] as? [[String: Any]] else {
            if data["list"] is NSNull || integer(data["count"]) == 0 && data["count"] != nil { return [] }
            throw ClientError.invalidResponse
        }
        return rows.compactMap(FavoriteFolder.parse)
    }
    public func favorites(mid: Int, folder: Int, page: Int) async throws -> SavedPage {
        try requireAccount(mid)
        guard folder > 0, page > 0 else { throw ClientError.invalidInput }
        let data = try await request("/x/v3/fav/resource/list", query: ["media_id":"\(folder)", "pn":"\(page)", "ps":"20", "order":"mtime", "platform":"web"]).data
        guard let more = data["has_more"] as? Bool else { throw ClientError.invalidResponse }
        let rows = data["medias"] as? [[String: Any]]
        guard rows != nil || data["medias"] is NSNull else { throw ClientError.invalidResponse }
        return SavedPage(items: SavedVideo.unique((rows ?? []).compactMap { SavedVideo.parse($0, favorite: true) }), hasMore: more)
    }
    public func watchLater(mid: Int) async throws -> [SavedVideo] {
        try requireAccount(mid)
        let data = try await request("/x/v2/history/toview").data
        guard let rows = data["list"] as? [[String: Any]] else {
            if data["list"] is NSNull { return [] }; throw ClientError.invalidResponse
        }
        return SavedVideo.unique(rows.compactMap { SavedVideo.parse($0, favorite: false) })
    }
    public func changeFavorites(mid: Int, aid: Int, changes: FavoriteChanges) async throws {
        guard aid > 0 else { throw ClientError.invalidInput }; guard !changes.isEmpty else { return }
        _ = try await postAuthenticated("/x/v3/fav/resource/deal", values: ["rid":"\(aid)", "type":"2", "add_media_ids":changes.added.map(String.init).joined(separator: ","), "del_media_ids":changes.removed.map(String.init).joined(separator: ",")], mid: mid)
    }
    public func createFolder(mid: Int, title: String, isPrivate: Bool) async throws -> FavoriteFolder {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 20 else { throw ClientError.invalidFolderName }
        let data = try await postAuthenticated("/x/v3/fav/folder/add", values: ["title":title, "privacy":isPrivate ? "1" : "0"], mid: mid)
        guard let folder = FavoriteFolder.parse(data) else { throw ClientError.writeUncertain }; return folder
    }
    public func setWatchLater(mid: Int, aid: Int, saved: Bool) async throws {
        guard aid > 0 else { throw ClientError.invalidInput }
        _ = try await postAuthenticated(saved ? "/x/v2/history/toview/add" : "/x/v2/history/toview/del", values: ["aid":"\(aid)"], mid: mid)
    }
    public func comments(aid: Int, sort: CommentSort, offset: String?) async throws -> CommentPage {
        guard aid > 0 else { throw ClientError.invalidInput }
        let pagination = String(decoding: try JSONSerialization.data(withJSONObject: ["offset":offset ?? ""], options: [.sortedKeys]), as: UTF8.self)
        let data = try await request("/x/v2/reply/wbi/main", query: ["oid":"\(aid)", "type":"1", "mode":sort == .hot ? "3" : "2", "pagination_str":pagination, "web_location":"1315875"], signed: true).data
        return try CommentPage.parse(data, first: offset == nil)
    }
    public func commentThread(aid: Int, root: Int, page: Int) async throws -> CommentThreadPage {
        guard aid > 0, root > 0, page > 0 else { throw ClientError.invalidInput }
        let data = try await request("/x/v2/reply/reply", query: ["oid":"\(aid)", "type":"1", "root":"\(root)", "pn":"\(page)", "ps":"20"]).data
        guard let info = data["page"] as? [String: Any], info["count"] != nil,
              let rows = data["replies"] as? [[String: Any]] ?? (data["replies"] is NSNull ? [] : nil) else { throw ClientError.invalidResponse }
        let size = integer(info["size"])
        guard size > 0 else { throw ClientError.invalidResponse }
        return CommentThreadPage(items: Comment.unique(rows.compactMap { Comment.parse($0) }), hasMore: page * size < integer(info["count"]))
    }
}
