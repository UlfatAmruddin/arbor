import AppKit
import ArborCore

/// Extension points in the window, tab and item views for features that adjust behavior without owning
/// those files (added for Folder Options; any feature may use them). All run on the main thread.
enum WindowHooks {
    /// A browser window finished building (status bar visibility, placement recovery…).
    static var didCreate: [(BrowserWindowController) -> Void] = []
    /// A tab's content loaded, before it is drawn. `changed` is false for a refresh of the same location.
    /// The tab's `items` are set; a hook may change `tab.viewMode` / `tab.sortOrder` (per-folder views).
    static var willDisplay: [(BrowserWindowController, TabState, Location, _ changed: Bool) -> Void] = []
    /// The active tab's items were put on screen (after mode/sort/filter changes too).
    static var didDisplay: [(BrowserWindowController, TabState) -> Void] = []
    /// The active tab's selection changed (VoiceOver selection-count announcements).
    static var selectionChanged: [(BrowserWindowController) -> Void] = []
    /// The user changed the active tab's view mode or sort order.
    static var viewStateChanged: [(BrowserWindowController, TabState) -> Void] = []
    /// Filters a loaded listing before it is cached in the tab (protected system files…).
    static var itemFilters: [([FileItem], Location) -> [FileItem]] = []
    /// Replaces a tab's title (full path in the title bar); nil keeps the provider's title.
    static var tabTitle: ((Location) -> String?)?
    /// Opening one folder from the item view; return true if the hook handled it (own window).
    static var openFolder: ((BrowserWindowController, Location) -> Bool)?
    /// Where new windows and new tabs open ("Open Arbor to:"). Explorer's default is Home (DEC-020).
    static var startLocation: () -> Location = { .home }
    /// Called once at launch when no folder was given on the command line; may open windows.
    static var restoreSession: ((AppDelegate) -> Void)?

    static func filter(_ items: [FileItem], _ location: Location) -> [FileItem] {
        itemFilters.reduce(items) { $1($0, location) }
    }
}

/// Item view decorations (Details name cells), e.g. hover underline and pop-up descriptions.
enum ItemViewHooks {
    /// Called for each name cell after it is configured.
    static var decorateName: ((NSTextField, FileItem, Int, NSTableView) -> Void)?
}

/// Navigation pane adjustments.
enum NavigationPaneHooks {
    /// Adjusts the root nodes after the pane builds them (extra roots, hidden empty drives…).
    static var adjustRoots: [([NavNode]) -> [NavNode]] = []
    /// Filters a folder's children when it is expanded.
    static var filterChildren: [([FileItem]) -> [FileItem]] = []
    /// Called before the pane marks the current location (expand to open folder).
    static var willReveal: ((NavigationPaneController, Location) -> Void)?
    /// Called for each tree cell after it is configured.
    static var decorateCell: ((NavCellView, NavNode) -> Void)?

    static func roots(_ roots: [NavNode]) -> [NavNode] { adjustRoots.reduce(roots) { $1($0) } }
    static func children(_ items: [FileItem]) -> [FileItem] { filterChildren.reduce(items) { $1($0) } }
}

/// Whether the Preview pane may run preview handlers ("Show preview handlers in preview pane").
enum PreviewPolicy {
    static var showsPreviewHandlers: () -> Bool = { true }
}
