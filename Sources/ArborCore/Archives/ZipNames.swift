import Foundation

/// How "\" in ZIP member names is read, matching bsdtar so listing equals extraction (qa-places #13).
/// Windows-made archives: "\" is always a separator (`bsdtarRewrite`). Others: only in names without "/".
/// Results still go through `ArchivePath`, so "..\x", "\x" and "C:\x" are rejected.
public enum ZipNames {
    /// "Version made by" hosts that use "\" (APPNOTE 4.4.2: MS-DOS, OS/2 HPFS, NTFS, VFAT).
    public static func isWindowsHost(_ host: UInt16) -> Bool { [0, 6, 10, 14].contains(host) }

    public static func interpret(_ stored: String, windowsSeparators: Bool) -> String {
        guard stored.contains("\\") else { return stored }
        if windowsSeparators || !stored.contains("/") { return stored.replacingOccurrences(of: "\\", with: "/") }
        return stored
    }

    /// bsdtar arguments that make extraction treat "\" as a separator.
    public static let bsdtarRewrite = ["-s", ",\\\\,/,g"]

    /// Renames a Windows-made listing as `bsdtarRewrite` extracts it; `storedPath` keeps the original for patterns.
    public static func rewritten(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        entries.map { entry in
            guard entry.rawPath.contains("\\") || entry.linkTarget?.contains("\\") == true else { return entry }
            var copy = entry
            copy.storedPath = entry.rawPath
            copy.rawPath = entry.rawPath.replacingOccurrences(of: "\\", with: "/")
            copy.linkTarget = entry.linkTarget?.replacingOccurrences(of: "\\", with: "/")
            return copy
        }
    }
}
