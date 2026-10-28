import Foundation
import CryptoKit

public enum WBISigning {
    public static func mixin(_ raw: String) -> String {
        let table = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
        let characters = Array(raw)
        return String(table.compactMap { $0 < characters.count ? characters[$0] : nil }.prefix(32))
    }
    public static func sign(_ values: [String: String], key: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> [String: String] {
        var values = values.mapValues { $0.filter { !"!'()*".contains($0) } }
        values["wts"] = String(timestamp)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
        values["w_rid"] = Insecure.MD5.hash(data: Data((query + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return values
    }
}
