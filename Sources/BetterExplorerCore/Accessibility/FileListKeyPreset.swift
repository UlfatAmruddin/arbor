import Foundation

/// A registry command a file-list key can run; the raw value is the command's id.
public enum FileListCommand: String, CaseIterable, Sendable {
    case open = "file.open"
    case rename = "file.rename"
    case back = "nav.back"
    case moveToTrash = "file.trash"
    case deletePermanently = "file.deletePermanently"

    /// Holding the key must not cycle a rename open and shut, or dive through folders.
    public var repeatsWhileHeld: Bool {
        switch self {
        case .open, .rename: return false
        case .back, .moveToTrash, .deletePermanently: return true
        }
    }
}

/// The file-list keys whose meaning differs by preset (FE-066). Keys that mean the same in both stay on their commands.
public enum FileListKeyPreset: String, CaseIterable, Sendable {
    case windows, mac

    public static let preferenceKey = "keyboardPreset"
    public static let standard = FileListKeyPreset.windows

    /// Anything unrecognised is the default, so a damaged preference can't change what a key does.
    public init(stored: String) {
        self = FileListKeyPreset(rawValue: stored) ?? .standard
    }

    /// The only in-app description of a preset: a menu can't show Return as Rename's shortcut.
    public var title: String {
        switch self {
        case .windows: return L10n.tr("Windows style: Return opens, F2 renames, ⌫ goes back, fn⌫ moves to Trash")
        case .mac: return L10n.tr("Mac style: Return renames, ⌘↓ opens, ⌘↑ goes up, ⌘⌫ moves to Trash")
        }
    }

    /// Keys are bound only here, in `KeyNames.parse` spellings; nil leaves one to the focused view. `title` and the feature doc repeat them: keep both in step.
    public static let rows: [(key: String, windows: FileListCommand?, mac: FileListCommand?)] = [
        ("return", nil, .rename),
        ("enter", nil, .rename),
        ("cmd+down", nil, .open),
        ("delete", .back, nil),
        ("forwarddelete", .moveToTrash, nil),
        ("shift+forwarddelete", .deletePermanently, nil),
    ]

    private static let resolved: [(code: UInt16, modifiers: Set<String>, windows: FileListCommand?, mac: FileListCommand?)] =
        rows.compactMap { row in
            KeyNames.parse(row.key).map { ($0.code, $0.modifiers, row.windows, row.mac) }
        }

    /// `modifiers` are `KeyNames` names and must match exactly: ⌘Return is not Return.
    public func command(keyCode: UInt16, modifiers: Set<String>) -> FileListCommand? {
        guard let row = Self.resolved.first(where: { $0.code == keyCode && $0.modifiers == modifiers }) else { return nil }
        switch self {
        case .windows: return row.windows
        case .mac: return row.mac
        }
    }
}
