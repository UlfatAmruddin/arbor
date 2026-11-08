import AppKit
import ArborCore

/// Per-tab view options beyond sort and mode: Details columns, Group by, collapsed groups and
/// column header filters. Kept in a side table keyed by tab so `TabState` stays small.
/// Columns, grouping and filters belong to the folder shown: they reset when the tab navigates.
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

    /// Columns whose values must be loaded for every item (not just visible rows).
    func columnsNeedingAllValues(sort: FileSortOrder) -> Set<ColumnID> {
        var set = Set(filters.columns)
        if let groupBy { set.insert(groupBy) }
        set.insert(sort.primaryColumn)
        sort.thenBy.forEach { set.insert($0.column) }
        return set.filter(ColumnCatalog.needsLoading)
    }
}

/// Column sets per folder kind, Group-by memory per folder, and the hooks other features use.
///
/// API for the Folder Options / persistence feature:
///   - `ViewOptions.folderKindResolver = { location, items in … }` picks the template for a folder
///     ("Optimize this folder for"). Default: known folders (Pictures, Music, Movies, Downloads,
///     Documents) and their subfolders, else content discovery, else General items.
///   - `ViewOptions.columnSet(for:)` / `setColumnSet(_:for:)` / `resetColumnSets()` read and write the
///     saved column set of a kind ("Apply to Folders" = `setColumnSet(current, for: kind)`;
///     "Reset Folders" = `resetColumnSets()`). Changes post `ViewOptions.changed`.
///   - `ViewOptions.options(for: tab)` is the live state of one tab.
enum ViewOptions {
    static let changed = Notification.Name("ArborViewOptionsChanged")
    private static let storeKey = "details.columnSets"

    private struct Slot { weak var tab: TabState?; let options: TabViewOptions }
    private static var slots: [UUID: Slot] = [:]
    /// Group by per folder for this session (bounded), so going Back restores it.
    private static var groupMemory: [String: (ColumnID?, Bool)] = [:]
    private static var groupMemoryOrder: [String] = []

    /// The folder kind a location's column set and Group by come from (Folder Options: the folder's type).
    static let folderKindResolver = Provided<(Location, [FileItem]) -> FolderKind>(
        "ViewOptions.folderKindResolver", "The folder kind whose column set a location uses.",
        signature: "(location, items) -> FolderKind", default: defaultKind)

    /// The user changed the shown columns (Choose Details, header menu, resize, reorder). Folder Options
    /// saves them for the folder and answers true; otherwise they are saved for the folder kind.
    static let columnsEdited = Handlers<TabViewOptions, Bool>(
        "ViewOptions.columnsEdited", "The user changed a tab's columns; true = saved (for the folder).",
        signature: "(options) -> saved?")

    /// Forgets a tab's options so the next `options(for:)` rebuilds them (the folder's template changed).
    static func reset(_ tab: TabState) { slots[tab.id] = nil }

    /// Forgets this session's per-folder Group by memory ("Apply to Folders" / "Reset Folders").
    static func forgetGroupMemory() {
        groupMemory = [:]
        groupMemoryOrder = []
    }

    static func saveEditedColumns(_ options: TabViewOptions) {
        if columnsEdited.first(options) != true { setColumnSet(options.columns, for: options.kind) }
    }

    /// The tab's options, re-initialized when the tab now shows another location.
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
