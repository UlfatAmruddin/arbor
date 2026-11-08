import Foundation

/// The editable facts of one item, as read when the Properties window opened and as edited by the
/// user. Apply writes only fields that differ (FE-150, spec §11.3), and refuses to clobber a
/// field that another app changed meanwhile without asking.
public struct EditableState: Equatable, Sendable {
    public var name: String
    public var locked: Bool
    public var hidden: Bool
    /// POSIX mode bits (nil when unknown).
    public var mode: UInt16?
    public var tags: [String]
    public var comment: String
    public var quarantined: Bool

    public init(name: String, locked: Bool = false, hidden: Bool = false, mode: UInt16? = nil,
                tags: [String] = [], comment: String = "", quarantined: Bool = false) {
        self.name = name
        self.locked = locked
        self.hidden = hidden
        self.mode = mode
        self.tags = tags
        self.comment = comment
        self.quarantined = quarantined
    }

    public static func read(_ url: URL) throws -> EditableState {
        let flags = try FileFlags.read(url)
        var st = stat()
        let mode: UInt16? = lstat(url.path, &st) == 0 ? UInt16(st.st_mode & 0o7777) : nil
        return EditableState(name: url.lastPathComponent, locked: flags.isLocked, hidden: flags.isHidden, mode: mode,
                             tags: FinderMetadata.tags(of: url), comment: FinderMetadata.comment(of: url),
                             quarantined: FinderMetadata.isQuarantined(url))
    }

    public func value(of field: EditableField) -> AnyHashable {
        switch field {
        case .name: return name
        case .locked: return locked
        case .hidden: return hidden
        case .mode: return mode.map { Int($0) } ?? -1
        case .tags: return tags
        case .comment: return comment
        case .quarantine: return quarantined
        }
    }
}

public enum EditableField: String, CaseIterable, Sendable {
    case name, locked, hidden, mode, tags, comment, quarantine

    public var title: String {
        switch self {
        case .name: return L10n.tr("Name")
        case .locked: return L10n.tr("Read-only (Locked)")
        case .hidden: return L10n.tr("Hidden")
        case .mode: return L10n.tr("Permissions")
        case .tags: return L10n.tr("Tags")
        case .comment: return L10n.tr("Comments")
        case .quarantine: return L10n.tr("Unblock")
        }
    }
}

public struct PropertyApplyError: Error, LocalizedError {
    public var field: EditableField
    public var message: String
    /// Where the item is after the failure (a rename may already have happened).
    public var url: URL
    public var errorDescription: String? { "\(field.title): \(message)" }
}

/// A pending set of edits for one item.
public struct PropertyChangePlan: Sendable {
    public var url: URL
    public var original: EditableState
    public var edited: EditableState

    public init(url: URL, original: EditableState, edited: EditableState) {
        self.url = url
        self.original = original
        self.edited = edited
    }

    public var changedFields: [EditableField] {
        EditableField.allCases.filter { original.value(of: $0) != edited.value(of: $0) }
    }

    public var hasChanges: Bool { !changedFields.isEmpty }

    /// Fields the user changed that were also changed on disk since the window read them.
    /// A field that now already holds the user's value is not a conflict.
    public func conflicts(with current: EditableState) -> [EditableField] {
        changedFields.filter { current.value(of: $0) != original.value(of: $0) && current.value(of: $0) != edited.value(of: $0) }
    }

    /// Applies the changed fields in a safe order and returns the item's (possibly renamed) URL.
    ///
    /// Order: unlock if the item is locked and anything must change (a locked item refuses every
    /// change), then permissions, hidden, tags, comment and unblock, then rename, then lock again if
    /// the final state is locked. Stops at the first failure.
    public func apply(fileManager: FileManager = .default) throws -> URL {
        let fields = changedFields
        guard !fields.isEmpty else { return url }
        var url = self.url
        func step(_ field: EditableField, _ body: () throws -> Void) throws {
            do { try body() } catch {
                throw PropertyApplyError(field: field, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, url: url)
            }
        }
        let currentlyLocked = (try? FileFlags.read(url).isLocked) ?? original.locked
        let needsUnlock = currentlyLocked && fields.contains { $0 != .locked } || (currentlyLocked && !edited.locked)
        if needsUnlock {
            try step(.locked) { try FileFlags.update(url, locked: false) }
        }
        do {
            if fields.contains(.mode), let mode = edited.mode {
                try step(.mode) { try ItemSecurity.setPermissions(PosixPermissions(mode: mode), on: url) }
            }
            if fields.contains(.hidden) {
                try step(.hidden) { try FileFlags.update(url, hidden: edited.hidden) }
            }
            if fields.contains(.tags) {
                try step(.tags) { try FinderMetadata.setTags(edited.tags, on: url) }
            }
            if fields.contains(.comment) {
                try step(.comment) { try FinderMetadata.setComment(edited.comment, on: url) }
            }
            if fields.contains(.quarantine), !edited.quarantined {
                try step(.quarantine) { try FinderMetadata.removeQuarantine(from: url) }
            }
            if fields.contains(.name) {
                try step(.name) { url = try Renamer.rename(url, to: edited.name, fileManager: fileManager) }
            }
        } catch {
            // Never leave an item unlocked because a later step failed.
            if needsUnlock, edited.locked || !fields.contains(.locked) { _ = try? FileFlags.update(url, locked: true) }
            throw error
        }
        if edited.locked, needsUnlock || fields.contains(.locked) {
            try step(.locked) { try FileFlags.update(url, locked: true) }
        }
        return url
    }
}
