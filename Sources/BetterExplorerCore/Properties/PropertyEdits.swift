import Foundation

/// An item's editable facts (FE-150, spec §11.3). Apply writes only changed fields and never silently
/// clobbers a field another app changed meanwhile.
public struct EditableState: Equatable, Sendable {
    public var name: String
    public var locked: Bool
    public var hidden: Bool
    /// nil when unknown.
    public var mode: UInt16?
    public var tags: [String]
    public var comment: String

    public init(name: String, locked: Bool = false, hidden: Bool = false, mode: UInt16? = nil,
                tags: [String] = [], comment: String = "") {
        self.name = name
        self.locked = locked
        self.hidden = hidden
        self.mode = mode
        self.tags = tags
        self.comment = comment
    }

    public static func read(_ url: URL) throws -> EditableState {
        let flags = try FileFlags.read(url)
        var st = stat()
        let mode: UInt16? = lstat(url.path, &st) == 0 ? UInt16(st.st_mode & 0o7777) : nil
        return EditableState(name: url.lastPathComponent, locked: flags.isLocked, hidden: flags.isHidden, mode: mode,
                             tags: FinderMetadata.tags(of: url), comment: FinderMetadata.comment(of: url))
    }

    public func value(of field: EditableField) -> AnyHashable {
        switch field {
        case .name: return name
        case .locked: return locked
        case .hidden: return hidden
        case .mode: return mode.map { Int($0) } ?? -1
        case .tags: return tags
        case .comment: return comment
        }
    }
}

public enum EditableField: String, CaseIterable, Sendable {
    case name, locked, hidden, mode, tags, comment

    public var title: String {
        switch self {
        case .name: return L10n.tr("Name")
        case .locked: return L10n.tr("Read-only (Locked)")
        case .hidden: return L10n.tr("Hidden")
        case .mode: return L10n.tr("Permissions")
        case .tags: return L10n.tr("Tags")
        case .comment: return L10n.tr("Comments")
        }
    }
}

public struct PropertyApplyError: Error, LocalizedError {
    public var field: EditableField
    public var message: String
    /// Location after the failure; a rename may already have happened.
    public var url: URL
    public var errorDescription: String? { "\(field.title): \(message)" }
}

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

    /// Edited fields also changed on disk since reading, unless disk already holds the user's value.
    public func conflicts(with current: EditableState) -> [EditableField] {
        changedFields.filter { current.value(of: $0) != original.value(of: $0) && current.value(of: $0) != edited.value(of: $0) }
    }

    /// Unlocks first (a locked item refuses every change), renames last, then re-locks if needed.
    /// Stops at the first failure; returns the possibly renamed URL.
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
