import AppKit
import ArborCore

/// Optional: a custom page (Home, This Mac…) whose items can be selected. The window then uses
/// this selection for commands (Copy, Copy as path, Share, Open…), the status bar and side panes,
/// exactly as it does for the item views. Call `BrowserWindowController.itemViewSelectionDidChange()`
/// when it changes.
protocol LocationPageSelection: AnyObject {
    var selectedItems: [FileItem] { get }
}

/// Window events features can observe without editing the window controller.
enum LocationEvents {
    /// A tab committed a navigation to a new location (not Back/Forward/Refresh).
    /// `object` is the window controller; `userInfo["location"]` is the `Location`.
    static let didVisit = Notification.Name("ArborDidVisitLocation")
    /// Files were opened with their apps from Arbor. `userInfo["urls"]` is `[URL]`.
    static let didOpenFiles = Notification.Name("ArborDidOpenFiles")
}
