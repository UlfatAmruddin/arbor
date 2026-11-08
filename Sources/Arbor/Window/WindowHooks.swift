import AppKit
import ArborCore

/// Extension points in the window, tab and item views for features that adjust behavior without owning
/// those files (added for Folder Options; any feature may use them). All run on the main thread.
/// See docs/EXTENSION-POINTS.md.
enum WindowHooks {
    /// A browser window finished building (status bar visibility, placement recovery…).
    static let didCreate = Observers<BrowserWindowController>(
        "WindowHooks.didCreate", "A browser window finished building.", signature: "(window)")
    /// A tab's content loaded, before it is drawn. `changed` is false for a refresh of the same location.
    /// The tab's `items` are set; an observer may change `tab.viewMode` / `tab.sortOrder` (per-folder views).
    static let willDisplay = Observers<(window: BrowserWindowController, tab: TabState, location: Location, changed: Bool)>(
        "WindowHooks.willDisplay", "A tab's content loaded, before it is drawn (may set view mode and sort).",
        signature: "(window, tab, location, changed)")
    /// The active tab's items were put on screen (after mode/sort/filter changes too).
    static let didDisplay = Observers<(window: BrowserWindowController, tab: TabState)>(
        "WindowHooks.didDisplay", "The active tab's items were put on screen.", signature: "(window, tab)")
    /// The active tab's selection changed (VoiceOver selection-count announcements).
    static let selectionChanged = Observers<BrowserWindowController>(
        "WindowHooks.selectionChanged", "The active tab's selection changed.", signature: "(window)")
    /// The user changed the active tab's view mode or sort order.
    static let viewStateChanged = Observers<(window: BrowserWindowController, tab: TabState)>(
        "WindowHooks.viewStateChanged", "The user changed the active tab's view mode or sort order.", signature: "(window, tab)")
    /// Filters a loaded listing before it is cached in the tab (protected system files…).
    static let itemFilters = Pipeline<[FileItem], Location>(
        "WindowHooks.itemFilters", "Filters a loaded listing before the tab caches it.", signature: "(items, location) -> items")
    /// Replaces a tab's title (full path in the title bar); nil keeps the provider's title.
    static let tabTitle = Handlers<Location, String>(
        "WindowHooks.tabTitle", "Replaces a tab's title; nil keeps the provider's.", signature: "(location) -> title?")
    /// Opening one folder from the item view; a handler returns true if it handled it (own window).
    static let openFolder = Handlers<(BrowserWindowController, Location), Void>(
        "WindowHooks.openFolder", "Opening one folder from the item view; true = handled (opened elsewhere).",
        signature: "(window, location) -> handled")
    /// Where new windows and new tabs open ("Open Arbor to:"). Explorer's default is Home (DEC-020).
    static let startLocation = Provided<() -> Location>(
        "WindowHooks.startLocation", "Where new windows and tabs open.", signature: "() -> Location", default: { .home })
    /// Called once at launch when no folder was given on the command line; may open windows.
    static let restoreSession = Provided<((AppDelegate) -> Void)?>(
        "WindowHooks.restoreSession", "Reopens the last session's windows at launch.", signature: "(app)", default: nil)

    static func filter(_ items: [FileItem], _ location: Location) -> [FileItem] {
        itemFilters.apply(items, location)
    }
}

/// Item view decorations (Details name cells), e.g. hover underline and pop-up descriptions.
enum ItemViewHooks {
    /// Called for each name cell after it is configured.
    static let decorateName = Observers<(field: NSTextField, item: FileItem, row: Int, table: NSTableView)>(
        "ItemViewHooks.decorateName", "Each Details name cell after it is configured.", signature: "(field, item, row, table)")
    /// Layouts that draw their own names (icon views): whether item `index` of `view` is underlined.
    static let underlinesName = Handlers<(NSView, Int), Bool>(
        "ItemViewHooks.underlinesName", "Whether an icon-view item's name is underlined.", signature: "(view, index) -> Bool?")
}

/// Navigation pane adjustments.
enum NavigationPaneHooks {
    /// Adjusts the root nodes after the pane builds them (extra roots, hidden empty drives…).
    static let adjustRoots = Pipeline<[NavNode], Void>(
        "NavigationPaneHooks.adjustRoots", "Adjusts the navigation pane's root nodes.", signature: "(roots) -> roots")
    /// Filters a folder's children when it is expanded.
    static let filterChildren = Pipeline<[FileItem], Void>(
        "NavigationPaneHooks.filterChildren", "Filters a tree folder's children when it expands.", signature: "(items) -> items")
    /// Called before the pane marks the current location (expand to open folder).
    static let willReveal = Observers<(pane: NavigationPaneController, location: Location)>(
        "NavigationPaneHooks.willReveal", "Before the pane marks the current location.", signature: "(pane, location)")
    /// Called for each tree cell after it is configured.
    static let decorateCell = Observers<(cell: NavCellView, node: NavNode)>(
        "NavigationPaneHooks.decorateCell", "Each tree cell after it is configured.", signature: "(cell, node)")

    static func roots(_ roots: [NavNode]) -> [NavNode] { adjustRoots.apply(roots) }
    static func children(_ items: [FileItem]) -> [FileItem] { filterChildren.apply(items) }
}

/// Whether the Preview pane may run preview handlers ("Show preview handlers in preview pane").
enum PreviewPolicy {
    static let showsPreviewHandlers = Provided<() -> Bool>(
        "PreviewPolicy.showsPreviewHandlers", "Whether the Preview pane may run preview handlers.",
        signature: "() -> Bool", default: { true })
}
