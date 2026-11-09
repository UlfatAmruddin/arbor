import Foundation

/// What importing a file would change. The app can only get one from `make`, so every change passed the allowlist.
public struct PortableImportPlan: Sendable {
    public struct Change: Sendable {
        public let setting: PortableSetting
        public let new: PortableValue
        public let currentTitle: String
        public let newTitle: String
    }

    /// In catalog order.
    public let changes: [Change]
    /// Known settings whose value in the file isn't one of the allowed ones.
    public let invalidTitles: [String]
    /// Known settings this Mac can't use right now.
    public let unavailableTitles: [String]
    /// Keys not on the allowlist. Counted only: their names are never shown, stored or logged.
    public let ignoredCount: Int
    /// Every entry in the file was usable and already equal to the current setting.
    public let alreadyMatches: Bool

    /// Most titles a note spells out, so a crafted file can't grow an alert past the screen.
    static let noteTitleLimit = 5

    public static func make(file: PortableSettingsFile, current: (PortableSetting) -> PortableValue?,
                            unavailable: Set<String> = []) -> PortableImportPlan {
        var changes: [Change] = []
        var invalid: [String] = []
        var notAvailable: [String] = []
        var unchanged = 0
        for setting in PortableSettingsCatalog.all {
            guard let entry = file.entries[setting.key] else { continue }
            guard !unavailable.contains(setting.key) else { notAvailable.append(setting.title); continue }
            guard case .value(let value) = entry, setting.allows(value) else { invalid.append(setting.title); continue }
            let now = setting.normalized(current(setting))
            if value == now { unchanged += 1; continue }
            changes.append(Change(setting: setting, new: value, currentTitle: setting.title(of: now), newTitle: setting.title(of: value)))
        }
        let ignored = file.entries.keys.filter { PortableSettingsCatalog.setting($0) == nil }.count
        let matches = unchanged > 0 && unchanged == file.entries.count
        return PortableImportPlan(changes: changes, invalidTitles: invalid, unavailableTitles: notAvailable,
                                  ignoredCount: ignored, alreadyMatches: matches)
    }

    /// What was left out, for the preview and the nothing-to-import message; empty when nothing was.
    public var note: String {
        var lines: [String] = []
        if !invalidTitles.isEmpty { lines.append(L10n.format("Not imported, the value in the file isn't allowed: %@.", Self.list(invalidTitles))) }
        if !unavailableTitles.isEmpty { lines.append(L10n.format("Not imported, not available on this Mac: %@.", Self.list(unavailableTitles))) }
        if ignoredCount == 1 { lines.append(L10n.tr("1 other entry in the file was ignored.")) }
        if ignoredCount > 1 { lines.append(L10n.format("%d other entries in the file were ignored.", ignoredCount)) }
        return lines.joined(separator: "\n")
    }

    private static func list(_ titles: [String]) -> String {
        let shown = titles.prefix(noteTitleLimit).joined(separator: "; ")
        guard titles.count > noteTitleLimit else { return shown }
        return L10n.format("%@; and %d more", shown, titles.count - noteTitleLimit)
    }
}
