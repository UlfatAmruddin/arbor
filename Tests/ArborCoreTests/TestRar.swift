import Foundation
@testable import ArborCore

/// Builds real RAR4 and RAR5 archives byte by byte with the stored method, per the published formats, including hostile ones.
/// RAR4 headers start with the low 16 bits of a CRC32; RAR5 headers with a full CRC32, and RAR5 sizes are vints.
struct TestRar {
    enum Format: String, CaseIterable, Sendable { case rar4, rar5 }

    /// RAR5 link or reference types (redirection extra record).
    enum Redirect: Int { case symlink = 1, junction = 3, hardLink = 4, fileCopy = 5 }

    struct Member {
        var name: String
        var content = Data()
        var mode: UInt32 = 0o100644
        var modified = TestRar.defaultDate
        var windowsHost = false
        var encrypted = false
        var splitBefore = false
        var splitAfter = false
        /// 0 = stored; anything else claims a compression the content doesn't have.
        var method = 0
        /// Declared unpacked size when it differs from `content`.
        var unpackedSize: Int?
        var redirect: (type: Redirect, target: String)?
        /// Name bytes as stored, for RAR4's legacy OEM names.
        var rawName: [UInt8]?
        /// RAR4 only: stores the name in the "Unicode" encoding (FHD_UNICODE).
        var unicodeName = false

        var isFolder: Bool { mode & 0o170000 == 0o040000 }
    }

    /// 2025-03-07 12:30:20 UTC; even seconds because RAR4 dates have two-second steps.
    static let defaultDate = Date(timeIntervalSince1970: 1_741_350_620)

    let format: Format
    var members: [Member] = []
    var isVolume = false
    var hasEncryptedHeaders = false
    var hasServiceBlock = false

    init(_ format: Format) { self.format = format }

    mutating func file(_ name: String, _ text: String = "x", modified: Date = TestRar.defaultDate) {
        members.append(Member(name: name, content: Data(text.utf8), modified: modified))
    }

    mutating func folder(_ name: String) { members.append(Member(name: name, mode: 0o040755)) }

    mutating func fifo(_ name: String) { members.append(Member(name: name, mode: 0o010644)) }

    /// A symbolic link: RAR4 stores the target as data, RAR5 in an extra record.
    mutating func link(_ name: String, to target: String) {
        switch format {
        case .rar4: members.append(Member(name: name, content: Data(target.utf8), mode: 0o120777))
        case .rar5: members.append(Member(name: name, mode: 0o120777, redirect: (.symlink, target)))
        }
    }

    func build() -> Data { format == .rar4 ? buildRar4() : buildRar5() }

    func write(to url: URL) throws { try build().write(to: url) }

    // MARK: RAR4

    private func buildRar4() -> Data {
        var out = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        var mainFlags: UInt16 = isVolume ? 0x0001 : 0
        if hasEncryptedHeaders { mainFlags |= 0x0080 }
        out += Self.rar4Block(type: 0x73, flags: mainFlags, body: Data(count: 6))
        if hasEncryptedHeaders { return out + Data(repeating: 0x11, count: 64) }
        if hasServiceBlock {
            let body = Self.rar4FileFields(packed: 5, unpacked: 5, host: 3, crc: TestZip.crc32(Data("notes".utf8)), time: 0, method: 0x30, nameCount: 3, attributes: 0)
            out += Self.rar4Block(type: 0x7A, flags: 0x8000, body: body + Data("CMT".utf8)) + Data("notes".utf8)
        }
        for m in members { out += rar4Member(m) }
        return out + Self.rar4Block(type: 0x7B, flags: 0x4000, body: Data())
    }

    private func rar4Member(_ m: Member) -> Data {
        var flags: UInt16 = 0x8000
        if m.splitBefore { flags |= 0x0001 }
        if m.splitAfter { flags |= 0x0002 }
        if m.encrypted { flags |= 0x0004 | 0x0400 }
        if m.isFolder { flags |= 0x00E0 }
        if m.unicodeName { flags |= 0x0200 }
        let name = m.rawName ?? (m.unicodeName ? Self.rar4UnicodeName(m.name) : Array(m.name.utf8))
        let attributes = m.windowsHost ? (m.isFolder ? 0x10 : 0x20) : m.mode
        var body = Self.rar4FileFields(packed: m.content.count, unpacked: m.unpackedSize ?? m.content.count, host: m.windowsHost ? 2 : 3,
                                       crc: TestZip.crc32(m.content), time: Self.dosTime(m.modified), method: UInt8(0x30 + m.method),
                                       nameCount: name.count, attributes: attributes)
        body.append(contentsOf: name)
        if m.encrypted { body.append(contentsOf: [UInt8](repeating: 0x53, count: 8)) }   // salt
        return Self.rar4Block(type: 0x74, flags: flags, body: body) + m.content
    }

    private static func rar4FileFields(packed: Int, unpacked: Int, host: UInt8, crc: UInt32, time: UInt32, method: UInt8,
                                       nameCount: Int, attributes: UInt32) -> Data {
        var d = Data()
        le(UInt32(packed), &d); le(UInt32(unpacked), &d); d.append(host); le(crc, &d); le(time, &d)
        d.append(29); d.append(method); le(UInt16(nameCount), &d); le(attributes, &d)
        return d
    }

    /// CRC16 (low half of a CRC32 over everything after the field), type, flags, size, body.
    static func rar4Block(type: UInt8, flags: UInt16, body: Data) -> Data {
        var header = Data([type])
        le(flags, &header); le(UInt16(7 + body.count), &header)
        header += body
        var out = Data()
        le(UInt16(truncatingIfNeeded: TestZip.crc32(header)), &out)
        return out + header
    }

    /// A plain-byte stand-in, NUL, then every UTF-16 unit in mode 2 (both bytes explicit, a flag byte per four).
    private static func rar4UnicodeName(_ name: String) -> [UInt8] {
        let units = Array(name.utf16)
        var out = [UInt8](repeating: UInt8(ascii: "_"), count: units.count) + [0, 0]
        for start in stride(from: 0, to: units.count, by: 4) {
            let group = units[start..<min(start + 4, units.count)]
            out.append(UInt8(truncatingIfNeeded: 0xAA & (0xFF << (8 - 2 * group.count))))
            for unit in group { out.append(UInt8(unit & 0xFF)); out.append(UInt8(unit >> 8)) }
        }
        return out
    }

    private static func dosTime(_ date: Date) -> UInt32 {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt32((c.year ?? 1980) - 1980) << 25
        let month = UInt32(c.month ?? 1) << 21
        let day = UInt32(c.day ?? 1) << 16
        let hour = UInt32(c.hour ?? 0) << 11
        return year | month | day | hour | UInt32(c.minute ?? 0) << 5 | UInt32((c.second ?? 0) / 2)
    }

    // MARK: RAR5

    private func buildRar5() -> Data {
        var out = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
        if hasEncryptedHeaders {
            var body = Self.vint(0) + Self.vint(1)
            body += Data([15]) + Data(repeating: 0x53, count: 16) + Data(repeating: 0x43, count: 12)
            return out + Self.rar5Header(type: 4, body: body) + Data(repeating: 0x22, count: 128)
        }
        out += Self.rar5Header(type: 1, body: Self.vint(isVolume ? 1 : 0))
        if hasServiceBlock {
            var body = Self.vint(4) + Self.vint(5) + Self.vint(0)
            Self.le(TestZip.crc32(Data("notes".utf8)), &body)
            body += Self.vint(0) + Self.vint(1) + Self.vint(3) + Data("CMT".utf8)
            out += Self.rar5Header(type: 3, body: body, dataSize: 5) + Data("notes".utf8)
        }
        for m in members { out += rar5Member(m) }
        return out + Self.rar5Header(type: 5, body: Self.vint(0))
    }

    private func rar5Member(_ m: Member) -> Data {
        var body = Self.vint(UInt64((m.isFolder ? 1 : 0) | 2 | (m.isFolder ? 0 : 4)))
        body += Self.vint(UInt64(m.unpackedSize ?? m.content.count))
        body += Self.vint(m.windowsHost ? (m.isFolder ? 0x10 : 0x20) : UInt64(m.mode))
        Self.le(UInt32(m.modified.timeIntervalSince1970), &body)
        if !m.isFolder { Self.le(TestZip.crc32(m.content), &body) }
        let name = m.rawName ?? Array(m.name.utf8)
        body += Self.vint(UInt64(m.method) << 7) + Self.vint(m.windowsHost ? 0 : 1) + Self.vint(UInt64(name.count)) + Data(name)

        var extra = Data()
        if m.encrypted {
            let record = Self.vint(1) + Self.vint(0) + Self.vint(0) + Data([15]) + Data(repeating: 0x53, count: 16) + Data(repeating: 0x49, count: 16)
            extra += Self.vint(UInt64(record.count)) + record
        }
        if let redirect = m.redirect {
            let target = Data(redirect.target.utf8)
            let record = Self.vint(5) + Self.vint(UInt64(redirect.type.rawValue)) + Self.vint(0) + Self.vint(UInt64(target.count)) + target
            extra += Self.vint(UInt64(record.count)) + record
        }
        let flags: UInt64 = (m.splitBefore ? 0x08 : 0) | (m.splitAfter ? 0x10 : 0)
        return Self.rar5Header(type: 2, flags: flags, body: body, extra: extra, dataSize: m.content.count) + m.content
    }

    /// CRC32 of everything after the field, then the size of the rest, type, flags, optional sizes, body, extra area.
    static func rar5Header(type: UInt64, flags: UInt64 = 0, body: Data, extra: Data = Data(), dataSize: Int? = nil) -> Data {
        var allFlags = flags
        if !extra.isEmpty { allFlags |= 0x01 }
        if dataSize != nil { allFlags |= 0x02 }
        var inner = vint(type) + vint(allFlags)
        if !extra.isEmpty { inner += vint(UInt64(extra.count)) }
        if let dataSize { inner += vint(UInt64(dataSize)) }
        inner += body + extra
        let sized = vint(UInt64(inner.count)) + inner
        var out = Data()
        le(TestZip.crc32(sized), &out)
        return out + sized
    }

    /// Seven bits per byte, least significant first; the high bit means more follow.
    static func vint(_ value: UInt64) -> Data {
        var rest = value
        var out = Data()
        repeat {
            let low = UInt8(rest & 0x7F)
            rest >>= 7
            out.append(rest == 0 ? low : low | 0x80)
        } while rest != 0
        return out
    }

    private static func le<T: FixedWidthInteger>(_ value: T, _ out: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }
}
