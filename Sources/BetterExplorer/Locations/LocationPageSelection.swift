import AppKit
import BetterExplorerCore

/// Optional: a custom page (Home, This Mac…) with selectable items, used for commands, status bar and
/// side panes like item views. Call `BrowserWindowController.itemViewSelectionDidChange()` on change.
protocol LocationPageSelection: AnyObject {
    var selectedItems: [FileItem] { get }
}

/// Window events features can observe without editing the window controller.
enum LocationEvents {
    /// A tab committed a navigation to a new location (not Back/Forward/Refresh).
    /// `object` is the window controller; `userInfo["location"]` is the `Location`.
    static let didVisit = Notification.Name("BetterExplorerDidVisitLocation")
    /// Files were opened with their apps from Better Explorer. `userInfo["urls"]` is `[URL]`.
    static let didOpenFiles = Notification.Name("BetterExplorerDidOpenFiles")
}
