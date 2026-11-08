import Foundation

/// Archive formats Arbor can browse (spec §13.1: a capability matrix, not a checkbox).
///
/// Every format is read through the system's libarchive (`/usr/bin/bsdtar`); ZIP listings also
/// come from Arbor's own central-directory reader, which adds compressed sizes and encryption flags.
/// Creating is limited to ZIP, 7z and TAR, like Windows 11 24H2's "Compress to". Nothing here
/// modifies an existing archive.
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip, sevenZip, tar, tarGzip, tarBzip2, tarXz, tarZstd, rar, cpio, iso

    /// Name suffixes, longest first so "x.tar.gz" is not mistaken for something else.
    private static let suffixes: [(String, ArchiveFormat)] = [
        (".tar.gz", .tarGzip), (".tar.bz2", .tarBzip2), (".tar.xz", .tarXz), (".tar.zst", .tarZstd),
        (".tgz", .tarGzip), (".tbz2", .tarBzip2), (".tbz", .tarBzip2), (".txz", .tarXz), (".tzst", .tarZstd),
        (".zip", .zip), (".7z", .sevenZip), (".tar", .tar), (".rar", .rar), (".cpio", .cpio), (".iso", .iso),
    ]

    /// The format a file name suggests, or nil if it isn't an archive Arbor browses.
    public static func detect(name: String) -> ArchiveFormat? {
        let lower = name.lowercased()
        for (suffix, format) in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count { return format }
        return nil
    }

    public static func detect(_ url: URL) -> ArchiveFormat? { detect(name: url.lastPathComponent) }

    /// The name without its archive suffix: "backup.tar.gz" → "backup", "Photos.zip" → "Photos".
    public static func baseName(of name: String) -> String {
        let lower = name.lowercased()
        for (suffix, _) in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return NameRules.splitExtension(name, treatAsFolder: false).base
    }

    /// Explorer's Type column wording for the archive file itself.
    public var typeName: String {
        switch self {
        case .zip: return L10n.tr("Compressed (zipped) Folder")
        case .sevenZip: return L10n.tr("7Z File")
        case .tar: return L10n.tr("TAR File")
        case .tarGzip: return L10n.tr("GZ File")
        case .tarBzip2: return L10n.tr("BZ2 File")
        case .tarXz: return L10n.tr("XZ File")
        case .tarZstd: return L10n.tr("ZST File")
        case .rar: return L10n.tr("RAR File")
        case .cpio: return L10n.tr("CPIO File")
        case .iso: return L10n.tr("Disc Image File")
        }
    }

    /// Whether Arbor can write this format (as a new archive; existing archives are never modified).
    public var canCreate: Bool { ArchiveCreateFormat(rawValue: rawValue) != nil }
}

/// Formats offered by Compress to ▸ (Windows 11 24H2: ZIP File, 7z File, TAR File).
public enum ArchiveCreateFormat: String, Sendable, CaseIterable {
    case zip, sevenZip, tar

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        }
    }

    /// Menu title under Compress to ▸.
    public var menuTitle: String {
        switch self {
        case .zip: return L10n.tr("ZIP File")
        case .sevenZip: return L10n.tr("7z File")
        case .tar: return L10n.tr("TAR File")
        }
    }

    /// libarchive's writer name.
    public var bsdtarFormat: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return L10n.tr("7zip")
        case .tar: return "paxr"   // ustar when it fits, pax headers only for long or non-ASCII names
        }
    }
}

/// Disk images that macOS can attach (FE-171). ISO is also browsable as an archive when it can't be mounted.
public enum DiskImage {
    public static let extensions: Set<String> = ["iso", "dmg", "img", "cdr", "sparseimage", "sparsebundle", "toast"]

    public static func isDiskImage(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Mount points from `hdiutil attach -plist` output.
    public static func mountPoints(fromPlist data: Data) -> [URL] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0) }
    }
}

/// Names Arbor gives to new archives and extraction folders (Windows conventions, DEC-012 numbering).
public enum ArchiveNaming {
    public static let newZipName = "New Compressed (zipped) Folder.zip"

    /// "New Compressed (zipped) Folder.zip", then "New Compressed (zipped) Folder (2).zip".
    public static func newZipName(isTaken: (String) -> Bool) -> String {
        uniqueName(newZipName, isTaken: isTaken)
    }

    /// The archive created for a selection, named after `primary` (the first or right-clicked item):
    /// "report.docx" → "report.zip", "Photos" → "Photos.zip", ".zshrc" → ".zshrc.zip".
    public static func archiveName(for primary: String, isFolder: Bool, format: ArchiveCreateFormat,
                                   isTaken: (String) -> Bool) -> String {
        let base = NameRules.splitExtension(primary, treatAsFolder: isFolder).base
        return uniqueName("\(base.isEmpty ? primary : base).\(format.fileExtension)", isTaken: isTaken)
    }

    /// The folder Extract All proposes: the archive's name without its suffix, next to the archive.
    public static func extractionFolder(for archive: URL) -> URL {
        let base = ArchiveFormat.baseName(of: archive.lastPathComponent)
        return archive.deletingLastPathComponent().appendingPathComponent(base.isEmpty ? "Extracted" : base)
    }

    /// `name` if free, else "name (2).ext", "name (3).ext"…
    public static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) { return name }
        // Keep compound suffixes together: "a.tar.gz" → "a (2).tar.gz".
        let base = ArchiveFormat.baseName(of: name)
        let suffix = String(name.dropFirst(base.count))
        if ArchiveFormat.detect(name: name) != nil, !base.isEmpty {
            var n = 2
            while isTaken("\(base) (\(n))\(suffix)") { n += 1 }
            return "\(base) (\(n))\(suffix)"
        }
        return NameRules.keepBothName(for: name, treatAsFolder: false, isTaken: isTaken)
    }

    /// The smallest valid ZIP file: an end-of-central-directory record with no entries (22 bytes).
    public static let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
}
