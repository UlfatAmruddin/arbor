import AppKit
import ArborCore

/// What the search box calls (B5). One instance per window. The default filters the current
/// folder (DEC-014); the search feature registers a replacement:
///
///     SearchRegistry.register { window in IndexedSearchController(window: window) }
protocol SearchController: AnyObject {
    /// Placeholder text for the box, e.g. "Search Documents".
    func placeholder(for location: Location) -> String
    /// Every keystroke (already debounced by nothing — keep it cheap or debounce yourself).
    func queryChanged(_ text: String)
    /// Return was pressed in the box.
    func submit(_ text: String)
    /// The tab's location changed (the box has already been cleared).
    func locationDidChange(_ location: Location)
    /// Text the box shows when a tab becomes active.
    func boxText(for location: Location, filterText: String) -> String
}

extension SearchController {
    func placeholder(for location: Location) -> String { "Search \(location.displayName)" }
    func locationDidChange(_ location: Location) {}
    /// Text the box shows when a tab becomes active (a search tab shows its query). Default: the tab's filter text.
    func boxText(for location: Location, filterText: String) -> String { filterText }
}

enum SearchRegistry {
    private static var factory: (BrowserWindowController) -> SearchController = { FolderFilterSearch(window: $0) }

    static func register(_ make: @escaping (BrowserWindowController) -> SearchController) { factory = make }
    static func make(for window: BrowserWindowController) -> SearchController { factory(window) }
}

/// v0.1 behavior: filter the visible folder by name; Return moves focus to the first match.
final class FolderFilterSearch: SearchController {
    private weak var window: BrowserWindowController?
    init(window: BrowserWindowController) { self.window = window }

    func queryChanged(_ text: String) { window?.applyFilter(text) }

    func submit(_ text: String) {
        guard let window, let view = window.itemView else { return }
        view.focus()
        if view.selectedItems.isEmpty, let first = view.items.first { view.select(urls: [first.url]) }
    }
}
