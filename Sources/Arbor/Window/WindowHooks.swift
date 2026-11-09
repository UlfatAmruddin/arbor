import AppKit
import ArborCore

/// Window, tab and item view extension points for features (docs/EXTENSION-POINTS.md). Main thread only.
enum WindowHooks {
    static let didCreate = Observers<BrowserWindowController>(
        "WindowHooks.didCreate", "A browser window finished building.", signature: "(window)")
    /// `changed` is false for a same-location refresh; observers may set `tab.viewMode` / `tab.sortOrder`.
    static let willDisplay = Observers<(window: BrowserWindowController, tab: TabState, location: Location, changed: Bool)>(
        "WindowHooks.willDisplay", "A tab's content loaded, before it is drawn (may set view mode and sort).",
        signature: "(window, tab, location, changed)")
    /// Also after mode/sort/filter changes.
    static let didDisplay = Observers<(window: BrowserWindowController, tab: TabState)>(
        "WindowHooks.didDisplay", "The active tab's items were put on screen.", signature: "(window, tab)")
    static let selectionChanged = Observers<BrowserWindowController>(
        "WindowHooks.selectionChanged", "The active tab's selection changed.", signature: "(window)")
    static let viewStateChanged = Observers<(window: BrowserWindowController, tab: TabState)>(
        "WindowHooks.viewStateChanged", "The user changed the active tab's view mode or sort order.", signature: "(window, tab)")
    static let itemFilters = Pipeline<[FileItem], Location>(
        "WindowHooks.itemFilters", "Filters a loaded listing before the tab caches it.", signature: "(items, location) -> items")
    static let tabTitle = Handlers<Location, String>(
        "WindowHooks.tabTitle", "Replaces a tab's title; nil keeps the provider's.", signature: "(location) -> title?")
    static let openFolder = Handlers<(BrowserWindowController, Location), Void>(
        "WindowHooks.openFolder", "Opening one folder from the item view; true = handled (opened elsewhere).",
        signature: "(window, location) -> handled")
    /// Explorer's default is Home (DEC-020).
    static let startLocation = Provided<() -> Location>(
        "WindowHooks.startLocation", "Where new windows and tabs open.", signature: "() -> Location", default: { .home })
    /// Called once at launch when no folder was given on the command line.
    static let restoreSession = Provided<((AppDelegate) -> Void)?>(
        "WindowHooks.restoreSession", "Reopens the last session's windows at launch.", signature: "(app)", default: nil)

    static func filter(_ items: [FileItem], _ location: Location) -> [FileItem] {
        itemFilters.apply(items, location)
    }
}

/// Item view decorations (Details name cells).
enum ItemViewHooks {
    static let decorateName = Observers<(field: NSTextField, item: FileItem, row: Int, table: NSTableView)>(
        "ItemViewHooks.decorateName", "Each Details name cell after it is configured.", signature: "(field, item, row, table)")
    /// For layouts that draw their own names (icon views).
    static let underlinesName = Handlers<(NSView, Int), Bool>(
        "ItemViewHooks.underlinesName", "Whether an icon-view item's name is underlined.", signature: "(view, index) -> Bool?")
}

enum NavigationPaneHooks {
    static let adjustRoots = Pipeline<[NavNode], Void>(
        "NavigationPaneHooks.adjustRoots", "Adjusts the navigation pane's root nodes.", signature: "(roots) -> roots")
    static let filterChildren = Pipeline<[FileItem], Void>(
        "NavigationPaneHooks.filterChildren", "Filters a tree folder's children when it expands.", signature: "(items) -> items")
    static let willReveal = Observers<(pane: NavigationPaneController, location: Location)>(
        "NavigationPaneHooks.willReveal", "Before the pane marks the current location.", signature: "(pane, location)")
    static let decorateCell = Observers<(cell: NavCellView, node: NavNode)>(
        "NavigationPaneHooks.decorateCell", "Each tree cell after it is configured.", signature: "(cell, node)")
    static let didExpand = Observers<(pane: NavigationPaneController, node: NavNode)>(
        "NavigationPaneHooks.didExpand", "A tree node was expanded.", signature: "(pane, node)")

    static func roots(_ roots: [NavNode]) -> [NavNode] { adjustRoots.apply(roots) }
    static func children(_ items: [FileItem]) -> [FileItem] { filterChildren.apply(items) }
}

enum PreviewPolicy {
    static let showsPreviewHandlers = Provided<() -> Bool>(
        "PreviewPolicy.showsPreviewHandlers", "Whether the Preview pane may run preview handlers.",
        signature: "() -> Bool", default: { true })
}
