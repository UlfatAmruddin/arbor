import Foundation

/// Drive Properties capabilities (FE-188); unreported values stay nil ("Unknown"), never guessed.
public struct VolumeCapabilityReport: Equatable, Sendable {
    public var format: FileSystemCapabilities
    public var formatDescription: String?
    public var caseSensitive: Bool?
    public var casePreserving: Bool?
    public var supportsTrash: Bool?
    public var supportsExtendedAttributes: Bool?
    public var supportsClones: Bool?
    public var supportsHardLinks: Bool?
    public var supportsSymbolicLinks: Bool?
    public var supportsCompression: Bool?
    public var isEncrypted: Bool?
    public var isJournaled: Bool?
    /// Volume-reported limit, else the format's.
    public var maximumFileSize: Int64?

    public init(format: FileSystemCapabilities) { self.format = format }

    public var isReadOnly: Bool { format.isReadOnly }

    /// NTFS gets its specific reason.
    public var readOnlyExplanation: String? {
        guard format.isReadOnly else { return nil }
        if format.kind == .ntfs {
            return "macOS can read NTFS drives but can't write to them, so files on this drive can't be changed, renamed or deleted here. To change them, copy them to another drive, or reformat the drive as exFAT (which erases it)."
        }
        if format.isNetwork { return L10n.tr("The server shares this folder read-only, or your account can only read it.") }
        return L10n.tr("This drive is mounted read-only. Files can be opened and copied, but not changed.")
    }

    public var rows: [(label: String, value: String)] {
        func yesNo(_ value: Bool?) -> String { value.map { $0 ? L10n.tr("Yes") : L10n.tr("No") } ?? L10n.tr("Unknown") }
        var rows: [(String, String)] = [
            ("File system:", formatDescription.flatMap { $0.caseInsensitiveCompare(format.displayName) == .orderedSame ? nil : $0 }
                .map { "\(format.displayName) (\($0))" } ?? format.displayName),
            (L10n.tr("Access:"), format.isReadOnly ? L10n.tr("Read-only") : L10n.tr("Read and write")),
            ("Case-sensitive names:", yesNo(caseSensitive)),
            ("Case-preserving names:", yesNo(casePreserving)),
            ("Supports the Trash:", yesNo(supportsTrash)),
            ("Extended attributes (tags, comments):", yesNo(supportsExtendedAttributes)),
            ("File clones (instant copies):", yesNo(supportsClones)),
            ("Hard links:", yesNo(supportsHardLinks)),
            ("Symbolic links:", yesNo(supportsSymbolicLinks)),
            ("Compression:", yesNo(supportsCompression)),
            ("Encrypted:", yesNo(isEncrypted)),
            ("Journaled:", yesNo(isJournaled)),
        ]
        rows.append(("Maximum file size:", Self.sizeText(maximumFileSize ?? format.maximumFileSize)))
        return rows
    }

    /// Most important first (read-only first).
    public var notes: [String] {
        var notes: [String] = []
        if let readOnly = readOnlyExplanation { notes.append(readOnly) }
        for note in format.notes where !(format.isReadOnly && (note.contains("read-only") || note.contains("can't write"))) {
            notes.append(note)
        }
        if supportsTrash == false, !format.isNetwork {
            notes.append("Items deleted on this drive can't go to the Trash; Arbor asks before deleting them permanently.")
        }
        if caseSensitive == true { notes.append("“Report.txt” and “report.txt” are different files on this drive.") }
        return notes
    }

    static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return L10n.tr("No practical limit") }
        // Huge powers of two mean no real limit.
        if bytes >= 1 << 60 { return L10n.tr("No practical limit") }
        if bytes == 4_294_967_295 { return L10n.tr("4 GB (minus 1 byte)") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Does disk I/O: call off the main thread.
    public static func read(_ url: URL) -> VolumeCapabilityReport? {
        let keys: Set<URLResourceKey> = [.volumeTypeNameKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey,
                                         .volumeSupportsCaseSensitiveNamesKey, .volumeSupportsCasePreservedNamesKey,
                                         .volumeSupportsFileCloningKey, .volumeSupportsHardLinksKey,
                                         .volumeSupportsSymbolicLinksKey, .volumeSupportsCompressionKey,
                                         .volumeIsEncryptedKey, .volumeIsJournalingKey, .volumeMaximumFileSizeKey,
                                         .volumeURLKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        var typeName = v.volumeTypeName ?? ""
        if typeName.isEmpty {
            var info = statfs()
            if statfs(url.path, &info) == 0 {
                typeName = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
        }
        var report = VolumeCapabilityReport(format: FileSystemCapabilities(
            typeName: typeName, isReadOnly: v.volumeIsReadOnly ?? false, isCaseSensitive: v.volumeSupportsCaseSensitiveNames))
        report.formatDescription = v.volumeLocalizedFormatDescription
        report.caseSensitive = v.volumeSupportsCaseSensitiveNames
        report.casePreserving = v.volumeSupportsCasePreservedNames
        report.supportsClones = v.volumeSupportsFileCloning
        report.supportsHardLinks = v.volumeSupportsHardLinks
        report.supportsSymbolicLinks = v.volumeSupportsSymbolicLinks
        report.supportsCompression = v.volumeSupportsCompression
        report.isEncrypted = v.volumeIsEncrypted
        report.isJournaled = v.volumeIsJournaling
        report.maximumFileSize = v.volumeMaximumFileSize.map(Int64.init)
        let root = v.volume ?? url
        // _PC_XATTR_SIZE_BITS: 0 = no xattrs; -1 = unknown.
        let bits = pathconf(root.path, _PC_XATTR_SIZE_BITS)
        report.supportsExtendedAttributes = bits > 0 ? true : (bits == 0 ? false : nil)
        report.supportsTrash = supportsTrash(root, readOnly: report.isReadOnly)
        return report
    }

    /// True where macOS has or can make a trash folder for the volume.
    static func supportsTrash(_ volume: URL, readOnly: Bool) -> Bool? {
        if readOnly { return false }
        if (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volume, create: false)) != nil {
            return true
        }
        return false
    }
}
