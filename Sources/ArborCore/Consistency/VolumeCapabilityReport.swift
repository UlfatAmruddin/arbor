import Foundation

/// What a drive's file system can do, for drive Properties (FE-188): the format (from
/// `FileSystemCapabilities`) plus what the volume itself reports. Values the system doesn't report
/// stay nil and are shown as "Unknown", never guessed.
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
    /// Largest file the volume accepts, if it reports one (or the format's own limit).
    public var maximumFileSize: Int64?

    public init(format: FileSystemCapabilities) { self.format = format }

    public var isReadOnly: Bool { format.isReadOnly }

    /// A sentence for read-only drives (NTFS gets the specific reason).
    public var readOnlyExplanation: String? {
        guard format.isReadOnly else { return nil }
        if format.kind == .ntfs {
            return "macOS can read NTFS drives but can't write to them, so files on this drive can't be changed, renamed or deleted here. To change them, copy them to another drive, or reformat the drive as exFAT (which erases it)."
        }
        if format.isNetwork { return "The server shares this folder read-only, or your account can only read it." }
        return "This drive is mounted read-only. Files can be opened and copied, but not changed."
    }

    /// Label and value rows in display order.
    public var rows: [(label: String, value: String)] {
        func yesNo(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Unknown" }
        var rows: [(String, String)] = [
            ("File system:", formatDescription.flatMap { $0.caseInsensitiveCompare(format.displayName) == .orderedSame ? nil : $0 }
                .map { "\(format.displayName) (\($0))" } ?? format.displayName),
            ("Access:", format.isReadOnly ? "Read-only" : "Read and write"),
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

    /// Limits worth telling the user, most important first (read-only first).
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
        guard let bytes, bytes > 0 else { return "No practical limit" }
        // Volumes report huge powers of two when there is no real limit.
        if bytes >= 1 << 60 { return "No practical limit" }
        if bytes == 4_294_967_295 { return "4 GB (minus 1 byte)" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Reads a volume's capabilities. Does disk I/O: call off the main thread.
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
        // _PC_XATTR_SIZE_BITS: 0 = no extended attributes; -1 = the volume doesn't say.
        let bits = pathconf(root.path, _PC_XATTR_SIZE_BITS)
        report.supportsExtendedAttributes = bits > 0 ? true : (bits == 0 ? false : nil)
        report.supportsTrash = supportsTrash(root, readOnly: report.isReadOnly)
        return report
    }

    /// The Trash works where macOS has (or can make) a trash folder for the volume.
    static func supportsTrash(_ volume: URL, readOnly: Bool) -> Bool? {
        if readOnly { return false }
        if (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volume, create: false)) != nil {
            return true
        }
        return false
    }
}
