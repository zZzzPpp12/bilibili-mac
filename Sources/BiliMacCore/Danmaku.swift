import Foundation

public struct Danmaku: Identifiable, Sendable, Equatable {
    public let id: String
    public let time: Double
    public let mode: Int
    public let size: Int
    public let color: Int
    public let text: String
}
public enum DanmakuDecoder {
    private struct Reader {
        let data: [UInt8]
        var offset = 0
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard offset < data.count else { throw ClientError.invalidResponse }
                let byte = data[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw ClientError.invalidResponse }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw ClientError.invalidResponse
        }
        mutating func field() throws -> (Int, UInt64?, [UInt8]?)? {
            guard offset < data.count else { return nil }
            let key = try varint(); guard key >> 3 > 0 else { throw ClientError.invalidResponse }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: return (number, try varint(), nil)
            case 2:
                let length = try varint(); guard length <= UInt64(data.count - offset) else { throw ClientError.invalidResponse }
                let bytes = Array(data[offset..<offset + Int(length)]); offset += Int(length); return (number, nil, bytes)
            case 1, 5:
                let count = key & 7 == 1 ? 8 : 4
                guard offset + count <= data.count else { throw ClientError.invalidResponse }
                offset += count; return (number, nil, nil)
            default: throw ClientError.invalidResponse
            }
        }
    }
    public static func decode(_ data: Data) throws -> [Danmaku] {
        var reader = Reader(data: Array(data)); var result: [Danmaku] = []
        while let field = try reader.field() {
            guard field.0 == 1, let bytes = field.2 else { continue }
            var item = Reader(data: bytes), id = "", text = "", time = 0.0, mode = 1, size = 25, color = 0xFFFFFF
            while let field = try item.field() {
                switch field.0 {
                case 1: id = String(field.1 ?? 0)
                case 2: time = Double(field.1 ?? 0) / 1000
                case 3: mode = Int(clamping: field.1 ?? 1)
                case 4: size = Int(clamping: field.1 ?? 25)
                case 5: color = Int(clamping: field.1 ?? 0xFFFFFF)
                case 7: text = String(bytes: field.2 ?? [], encoding: .utf8) ?? ""
                case 12: id = String(bytes: field.2 ?? [], encoding: .utf8) ?? id
                default: break
                }
            }
            if !text.isEmpty, [1,2,3,4,5,6].contains(mode), result.count < 20_000 {
                result.append(Danmaku(id: id.isEmpty ? "\(reader.offset)" : id, time: time, mode: mode, size: min(36,max(12,size)), color: color & 0xFFFFFF, text: String(text.prefix(200))))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

public enum DanmakuMotion {
    public static func x(width: Double, textWidth: Double, elapsed: Double, lifetime: Double = 8, reverse: Bool = false) -> Double {
        reverse ? -textWidth + (width + textWidth) * elapsed / lifetime : width - (width + textWidth) * elapsed / lifetime
    }
}
