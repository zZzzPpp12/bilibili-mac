import Foundation

public struct IndexedFragment: Sendable {
    public let bytes: ByteSpan
    public let ticks: UInt32
    public let randomAccess: Bool
}
public struct SegmentIndex: Sendable {
    public let timescale: UInt32
    public let presentationStart: UInt64
    public let fragments: [IndexedFragment]
    public var startSeconds: Double { Double(presentationStart)/Double(timescale) }
    public var duration: Double { fragments.reduce(0) { $0 + Double($1.ticks)/Double(timescale) } }
    public static func decode(_ data: Data, fileOffset: Int64, fileLength: Int64) throws -> SegmentIndex {
        guard fileOffset >= 0, fileLength > 0, data.count <= 2_097_152 else { throw MediaFailure.invalidIndex }
        var cursor = BoxCursor(data)
        while cursor.remaining > 0 {
            let boxStart = cursor.position
            let short = try cursor.uint(4), type = try cursor.text(4)
            let size = short == 1 ? try cursor.uint(8) : short == 0 ? UInt64(data.count-boxStart) : short
            let header = cursor.position-boxStart
            guard size >= UInt64(header), size <= UInt64(data.count-boxStart) else { throw MediaFailure.invalidIndex }
            let boxEnd = boxStart+Int(size)
            if type != "sidx" { cursor.position = boxEnd; continue }
            guard boxEnd-cursor.position >= 24 else { throw MediaFailure.invalidIndex }
            let version = try cursor.uint(1); _ = try cursor.uint(3); _ = try cursor.uint(4)
            guard version <= 1 else { throw MediaFailure.unsupportedIndex }
            let scale = try cursor.uint(4); guard scale > 0 else { throw MediaFailure.invalidIndex }
            guard boxEnd-cursor.position >= (version == 0 ? 16 : 24) else { throw MediaFailure.invalidIndex }
            let start = try cursor.uint(version == 0 ? 4 : 8)
            let displacement = try cursor.uint(version == 0 ? 4 : 8)
            _ = try cursor.uint(2); let count = try cursor.uint(2)
            guard count > 0, count <= 20_000, UInt64(boxEnd-cursor.position) == count*12 else { throw MediaFailure.invalidIndex }
            let relative = UInt64(boxEnd).addingReportingOverflow(displacement)
            let absolute = UInt64(fileOffset).addingReportingOverflow(relative.partialValue)
            guard !relative.overflow, !absolute.overflow, absolute.partialValue <= UInt64(Int64.max) else { throw MediaFailure.invalidIndex }
            var next = Int64(absolute.partialValue), fragments: [IndexedFragment] = []
            for _ in 0..<count {
                let reference = try cursor.uint(4), ticks = try cursor.uint(4), sap = try cursor.uint(4)
                guard reference & 0x8000_0000 == 0 else { throw MediaFailure.unsupportedIndex }
                let length = Int64(reference & 0x7fff_ffff)
                guard length > 0, ticks > 0 else { throw MediaFailure.invalidIndex }
                let span = try ByteSpan(offset:next,length:length)
                guard span.end < fileLength else { throw MediaFailure.invalidIndex }
                fragments.append(.init(bytes:span,ticks:UInt32(ticks),randomAccess:sap & 0x8000_0000 != 0))
                next += length
            }
            return SegmentIndex(timescale:UInt32(scale),presentationStart:start,fragments:fragments)
        }
        throw MediaFailure.invalidIndex
    }
    static func validateInitialization(_ data: Data) throws {
        guard data.count <= 2_097_152 else { throw MediaFailure.oversizedResource }
        var cursor = BoxCursor(data), types = Set<String>()
        while cursor.remaining > 0 {
            let start = cursor.position, small = try cursor.uint(4), type = try cursor.text(4)
            let size = small == 1 ? try cursor.uint(8) : small == 0 ? UInt64(data.count-start) : small
            guard size >= UInt64(cursor.position-start), size <= UInt64(data.count-start) else { throw MediaFailure.invalidContainer }
            types.insert(type); cursor.position = start+Int(size)
        }
        guard types.contains("ftyp"), types.contains("moov"), !types.contains("mdat") else { throw MediaFailure.invalidContainer }
    }
}
struct BoxCursor {
    let bytes: [UInt8]
    var position = 0
    var remaining: Int { bytes.count-position }
    init(_ data: Data) { bytes = Array(data) }
    mutating func uint(_ width: Int) throws -> UInt64 {
        guard width > 0, width <= 8, remaining >= width else { throw MediaFailure.invalidIndex }
        defer { position += width }
        return bytes[position..<position+width].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    mutating func text(_ length: Int) throws -> String {
        guard remaining >= length else { throw MediaFailure.invalidIndex }
        defer { position += length }; return String(decoding:bytes[position..<position+length],as:UTF8.self)
    }
}
