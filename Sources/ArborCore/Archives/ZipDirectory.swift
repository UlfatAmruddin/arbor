import Foundation

/// Reads a ZIP file's central directory (names, sizes, compressed sizes, dates, encryption) without
/// decompressing anything. Supports ZIP64, the Info-ZIP Unicode path and extended-timestamp fields.
/// Mac metadata (`__MACOSX/…` AppleDouble members, which libarchive folds into the files they describe)
/// is hidden, as in Finder.
///
/// This is the only ZIP reader: archive browsing, Extract All and the search option
/// "Zipped (compressed) folders" all list archives through it.
public enum ZipDirectory {
    public enum ReadError: Error, LocalizedError, Equatable {
        case notZip, truncated, tooManyEntries

        public var errorDescription: String? {
            switch self {
            case .notZip: return "The file isn't a valid ZIP archive."
            case .truncated: return "The ZIP archive is damaged or incomplete."
            case .tooManyEntries: return "The ZIP archive lists more entries than Arbor can show."
            }
        }
    }

    /// Upper bound on listed entries, so a hostile directory can't exhaust memory.
    public static let maxEntries = 2_000_000

    /// Directory bytes read when a `limit` is given: enough for the limit at typical name lengths.
    static let limitedDirectoryBytes = 64 << 20

    /// Whether the name says ZIP (a cheap test before opening the file).
    public static func hasZipName(_ url: URL) -> Bool { ArchiveFormat.detect(url) == .zip }

    /// Lists the archive's members. With `limit`, returns at most that many entries (reading a bounded
    /// prefix of the directory) instead of failing on huge archives; search only needs a sample.
    public static func read(_ url: URL, limit: Int? = nil) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ReadError.notZip }
        let tailLength = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        let (offset, size, count) = try locateDirectory(tail: tail, limited: limit != nil) { start, length in
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: length) ?? Data()
        }
        if count == 0 || limit == 0 { return [] }
        guard offset + size <= fileSize else { throw ReadError.truncated }
        let wanted = limit == nil ? size : min(size, UInt64(limitedDirectoryBytes))
        guard wanted < 1 << 31 else { throw ReadError.truncated }
        try handle.seek(toOffset: offset)
        let directory = try handle.read(upToCount: Int(wanted)) ?? Data()
        guard directory.count == Int(wanted) else { throw ReadError.truncated }
        return try parseDirectory(directory, expected: count, limit: limit)
    }

    /// Finds the central directory from the end-of-central-directory record (and its ZIP64 variant).
    static func locateDirectory(tail: Data, limited: Bool = false,
                                read: (UInt64, Int) throws -> Data) throws -> (offset: UInt64, size: UInt64, count: UInt64) {
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { throw ReadError.notZip }
        var eocd: Int?
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { throw ReadError.notZip }
        var count = UInt64(le16(bytes, e + 10))
        var size = UInt64(le32(bytes, e + 12))
        var offset = UInt64(le32(bytes, e + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            // ZIP64 locator sits right before the EOCD record.
            let locator = e - 20
            guard locator >= 0, le32(bytes, locator) == 0x0706_4B50 else { throw ReadError.truncated }
            let recordOffset = le64(bytes, locator + 8)
            let record = [UInt8](try read(recordOffset, 56))
            guard record.count >= 56, le32(record, 0) == 0x0606_4B50 else { throw ReadError.truncated }
            count = le64(record, 32)
            size = le64(record, 40)
            offset = le64(record, 48)
        }
        guard limited || count <= UInt64(maxEntries) else { throw ReadError.tooManyEntries }
        return (offset, size, count)
    }

    static func parseDirectory(_ data: Data, expected: UInt64, limit: Int? = nil) throws -> [ArchiveEntry] {
        let cap = min(limit ?? maxEntries, maxEntries)
        let b = [UInt8](data)
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(expected, 100_000)))
        var p = 0
        while p + 46 <= b.count, le32(b, p) == 0x0201_4B50 {
            let madeBy = le16(b, p + 4)
            let flags = le16(b, p + 8)
            let dosTime = le16(b, p + 12)
            let dosDate = le16(b, p + 14)
            var compressed = UInt64(le32(b, p + 20))
            var uncompressed = UInt64(le32(b, p + 24))
            let nameLength = Int(le16(b, p + 28))
            let extraLength = Int(le16(b, p + 30))
            let commentLength = Int(le16(b, p + 32))
            let external = le32(b, p + 38)
            let nameStart = p + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            if next > b.count {
                if limit != nil { break }   // a limited read stops at the end of the prefix it read
                throw ReadError.truncated
            }
            let nameBytes = Array(b[nameStart..<extraStart])
            var name = decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)
            var modified: Date? = dosDateTime(date: dosDate, time: dosTime)

            // Extra fields.
            var x = extraStart
            while x + 4 <= extraStart + extraLength {
                let id = le16(b, x)
                let len = Int(le16(b, x + 2))
                let body = x + 4
                guard body + len <= extraStart + extraLength else { break }
                switch id {
                case 0x0001:   // ZIP64: only the fields that overflowed are present, in this order
                    var q = body
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= body + len { uncompressed = le64(b, q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= body + len { compressed = le64(b, q); q += 8 }
                case 0x7075:   // Info-ZIP Unicode path: version, CRC of the plain name, UTF-8 name
                    if len > 5, b[body] == 1 {
                        name = String(decoding: b[(body + 5)..<(body + len)], as: UTF8.self)
                    }
                case 0x5455:   // Extended timestamp: flags, then modification time (UTC seconds)
                    if len >= 5, b[body] & 1 != 0 {
                        modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: le32(b, body + 1))))
                    }
                default: break
                }
                x = body + len
            }

            // Windows tools sometimes store "\" as the separator.
            name = name.replacingOccurrences(of: "\\", with: "/")
            let host = madeBy >> 8
            let unixMode = host == 3 || host == 19 ? UInt16(truncatingIfNeeded: external >> 16) : 0
            let kind: ArchiveEntry.Kind
            switch unixMode & 0o170000 {
            case 0o120000: kind = .symlink
            case 0o040000: kind = .directory
            case 0o010000, 0o020000, 0o060000, 0o140000: kind = .special
            default: kind = name.hasSuffix("/") || external & 0x10 != 0 && host == 0 ? .directory : .file
            }
            if !isMacMetadata(name) {
                entries.append(ArchiveEntry(rawPath: name, kind: kind,
                                            size: kind == .file ? Int64(clamping: uncompressed) : nil,
                                            compressedSize: kind == .file ? Int64(clamping: compressed) : nil,
                                            modified: modified, isEncrypted: flags & 1 != 0))
            }
            if entries.count >= cap {
                if limit != nil { break }
                guard entries.count <= maxEntries else { throw ReadError.tooManyEntries }
            }
            p = next
        }
        return entries
    }

    /// `__MACOSX/` members hold resource forks and extended attributes for the real files.
    static func isMacMetadata(_ name: String) -> Bool {
        name == "__MACOSX" || name.hasPrefix("__MACOSX/")
    }

    /// UTF-8 when flagged or valid; otherwise the original IBM PC code page (CP437), as ZIP specifies.
    static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        if utf8Flag || bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return String(String.UnicodeScalarView(bytes.map { cp437[Int($0)] }))
    }

    static func dosDateTime(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var c = DateComponents()
        c.year = 1980 + Int(date >> 9)
        c.month = Int((date >> 5) & 0x0F)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return Calendar(identifier: .gregorian).date(from: c)
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }

    /// CP437, the code page ZIP names use when the UTF-8 flag is clear.
    private static let cp437: [Unicode.Scalar] = {
        let high: [UInt32] = [
            0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
            0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0x20A7, 0x192,
            0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0x2310, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
            0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
            0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
            0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
            0x3B1, 0xDF, 0x393, 0x3C0, 0x3A3, 0x3C3, 0xB5, 0x3C4, 0x3A6, 0x398, 0x3A9, 0x3B4, 0x221E, 0x3C6, 0x3B5, 0x2229,
            0x2261, 0xB1, 0x2265, 0x2264, 0x2320, 0x2321, 0xF7, 0x2248, 0xB0, 0x2219, 0xB7, 0x221A, 0x207F, 0xB2, 0x25A0, 0xA0,
        ]
        return (0..<128).map { Unicode.Scalar(UInt8($0)) } + high.map { Unicode.Scalar($0)! }
    }()
}
