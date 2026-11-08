import Foundation

/// How "\" in ZIP member names is read (qa-places #13).
///
/// The ZIP specification says names use "/"; some Windows tools store "\" instead, and Windows reads
/// "\" as a separator because it can't be part of a Windows name. On a Mac "\" is an ordinary character.
/// Arbor reads names the way its extractor (libarchive's bsdtar) does, so what a ZIP shows is what
/// extraction writes:
/// - an archive made on Windows (an entry from an MS-DOS/FAT, OS/2 HPFS, NTFS or VFAT host contains "\")
///   uses "\" as a separator everywhere; extraction rewrites "\" to "/" to match (`bsdtarRewrite`);
/// - otherwise "\" separates folders only in a name that has no "/" at all (libarchive's own rule);
///   in a name that also has "/", "\" is kept as part of the name.
/// Every result then goes through `ArchivePath`, so "..\..\x", "\x" and "C:\x" are rejected like their
/// "/" spellings.
public enum ZipNames {
    /// "Version made by" hosts whose file systems use "\" (APPNOTE 4.4.2: 0 MS-DOS/FAT, 6 OS/2 HPFS, 10 NTFS, 14 VFAT).
    public static func isWindowsHost(_ host: UInt16) -> Bool { [0, 6, 10, 14].contains(host) }

    /// The member name as Arbor shows and extracts it.
    public static func interpret(_ stored: String, windowsSeparators: Bool) -> String {
        guard stored.contains("\\") else { return stored }
        if windowsSeparators || !stored.contains("/") { return stored.replacingOccurrences(of: "\\", with: "/") }
        return stored
    }

    /// bsdtar arguments that make extraction read "\" as a separator, for archives made on Windows.
    public static let bsdtarRewrite = ["-s", ",\\\\,/,g"]

    /// bsdtar's listing of a Windows-made archive, renamed the way extraction with `bsdtarRewrite` writes
    /// it. `storedPath` keeps bsdtar's own name: extraction patterns must match that.
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
