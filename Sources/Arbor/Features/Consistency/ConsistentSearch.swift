import AppKit
import ArborCore

/// The search box per location: folders and pages search, Trash/archives/Network/Gallery filter in
/// place, and pages with nothing to search disable it. See docs/features/consistency.md.
enum ConsistentSearch {
    static func register() {
        SearchRegistry.wrappers.add("consistency.search-box-per-location") { inner, window in
            ScopedSearchController(window: window, inner: inner)
        }
        ExplorerSearchController.scopedRequest.register("consistency.scoped-search") { location, window in
            request(for: location, window: window)
        }
    }

    /// The search a place runs (query filled in by the caller), or nil for the default.
    static func request(for location: Location, window: BrowserWindowController?) -> SearchRequest? {
        switch location {
        case .home:
            let home = FileManager.default.homeDirectoryForCurrentUser
            let page = window.flatMap { $0.tabs.isEmpty ? nil : $0.activeTab.page as? ExplorerHomePage }
            let snapshot = page?.snapshot
            let pinned = snapshot?.quickAccess.map(\.url) ?? QuickAccess.urls
            let files = (snapshot?.favorites ?? []).map(\.item.url) + (snapshot?.recent ?? []).map(\.item.url)
            return ScopedSearch.home(userFolder: home, pinnedFolders: pinned, files: files)
        case .library(let name) where name != LibraryLogic.rootName:
            guard let library = LibraryStore.definition(name) else { return nil }
            return ScopedSearch.library(name, folders: library.folderURLs)
        case .thisMac:
            let page = window.flatMap { $0.tabs.isEmpty ? nil : $0.activeTab.page as? ThisMacPage }
            let local = (page?.volumes ?? []).filter { $0.kind != .network }.map(\.url)
            return ScopedSearch.allDrives(localVolumes: local)
        default:
            return nil
        }
    }

    /// True when the box has something to do on what's shown.
    static func isAvailable(_ window: BrowserWindowController, _ location: Location) -> Bool {
        guard !window.tabs.isEmpty, window.activeTab.displayedLocation != nil, window.activeTab.showsPage else { return true }
        if ExplorerSearchController.isSearchable(location) { return true }
        return window.activeTab.page is LocationPageFiltering
    }
}

/// Wraps the registered search controller; disables the box where it can't search.
final class ScopedSearchController: SearchController {
    private weak var window: BrowserWindowController?
    let inner: SearchController
    private(set) var isAvailable = true

    init(window: BrowserWindowController, inner: SearchController) {
        self.window = window
        self.inner = inner
    }

    static let unavailableText = L10n.tr("Nothing to search here")

    func placeholder(for location: Location) -> String {
        let text = inner.placeholder(for: location)
        guard let window else { return text }
        let available = ConsistentSearch.isAvailable(window, location)
        if available != isAvailable || window.searchBox.field.isEnabled != available {
            isAvailable = available
            window.searchBox.field.isEnabled = available
            window.searchBox.toolTip = available ? nil : L10n.tr("This page has no items to search or filter.")
            if !available { window.searchBox.text = "" }
        }
        return available ? text : Self.unavailableText
    }

    func queryChanged(_ text: String) {
        guard isAvailable else { return }
        inner.queryChanged(text)
    }

    func submit(_ text: String) {
        guard isAvailable else { return }
        inner.submit(text)
        // Pages that filter keep focus in the box only while typing; Return moves to the page.
        if let window, !window.tabs.isEmpty, window.activeTab.showsPage, window.activeTab.page is LocationPageFiltering {
            window.window?.makeFirstResponder(window.activeTab.page?.view.nextValidKeyView ?? window.activeTab.page?.view)
        }
    }

    func locationDidChange(_ location: Location) { inner.locationDidChange(location) }

    func boxText(for location: Location, filterText: String) -> String { inner.boxText(for: location, filterText: filterText) }
}

// MARK: - Pages that filter in place

extension GalleryPageController: LocationPageFiltering {
    func applyFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != filterText else { return }
        filterText = trimmed
        reloadNow()
    }
}

extension NetworkTilesPage: LocationPageFiltering {
    func applyFilter(_ text: String) {
        grid.filterText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.updateChrome()
    }
}

extension LibrariesPageController: LocationPageFiltering {
    func applyFilter(_ text: String) { filterText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Name matching shared by the page filters (the same rule as the folder filter).
enum PageFilter {
    static func matches(_ name: String, _ query: String) -> Bool {
        query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }
}
