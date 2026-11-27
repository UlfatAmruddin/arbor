import Foundation

/// Cleans a workspace name, typed or read from the file, for plain menu and alert text.
public enum WorkspaceName {
    public static let characterLimit = 80
    /// One Character can hold endless combining marks, so scalars are bounded too.
    static let scalarLimit = 320

    /// Nil when nothing usable remains.
    public static func clean(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.lazy.filter { !isUnsafe($0) }.prefix(scalarLimit))
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(characterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// Duplicate names are compared without regard to case.
    public static func matches(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.properties.isBidiControl
        }
    }
}

/// One saved tab set: a list of places for one window (FE-027). A value that exists is always valid.
public struct Workspace: Encodable, Equatable, Sendable {
    /// In UTF-8 bytes; a longer location key would not come back from the file.
    public static let keyLengthLimit = 8192

    public let id: String
    public private(set) var name: String
    public let tabs: [SessionTab]
    public let activeTab: Int

    /// Nil without a usable name or a tab that can be stored. Back and Forward are never kept (DEC-workspaces-1).
    public init?(id: String = UUID().uuidString, name: String, tabs: [SessionTab], activeTab: Int) {
        guard let cleanName = WorkspaceName.clean(name) else { return nil }
        let storable = Self.filtered(tabs, active: activeTab, keep: Self.canStore)
        let limited = storable.items.prefix(SessionState.tabLimit)
        guard !limited.isEmpty else { return nil }
        self.id = id
        self.name = cleanName
        self.tabs = limited.map { tab in
            var place = tab
            place.back = []
            place.forward = []
            return place
        }
        self.activeTab = min(storable.active, limited.count - 1)
    }

    func renamed(to cleanName: String) -> Workspace {
        var copy = self
        copy.name = cleanName
        return copy
    }

    static func canStore(_ tab: SessionTab) -> Bool {
        tab.location.utf8.count <= keyLengthLimit && !tab.location.utf8.contains(0)
    }

    /// Filters a tab list and moves the active index along: a dropped active tab lands on its right neighbour, else the last.
    static func filtered<Item>(_ items: [Item], active: Int, keep: (Item) -> Bool) -> (items: [Item], active: Int) {
        let activeIndex = min(max(active, 0), max(items.count - 1, 0))
        var kept: [Item] = []
        var keptBeforeActive = 0
        for (index, item) in items.enumerated() where keep(item) {
            kept.append(item)
            if index < activeIndex { keptBeforeActive += 1 }
        }
        return (kept, min(keptBeforeActive, max(kept.count - 1, 0)))
    }
}
