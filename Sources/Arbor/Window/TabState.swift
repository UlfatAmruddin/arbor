import AppKit
import ArborCore

/// One tab's state (B8, spec §3.3, §15.3), swapped into the window's single set of views.
/// Inactive tabs keep compact state plus a bounded cached listing so switching is instant.
final class TabState {
    let id = UUID()
    var history: NavigationHistory
    var location: Location { history.current.location }
    var viewMode: ViewMode
    var sortOrder: FileSortOrder
    var searchText = ""
    /// Restored when the tab becomes active again.
    var selectedNames: [String] = []
    /// Same selection as URLs; names repeat in search results (QA-CORE-4).
    var selectedURLs: [URL] = []
    var topVisibleName: String?

    /// Nil before the first load finishes.
    var displayedLocation: Location?
    /// Listing for `displayedLocation` (nil for custom pages, or evicted).
    var items: [FileItem]? {
        didSet {
            if let old = oldValue, old.count >= 10_000 { BackgroundRelease.drop(old) }
            if let cache = visibleCache, cache.items.count >= 10_000 { BackgroundRelease.drop(cache.items) }
            visibleCache = nil
            listingGeneration += 1
            if let items { TabState.touch(self, cost: CacheBudgets.listingCost(items)) } else { TabState.forget(self) }
        }
    }
    /// Custom page, kept only while the tab is active.
    var page: NSViewController?
    var showsPage = false

    var loadToken = UUID()
    var pendingLoad: LoadHandle?
    var renameAfterLoad: RenameTarget?
    /// Content not on screen yet; restore selection/scroll when it arrives.
    var restoreOnDisplay = false
    /// Next reload is a background check (watcher, tab switch): an unchanged listing leaves the view alone.
    var quietReload = false
    var quietToken: UUID?

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
        copy.selectedURLs = selectedURLs
        copy.topVisibleName = topVisibleName
        return copy
    }

    var title: String { WindowHooks.tabTitle.first(location) ?? LocationRegistry.provider(for: location).title(for: location) }
    var icon: NSImage { LocationRegistry.provider(for: location).icon(for: location, size: 16) }

    // MARK: Visible rows

    private var visibleCache: (query: String, order: FileSortOrder, items: [FileItem])?

    /// Filtered and sorted rows, cached until the listing, query or order changes.
    var visibleItems: [FileItem] {
        guard let items else { return [] }
        // While a background sort runs, the rows keep their previous order (FE-228).
        if let cache = visibleCache, cache.query == searchText, cache.order == sortOrder || isSorting { return cache.items }
        var filtered = FileFilter.apply(items, query: searchText)
        filtered = TabState.visibleItemsFilter.apply(filtered, self)
        let result = FileSorter.sorted(filtered, by: sortOrder)
        visibleCache = (searchText, sortOrder, result)
        return result
    }

    /// Column header filters (FE-039); call `invalidateVisibleItems()` when its result changes.
    static let visibleItemsFilter = Pipeline<[FileItem], TabState>(
        "TabState.visibleItemsFilter", "Narrows a tab's rows after the search text (column header filters).",
        signature: "(items, tab) -> items")

    /// Drops the cached rows and supersedes any running sort, which worked on the old rows.
    func invalidateVisibleItems() {
        visibleCache = nil
        sortGeneration += 1
        isSorting = false
    }

    private var sortGeneration = 0
    private var listingGeneration = 0
    /// A background sort for this tab is running (scripted timing waits for it).
    private(set) var isSorting = false

    /// Sorts a large uncached listing off the main thread (FE-228). Returns false if rows can be computed now;
    /// otherwise `ready` runs on main once cached. Stale results (newer request, query or listing) are dropped.
    func sortInBackground(then ready: @escaping () -> Void) -> Bool {
        guard let items else { return false }
        if let cache = visibleCache, cache.query == searchText, cache.order == sortOrder { return false }
        var filtered = FileFilter.apply(items, query: searchText)
        filtered = TabState.visibleItemsFilter.apply(filtered, self)
        guard BackgroundSort.shouldSortInBackground(filtered.count, sortOrder) else { return false }
        sortGeneration += 1
        let generation = sortGeneration, query = searchText, order = sortOrder, listing = listingGeneration
        isSorting = true
        BackgroundSort.sort(filtered, by: order, isCurrent: { [weak self] in
            guard let self else { return false }
            let current = self.sortGeneration == generation
            if current { self.isSorting = false }
            return current && self.searchText == query && self.sortOrder == order && self.listingGeneration == listing
        }, completion: { [weak self] sorted in
            guard let self else { return }
            self.visibleCache = (query, order, sorted)
            ready()
        })
        return true
    }

    // MARK: Bounded listing cache shared by all tabs (spec §15.3, FE-251)

    /// Inactive tabs share one listing byte budget, oldest evicted first; evicted tabs relist when selected.
    private(set) static var listingBudget = ListingBudget(byteLimit: CacheBudgets.tabListingBytes)
    private static var listed: [String: Weak] = [:]
    private struct Weak { weak var tab: TabState? }

    /// Marks a tab's listing as recently used and evicts the oldest inactive ones beyond the budget.
    static func touch(_ tab: TabState, cost: Int) {
        let key = tab.id.uuidString
        listed[key] = Weak(tab: tab)
        evict(listingBudget.touch(key, cost: cost, active: activeKeys))
    }

    static func forget(_ tab: TabState) {
        let key = tab.id.uuidString
        listed[key] = nil
        listingBudget.remove(key)
    }

    /// Drops inactive listings down to `bytes` (memory pressure).
    static func trimListings(toBytes bytes: Int) { evict(listingBudget.trim(toBytes: bytes, active: activeKeys)) }

    private static var activeKeys: Set<String> {
        Set(listed.compactMap { key, weak in weak.tab?.isActive == true ? key : nil })
    }

    private static func evict(_ keys: [String]) {
        for key in keys {
            let tab = listed.removeValue(forKey: key)?.tab
            tab?.items = nil
        }
    }

    deinit {
        let key = id.uuidString
        TabState.listed[key] = nil
        TabState.listingBudget.remove(key)
    }

    /// Set for the tab on screen, which is never evicted; inactive tabs also drop their sorted rows.
    var isActive = false {
        didSet { if !isActive { visibleCache = nil } }
    }
}

/// The item to rename once a listing arrives; a URL when names can repeat there (libraries).
enum RenameTarget {
    case name(String)
    case url(URL)

    func matches(_ item: FileItem) -> Bool {
        switch self {
        case .name(let name): return item.name == name
        case .url(let url): return Location.folder(item.url) == Location.folder(url)
        }
    }
}
