import Foundation
import UniformTypeIdentifiers

/// Reads plain-text files for "File contents" searches in places the index doesn't cover (FE-139, FE-141).
/// Bounded: text-like files only, at most `maxBytes`, never cloud placeholders (reading would download them).
public final class TextContent {
    public static let defaultMaxBytes = 4 << 20

    public enum Outcome: Equatable { case text(String), notText, tooLarge, notDownloaded, unreadable }

    private let url: URL
    private let typeIdentifier: String?
    private let size: Int64?
    private let maxBytes: Int
    private var cached: Outcome?

    public init(url: URL, typeIdentifier: String?, size: Int64?, maxBytes: Int = TextContent.defaultMaxBytes) {
        self.url = url
        self.typeIdentifier = typeIdentifier
        self.size = size
        self.maxBytes = maxBytes
    }

    /// nil = couldn't check.
    public func contains(_ needle: String) -> Bool? {
        guard case .text(let text) = outcome else { return nil }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    public var outcome: Outcome {
        if let cached { return cached }
        let result = read()
        cached = result
        return result
    }

    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "html", "htm", "css", "js", "ts", "tsx", "jsx",
        "swift", "m", "h", "c", "cc", "cpp", "hpp", "py", "rb", "go", "rs", "java", "kt", "sh", "zsh", "bash", "yml", "yaml",
        "toml", "ini", "cfg", "conf", "plist", "strings", "sql", "tex", "rtf", "srt", "vtt", "properties", "gradle", "php", "pl",
    ]

    public static func isTextLike(typeIdentifier: String?, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        if let id = typeIdentifier, let type = UTType(id) { return type.conforms(to: .text) }
        return false
    }

    private func read() -> Outcome {
        guard Self.isTextLike(typeIdentifier: typeIdentifier, name: url.lastPathComponent) else { return .notText }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .unreadable }
        if st.st_flags & 0x4000_0000 != 0 { return .notDownloaded }   // SF_DATALESS: a cloud placeholder
        let byteCount = size ?? Int64(st.st_size)
        guard byteCount <= Int64(maxBytes) else { return .tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return .unreadable }
        return .text(Self.decode(data))
    }

    /// UTF-8, then UTF-16 with a byte-order mark, then Latin-1 (which never fails).
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// Lists the entries of a .zip archive from its central directory, without extracting anything
/// (Search options ▸ Zipped (compressed) files). ZIP64 archives aren't read and are reported.
public enum SearchZipDirectory {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let isFolder: Bool
        public let size: Int64
        public let modified: Date?
    }

    public enum ReadError: Error, Equatable { case notZip, unsupported, damaged }

    public static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    public static func entries(of url: URL, limit: Int = 20_000) throws -> [Entry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ReadError.damaged }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize >= 22 else { throw ReadError.notZip }
        let tailLength = min(fileSize, 65_557)
        try? handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { throw ReadError.damaged }
        let bytes = [UInt8](tail)
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x06
        }) else { throw ReadError.notZip }
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(b[i]) | UInt64(b[i + 1]) << 8 | UInt64(b[i + 2]) << 16 | UInt64(b[i + 3]) << 24 }
        let count = u16(bytes, eocd + 10)
        let dirSize = u32(bytes, eocd + 12)
        let dirOffset = u32(bytes, eocd + 16)
        if count == 0xFFFF || dirSize == 0xFFFF_FFFF || dirOffset == 0xFFFF_FFFF { throw ReadError.unsupported }
        guard dirOffset + dirSize <= fileSize, dirSize < 64 << 20 else { throw ReadError.damaged }
        try? handle.seek(toOffset: dirOffset)
        guard let dirData = try? handle.read(upToCount: Int(dirSize)) else { throw ReadError.damaged }
        let d = [UInt8](dirData)
        var entries: [Entry] = []
        var i = 0
        while i + 46 <= d.count, entries.count < min(count, limit) {
            guard d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x01, d[i + 3] == 0x02 else { throw ReadError.damaged }
            let flags = u16(d, i + 8)
            let time = u16(d, i + 12), date = u16(d, i + 14)
            let size = u32(d, i + 24)
            let nameLength = u16(d, i + 28), extraLength = u16(d, i + 30), commentLength = u16(d, i + 32)
            guard i + 46 + nameLength <= d.count else { throw ReadError.damaged }
            let nameBytes = Data(d[(i + 46)..<(i + 46 + nameLength)])
            let name = (flags & 0x800 != 0 ? String(data: nameBytes, encoding: .utf8) : nil)
                ?? String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            if !name.hasPrefix("__MACOSX/"), !name.isEmpty {
                entries.append(Entry(path: name.hasSuffix("/") ? String(name.dropLast()) : name, isFolder: name.hasSuffix("/"),
                                     size: Int64(size), modified: dosDate(date: date, time: time)))
            }
            i += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func dosDate(date: Int, time: Int) -> Date? {
        var c = DateComponents()
        c.year = 1980 + (date >> 9)
        c.month = (date >> 5) & 0xF
        c.day = date & 0x1F
        c.hour = time >> 11
        c.minute = (time >> 5) & 0x3F
        c.second = (time & 0x1F) * 2
        return Calendar.current.date(from: c)
    }
}
