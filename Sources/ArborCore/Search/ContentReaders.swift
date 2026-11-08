import Foundation
import UniformTypeIdentifiers

/// Content search for unindexed places (FE-139, FE-141): text files up to `maxBytes`, never cloud
/// placeholders (reading would download them).
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
        guard st.st_mode & S_IFMT == S_IFREG else { return .notText }   // FIFOs, devices, sockets, symlinks
        if st.st_flags & 0x4000_0000 != 0 { return .notDownloaded }   // SF_DATALESS: a cloud placeholder
        let byteCount = size ?? Int64(st.st_size)
        guard byteCount <= Int64(maxBytes) else { return .tooLarge }
        guard let handle = FileHandle.openRegularFile(atPath: url.path) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return .unreadable }
        return .text(Self.decode(data))
    }

    /// UTF-16 with BOM, UTF-8, then Latin-1 (never fails).
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

extension FileHandle {
    /// Opens only a regular file: never follows a symlink, and a FIFO or device can't block the open.
    static func openRegularFile(atPath path: String) -> FileHandle? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        // Re-check the opened item: it may have been swapped since lstat.
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
