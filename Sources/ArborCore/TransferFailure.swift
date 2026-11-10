import Foundation

/// Why one item couldn't be copied, moved or replaced (FE-120, FE-121, spec §9.6).
public enum FailureKind: String, Sendable, Codable, CaseIterable {
    /// EBUSY / ETXTBSY: another process holds the file.
    case inUse
    /// The source can't be read.
    case accessDenied
    /// The destination folder can't be written.
    case destinationAccessDenied
    /// The item has the Locked flag (uchg/schg).
    case locked
    case diskFull
    /// The source disappeared.
    case notFound
    case readOnlyVolume
    case invalidName
    /// ENAMETOOLONG, or a tree nested deeper than Arbor walks; never fixed by truncating a name.
    case pathTooLong
    /// The destination folder, or a folder inside it, has the Locked flag.
    case destinationLocked
    /// A disk or share went away, or a folder on the way to the destination did.
    case volumeUnavailable
    /// EFBIG: the file is over the destination format's limit.
    case fileTooLarge
    case other
}

/// Where in the per-item pipeline the failure happened.
public enum FailureStage: String, Sendable, Codable {
    case copying, creatingFolder, readingFolder, moving, removingSource
}

public struct TransferFailure: Sendable, Equatable {
    public let source: URL
    public let destination: URL?
    public let stage: FailureStage
    public let kind: FailureKind
    /// The POSIX error number.
    public let code: Int32
    /// Bytes still to copy in the job, for "N MB is needed" (disk full).
    public let bytesNeeded: Int64?
    /// The one folder inside the job's destination that is at fault; nil when the destination itself is.
    public let faultySubfolder: URL?

    public init(source: URL, destination: URL?, stage: FailureStage, kind: FailureKind, code: Int32, bytesNeeded: Int64? = nil,
                faultySubfolder: URL? = nil) {
        self.source = source
        self.destination = destination
        self.stage = stage
        self.kind = kind
        self.code = code
        self.bytesNeeded = bytesNeeded
        self.faultySubfolder = faultySubfolder
    }

    /// Classifies a POSIX error, checking both sides on permission errors. `destinationLost` overrides the errno.
    public static func classify(errno code: Int32, source: URL, destination: URL?, stage: FailureStage, bytesNeeded: Int64? = nil,
                                destinationLost: Bool = false, jobDestination: URL? = nil) -> TransferFailure {
        let kind = destinationLost ? .volumeUnavailable : kind(of: code, source: source, destination: destination, stage: stage)
        let oneFolder = !destinationLost && (kind == .destinationLocked || (kind == .volumeUnavailable && code == ENOENT))
        return TransferFailure(source: source, destination: destination, stage: stage, kind: kind, code: code,
                               bytesNeeded: kind == .diskFull ? bytesNeeded : nil,
                               faultySubfolder: oneFolder ? subfolder(holding: destination, inside: jobDestination) : nil)
    }

    /// The parent of `destination`, unless that is the job's own destination.
    private static func subfolder(holding destination: URL?, inside jobDestination: URL?) -> URL? {
        guard let parent = destination?.deletingLastPathComponent(), let jobDestination else { return nil }
        return parent.standardizedFileURL.path == jobDestination.standardizedFileURL.path ? nil : parent
    }

    private static func kind(of code: Int32, source: URL, destination: URL?, stage: FailureStage) -> FailureKind {
        switch code {
        case EBUSY, ETXTBSY: return .inUse
        case ENOSPC, EDQUOT: return .diskFull
        case EROFS: return .readOnlyVolume
        case ENAMETOOLONG: return .pathTooLong
        case EILSEQ: return .invalidName
        case EFBIG: return .fileTooLarge
        case ENXIO, ENODEV, ENOTCONN, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED, ESHUTDOWN,
             ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH, ESTALE:
            return .volumeUnavailable
        case ENOENT:
            guard FileOps.exists(source) else { return .notFound }
            let parent = destination?.deletingLastPathComponent()
            return parent.map(FileOps.exists) == false ? .volumeUnavailable : .other
        case EACCES, EPERM:
            return permissionKind(source: source, destination: destination, stage: stage)
        default: return .other
        }
    }

    private static func permissionKind(source: URL, destination: URL?, stage: FailureStage) -> FailureKind {
        let folder = stage == .removingSource || stage == .readingFolder ? nil : destination?.deletingLastPathComponent()
        let folderLocked = folder.map(hasLockFlag) == true
        // A locked source doesn't stop a copy, so a locked destination is the cause even when both are.
        if folderLocked, stage == .copying || stage == .creatingFolder { return .destinationLocked }
        if hasLockFlag(source) || destination.map(hasLockFlag) == true { return .locked }
        if folderLocked { return .destinationLocked }
        if stage == .copying || stage == .readingFolder, access(source.path, R_OK) != 0 { return .accessDenied }
        if let destination, access(destination.deletingLastPathComponent().path, W_OK) != 0 { return .destinationAccessDenied }
        return stage == .removingSource || stage == .moving ? .accessDenied : .destinationAccessDenied
    }

    static func hasLockFlag(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
    }

    public var systemMessage: String { String(cString: strerror(code)) }

    /// Explorer's dialog title for this failure (windows11-reference §9.6, RECALL).
    public var title: String {
        switch kind {
        case .inUse: return source.hasDirectoryPath || FileOps.isPlainFolder(source) ? L10n.tr("Folder In Use") : L10n.tr("File In Use")
        case .accessDenied, .locked: return FileOps.isPlainFolder(source) ? L10n.tr("Folder Access Denied") : L10n.tr("File Access Denied")
        case .destinationAccessDenied, .readOnlyVolume: return L10n.tr("Destination Folder Access Denied")
        case .diskFull: return L10n.tr("Not Enough Space")
        case .notFound: return L10n.tr("Item Not Found")
        case .invalidName: return L10n.tr("Invalid File Name")
        case .pathTooLong: return L10n.tr("Path Too Long")
        case .destinationLocked: return L10n.tr("Destination Folder Locked")
        case .volumeUnavailable: return L10n.tr("Location Not Available")
        case .fileTooLarge: return L10n.tr("File Too Large")
        case .other: return L10n.tr("Interrupted Action")
        }
    }

    /// The main sentence, in Explorer's words adapted to the Mac.
    public func message(verb: String, volumeName: String?) -> String {
        let name = source.lastPathComponent
        switch kind {
        case .inUse:
            return L10n.tr("The action can't be completed because the file is open in another app.")
        case .accessDenied:
            return stage == .removingSource || stage == .moving
                ? L10n.format("You don't have permission to remove “%@” from its folder.", name)
                : L10n.format("You don't have permission to read “%@”.", name)
        case .locked:
            return L10n.format("“%@” is locked. Unlock it in Get Info, then try again.", name)
        case .destinationAccessDenied:
            return verb == "copy" ? L10n.tr("You don't have permission to copy to this folder.") : L10n.tr("You don't have permission to move to this folder.")
        case .readOnlyVolume:
            if let volumeName {
                return verb == "copy" ? L10n.format("The destination “%@” is read-only, so nothing can be copied to it.", volumeName)
                    : L10n.format("The destination “%@” is read-only, so nothing can be moved to it.", volumeName)
            }
            return verb == "copy" ? L10n.tr("The destination is read-only, so nothing can be copied to it.")
                : L10n.tr("The destination is read-only, so nothing can be moved to it.")
        case .diskFull:
            var sentences = [volumeName.map { L10n.format("There is not enough space on “%@”.", $0) } ?? L10n.tr("There is not enough space on the destination.")]
            if let bytesNeeded {
                let size = StatusText.bytes(bytesNeeded)
                sentences.append(verb == "copy" ? L10n.format("%@ is needed to copy these items.", size) : L10n.format("%@ is needed to move these items.", size))
            }
            sentences.append(L10n.tr("Delete or move files so you have enough space."))
            return sentences.joined(separator: " ")
        case .notFound:
            return L10n.format("Could not find this item. This is no longer located in %@. Verify the item's location and try again.", BidiText.path(source.deletingLastPathComponent().path))
        case .invalidName:
            return L10n.format("The name “%@” isn't valid at the destination. Rename it, then try again.", name)
        case .pathTooLong:
            return L10n.format("The name or location of “%@” would be too long, or nested too deeply, at the destination. Use a shorter name or a folder nearer the top of the disk, then try again.", name)
        case .destinationLocked:
            if let folder = faultySubfolder?.lastPathComponent {
                return L10n.format("The folder “%@” is locked. Unlock it in Get Info, then try again.", folder)
            }
            return L10n.tr("The destination folder is locked. Unlock it in Get Info, then try again.")
        case .volumeUnavailable:
            if let folder = faultySubfolder?.lastPathComponent {
                return L10n.format("The folder “%@” is no longer at the destination.", folder)
            }
            return L10n.tr("This location is no longer available. If it's on a disk or server, reconnect it, then try again.")
        case .fileTooLarge:
            return L10n.format("“%@” is too large for the format of the destination.", name)
        case .other:
            return verb == "copy"
                ? L10n.tr("An unexpected error is keeping you from copying the file. If you continue to receive this error, you can use the error code to search for help with this problem.")
                : L10n.tr("An unexpected error is keeping you from moving the file. If you continue to receive this error, you can use the error code to search for help with this problem.")
        }
    }

    /// The second line: "Close the file and try again." / "Error 5: Input/output error".
    public var hint: String {
        switch kind {
        case .inUse: return L10n.tr("Close the file and try again.")
        case .other: return L10n.format("Error %d: %@", code, systemMessage)
        default: return systemMessage
        }
    }

    /// Skip makes no sense when the problem is the whole destination, not this item.
    public var allowsSkip: Bool {
        switch kind {
        case .diskFull, .readOnlyVolume: return false
        case .destinationLocked, .volumeUnavailable: return faultySubfolder != nil
        default: return true
        }
    }

    /// A short form for summaries and the journal.
    public var summary: String {
        switch kind {
        case .inUse: return L10n.tr("The file is open in another app.")
        case .accessDenied: return L10n.tr("Access denied.")
        case .locked: return L10n.tr("The item is locked.")
        case .destinationAccessDenied: return L10n.tr("The destination folder can't be written to.")
        case .readOnlyVolume: return L10n.tr("The destination is read-only.")
        case .diskFull: return L10n.tr("There isn't enough space at the destination.")
        case .notFound: return L10n.tr("The item no longer exists.")
        case .invalidName: return L10n.tr("The name isn't valid at the destination.")
        case .pathTooLong: return L10n.tr("The path is too long or nested too deeply.")
        case .destinationLocked:
            if let folder = faultySubfolder?.lastPathComponent { return L10n.format("The folder “%@” is locked.", folder) }
            return L10n.tr("The destination folder is locked.")
        case .volumeUnavailable:
            if let folder = faultySubfolder?.lastPathComponent { return L10n.format("The folder “%@” is no longer at the destination.", folder) }
            return L10n.tr("The location is no longer available.")
        case .fileTooLarge: return L10n.tr("The file is too large for the destination.")
        case .other: return L10n.format("Error %d: %@", code, systemMessage)
        }
    }
}

public enum FailureChoice: Sendable, Equatable {
    case retry, skip, cancel
}

public struct FailureDecision: Sendable, Equatable {
    public var choice: FailureChoice
    /// "Do this for all current items": skip later failures of the same kind without asking.
    public var applyToRemaining: Bool

    public init(_ choice: FailureChoice, applyToRemaining: Bool = false) {
        self.choice = choice
        self.applyToRemaining = applyToRemaining
    }
}
