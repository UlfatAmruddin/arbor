import Foundation

/// Why one item couldn't be copied, moved or replaced (FE-120, FE-121, spec §9.6).
public enum FailureKind: String, Sendable, Codable {
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

    public init(source: URL, destination: URL?, stage: FailureStage, kind: FailureKind, code: Int32, bytesNeeded: Int64? = nil) {
        self.source = source
        self.destination = destination
        self.stage = stage
        self.kind = kind
        self.code = code
        self.bytesNeeded = bytesNeeded
    }

    /// Classifies a POSIX error; permission errors check both sides to name the right one.
    public static func classify(errno code: Int32, source: URL, destination: URL?, stage: FailureStage,
                                bytesNeeded: Int64? = nil) -> TransferFailure {
        let kind: FailureKind
        switch code {
        case EBUSY, ETXTBSY: kind = .inUse
        case ENOSPC, EDQUOT: kind = .diskFull
        case EROFS: kind = .readOnlyVolume
        case ENAMETOOLONG, EILSEQ: kind = .invalidName
        case ENOENT:
            kind = FileOps.exists(source) ? .other : .notFound
        case EACCES, EPERM:
            if hasLockFlag(source) || destination.map(hasLockFlag) == true {
                kind = .locked
            } else if stage == .copying || stage == .readingFolder, access(source.path, R_OK) != 0 {
                kind = .accessDenied
            } else if let dest = destination, access(dest.deletingLastPathComponent().path, W_OK) != 0 {
                kind = .destinationAccessDenied
            } else if stage == .removingSource || stage == .moving {
                kind = .accessDenied
            } else {
                kind = .destinationAccessDenied
            }
        default: kind = .other
        }
        return TransferFailure(source: source, destination: destination, stage: stage, kind: kind, code: code,
                               bytesNeeded: kind == .diskFull ? bytesNeeded : nil)
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
        case .inUse: return source.hasDirectoryPath || FileOps.isPlainFolder(source) ? "Folder In Use" : "File In Use"
        case .accessDenied, .locked: return FileOps.isPlainFolder(source) ? "Folder Access Denied" : "File Access Denied"
        case .destinationAccessDenied, .readOnlyVolume: return "Destination Folder Access Denied"
        case .diskFull: return "Not Enough Space"
        case .notFound: return "Item Not Found"
        case .invalidName: return "Invalid File Name"
        case .other: return "Interrupted Action"
        }
    }

    /// The main sentence, in Explorer's words adapted to the Mac.
    public func message(verb: String, volumeName: String?) -> String {
        let name = source.lastPathComponent
        switch kind {
        case .inUse:
            return "The action can't be completed because the file is open in another app."
        case .accessDenied:
            return stage == .removingSource || stage == .moving
                ? "You don't have permission to remove “\(name)” from its folder."
                : "You don't have permission to read “\(name)”."
        case .locked:
            return "“\(name)” is locked. Unlock it in Get Info, then try again."
        case .destinationAccessDenied:
            return "You don't have permission to \(verb) to this folder."
        case .readOnlyVolume:
            return "The destination\(volumeName.map { " “\($0)”" } ?? "") is read-only, so nothing can be \(verb == "copy" ? "copied" : "moved") to it."
        case .diskFull:
            let needed = bytesNeeded.map { " \(StatusText.bytes($0)) is needed to \(verb) these items." } ?? ""
            return "There is not enough space on \(volumeName.map { "“\($0)”" } ?? "the destination").\(needed) Delete or move files so you have enough space."
        case .notFound:
            return "Could not find this item. This is no longer located in \(source.deletingLastPathComponent().path). Verify the item's location and try again."
        case .invalidName:
            return "The name “\(name)” isn't valid at the destination. Rename it, then try again."
        case .other:
            return "An unexpected error is keeping you from \(verb == "copy" ? "copying" : "moving") the file. If you continue to receive this error, you can use the error code to search for help with this problem."
        }
    }

    /// The second line: "Close the file and try again." / "Error 5: Input/output error".
    public var hint: String {
        switch kind {
        case .inUse: return "Close the file and try again."
        case .other: return "Error \(code): \(systemMessage)"
        default: return systemMessage
        }
    }

    /// Skip makes no sense when the whole destination is out of space or read-only.
    public var allowsSkip: Bool { kind != .diskFull && kind != .readOnlyVolume }

    /// A short form for summaries and the journal.
    public var summary: String {
        switch kind {
        case .inUse: return "The file is open in another app."
        case .accessDenied: return "Access denied."
        case .locked: return "The item is locked."
        case .destinationAccessDenied: return "The destination folder can't be written to."
        case .readOnlyVolume: return "The destination is read-only."
        case .diskFull: return "There isn't enough space at the destination."
        case .notFound: return "The item no longer exists."
        case .invalidName: return "The name isn't valid at the destination."
        case .other: return "Error \(code): \(systemMessage)"
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
