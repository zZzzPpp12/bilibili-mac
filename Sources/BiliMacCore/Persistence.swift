import Foundation
import Security

public enum CredentialVault {
    private static let service = "dev.zzpp.BiliMac.session"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "web-session"] }
    public static func load() -> [String: String] {
        var query = query; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    public static func save(_ cookies: [String: String]) throws {
        guard cookies["SESSDATA"]?.isEmpty == false, cookies["bili_jct"]?.isEmpty == false else { throw ClientError.invalidResponse }
        let data = try JSONEncoder().encode(cookies)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    public static func clear() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}

public struct WatchRecord: Identifiable, Codable, Sendable {
    public var id: String { video.bvid }
    public var video: Video
    public var cid: Int
    public var position: Double
    public var positions: [String: Double]
    public var updatedAt: Date
    public init(video: Video, cid: Int, position: Double, positions: [String: Double] = [:], updatedAt: Date = Date()) {
        self.video = video; self.cid = cid; self.position = position; self.positions = positions
        self.positions[String(cid)] = position; self.updatedAt = updatedAt
    }
    public static func resumePosition(_ position: Double, duration: Double) -> Double {
        guard position.isFinite, position > 0 else { return 0 }
        if duration.isFinite, duration > 0, position >= duration - min(10, duration * 0.1) { return 0 }
        return position
    }
}
public struct HistoryRepository: Sendable {
    public let file: URL
    public init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BiliMac/history.json")
    }
    public func load() -> [WatchRecord] {
        guard let data = try? Data(contentsOf: file), let rows = try? JSONDecoder().decode([WatchRecord].self, from: data) else { return [] }
        return Array(rows.filter { $0.position.isFinite && $0.position >= 0 }.prefix(200))
    }
    public func save(_ rows: [WatchRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(rows.prefix(200))).write(to: file, options: .atomic)
    }
}
