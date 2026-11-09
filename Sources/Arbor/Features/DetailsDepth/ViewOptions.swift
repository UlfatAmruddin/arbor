import AppKit
import ArborCore

/// Per-tab columns, grouping and filters, kept aside so `TabState` stays small; reset on navigation.
final class TabViewOptions {
    /// The location these options describe.
    fileprivate(set) var locationKey: String?
    fileprivate(set) var kind: FolderKind = .general
    var columns = ColumnSet.defaults(for: .general)
    var groupBy: ColumnID?
    var groupAscending = true
    /// Bucket ids of collapsed groups.
    var collapsed: Set<String> = []
    var filters = ColumnFilters()

    /// Columns loaded for every item, not just visible rows.
    func columnsNeedingAllValues(sort: FileSortOrder) -> Set<ColumnID> {
        var set = Set(filters.columns)
        if let groupBy { set.insert(groupBy) }
        set.insert(sort.primaryColumn)
        sort.thenBy.forEach { set.insert($0.column) }
        return set.filter(ColumnCatalog.needsLoading)
    }
}

/// Column sets per folder kind and Group by memory. Folder Options sets `folderKindResolver` and backs
/// "Apply to Folders" / "Reset Folders" with `setColumnSet` / `resetColumnSets` (posts `changed`).
enum ViewOptions {
    static let changed = Notification.Name("ArborViewOptionsChanged")
    private static let storeKey = "details.columnSets"

    private struct Slot { weak var tab: TabState?; let options: TabViewOptions }
    private static var slots: [UUID: Slot] = [:]
    /// Group by per folder for this session (bounded), so going Back restores it.
    private static var groupMemory: [String: (ColumnID?, Bool)] = [:]
    private static var groupMemoryOrder: [String] = []

    /// Picks the folder kind (template) for a location.
    static let folderKindResolver = Provided<(Location, [FileItem]) -> FolderKind>(
        "ViewOptions.folderKindResolver", "The folder kind whose column set a location uses.",
        signature: "(location, items) -> FolderKind", default: defaultKind)

    /// User changed columns; Folder Options returns true if it saved them per folder, else they go to the kind.
    static let columnsEdited = Handlers<TabViewOptions, Bool>(
        "ViewOptions.columnsEdited", "The user changed a tab's columns; true = saved (for the folder).",
        signature: "(options) -> saved?")

    /// Forgets a tab's options so `options(for:)` rebuilds them.
    static func reset(_ tab: TabState) { slots[tab.id] = nil }

    /// Forgets this session's per-folder Group by memory ("Apply to Folders" / "Reset Folders").
    static func forgetGroupMemory() {
        groupMemory = [:]
        groupMemoryOrder = []
    }

    /// Forgets one location's Group by memory (a library's type changed, or it was renamed or deleted).
    static func forgetGroupMemory(forKey key: String) {
        groupMemory[key] = nil
        groupMemoryOrder.removeAll { $0 == key }
    }

    static func saveEditedColumns(_ options: TabViewOptions) {
        if columnsEdited.first(options) != true { setColumnSet(options.columns, for: options.kind) }
    }

    /// The tab's options, reset when it shows another location.
    static func options(for tab: TabState) -> TabViewOptions {
        let options: TabViewOptions
        if let slot = slots[tab.id] {
            options = slot.options
        } else {
            options = TabViewOptions()
            slots = slots.filter { $0.value.tab != nil }
            slots[tab.id] = Slot(tab: tab, options: options)
        }
        let location = tab.displayedLocation ?? tab.location
        if options.locationKey != location.key {
            if let old = options.locationKey { remember(old, options) }
            ColumnValueStore.shared.cancel(owner: DetailsDepth.allValuesOwner(tab))
            options.locationKey = location.key
            options.kind = folderKindResolver.value(location, tab.items ?? [])
            options.columns = columnSet(for: options.kind)
            if let saved = groupMemory[location.key] {
                (options.groupBy, options.groupAscending) = saved
            } else {
                options.groupBy = options.columns.groupBy
                options.groupAscending = options.columns.groupAscending
            }
            options.collapsed = []
            options.filters = ColumnFilters()
        }
        return options
    }

    /// Read-only, so chrome can't pick a folder kind before the listing loads; nil until `options(for:)` has run.
    static func existingOptions(for tab: TabState) -> TabViewOptions? {
        guard let options = slots[tab.id]?.options, options.locationKey == (tab.displayedLocation ?? tab.location).key else { return nil }
        return options
    }

    /// Records a Group by choice for the folder (Back/Forward restore it).
    static func rememberGroup(_ options: TabViewOptions) {
        if let key = options.locationKey { remember(key, options) }
    }

    private static func remember(_ key: String, _ options: TabViewOptions) {
        groupMemory[key] = (options.groupBy, options.groupAscending)
        groupMemoryOrder.removeAll { $0 == key }
        groupMemoryOrder.append(key)
        while groupMemoryOrder.count > 200 { groupMemory[groupMemoryOrder.removeFirst()] = nil }
    }

    // MARK: Column sets

    private static var saved: [String: ColumnSet] = {
        guard let data = Prefs.store.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: ColumnSet].self, from: data) else { return [:] }
        return decoded
    }()

    static func columnSet(for kind: FolderKind) -> ColumnSet { saved[kind.rawValue] ?? ColumnSet.defaults(for: kind) }

    static func setColumnSet(_ set: ColumnSet, for kind: FolderKind) {
        var set = set
        set.normalize()
        saved[kind.rawValue] = set
        persist()
    }

    static func resetColumnSets() {
        saved = [:]
        persist()
    }

    private static func persist() {
        if let data = try? JSONEncoder().encode(saved) { Prefs.store.set(data, forKey: storeKey) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: Folder kinds

    static func defaultKind(_ location: Location, _ items: [FileItem]) -> FolderKind {
        guard let url = location.folderURL?.standardizedFileURL.resolvingSymlinksInPath() else { return .general }
        let fm = FileManager.default
        let known: [(FileManager.SearchPathDirectory, FolderKind)] = [
            (.downloadsDirectory, .downloads), (.picturesDirectory, .pictures), (.musicDirectory, .music),
            (.moviesDirectory, .videos), (.documentDirectory, .documents),
        ]
        for (dir, kind) in known {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first?.standardizedFileURL.resolvingSymlinksInPath() else { continue }
            if url.path == base.path { return kind }
            // Subfolders share the template (Downloads only applies to the folder itself).
            if kind != .downloads, url.path.hasPrefix(base.path + "/") { return kind }
        }
        return FolderKind.discover(items) ?? .general
    }
}
