import AppKit
import ArborCore

/// One tab's state (B8, spec §3.3, §15.3). The window has one set of views; switching tabs swaps
/// this state into them. Inactive tabs keep only compact state (location, history, selection names,
/// scroll anchor, search text, view settings) plus a bounded cached listing so switching is instant.
final class TabState {
    let id = UUID()
    var history: NavigationHistory
    var location: Location { history.current.location }
    var viewMode: ViewMode
    var sortOrder: FileSortOrder
    var searchText = ""
    /// Restored when the tab becomes active again.
    var selectedNames: [String] = []
    var topVisibleName: String?

    /// The location whose content is loaded (nil before the first load finishes).
    var displayedLocation: Location?
    /// Cached listing for `displayedLocation` (nil for custom pages, or evicted).
    var items: [FileItem]? {
        didSet { visibleCache = nil; if items != nil { TabState.touch(self) } }
    }
    /// Custom page, kept only while the tab is active.
    var page: NSViewController?
    var showsPage = false

    var loadToken = UUID()
    var pendingLoad: LoadHandle?
    var renameAfterLoad: String?
    /// Set while the tab's content is not on screen yet (restore selection/scroll when it arrives).
    var restoreOnDisplay = false

    init(location: Location, viewMode: ViewMode = Prefs.defaultViewMode, sortOrder: FileSortOrder = Prefs.sortOrder) {
        history = NavigationHistory(start: location)
        self.viewMode = viewMode
        self.sortOrder = sortOrder
    }

    /// A new tab at the same place with the same history and view (Duplicate tab).
    func duplicate() -> TabState {
        let copy = TabState(location: location, viewMode: viewMode, sortOrder: sortOrder)
        copy.history = history
        copy.selectedNames = selectedNames
        copy.topVisibleName = topVisibleName
        return copy
    }

    var title: String { WindowHooks.tabTitle?(location) ?? LocationRegistry.provider(for: location).title(for: location) }
    var icon: NSImage { LocationRegistry.provider(for: location).icon(for: location, size: 16) }

    // MARK: Visible rows

    private var visibleCache: (query: String, order: FileSortOrder, items: [FileItem])?

    /// Filtered and sorted rows, cached until the listing, query or order changes.
    var visibleItems: [FileItem] {
        guard let items else { return [] }
        if let cache = visibleCache, cache.query == searchText, cache.order == sortOrder { return cache.items }
        var filtered = FileFilter.apply(items, query: searchText)
        if let hook = TabState.visibleItemsFilter { filtered = hook(self, filtered) }
        let result = FileSorter.sorted(filtered, by: sortOrder)
        visibleCache = (searchText, sortOrder, result)
        return result
    }

    /// Feature hook (column header filters, FE-039): narrows the rows after the search text.
    /// Call `invalidateVisibleItems()` whenever its result would change.
    static var visibleItemsFilter: ((TabState, [FileItem]) -> [FileItem])?

    /// Drops the cached rows (a filter or a sort column's metadata changed).
    func invalidateVisibleItems() { visibleCache = nil }

    // MARK: Bounded listing cache shared by all tabs (spec §15.3)

    static var listingLimit = 8
    private static var recent: [Weak] = []
    private struct Weak { weak var tab: TabState? }

    /// Marks a tab's listing as recently used and evicts the oldest beyond the limit.
    static func touch(_ tab: TabState) {
        recent.removeAll { $0.tab == nil || $0.tab === tab }
        recent.append(Weak(tab: tab))
        while recent.count > listingLimit {
            let old = recent.removeFirst()
            if let t = old.tab, !t.isActive { t.items = nil }
        }
    }

    /// Set by the window for the tab on screen; active tabs are never evicted.
    var isActive = false
}
