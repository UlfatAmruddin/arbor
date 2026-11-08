import AppKit
import ArborCore

/// Optional: a custom page whose content the search box filters in place (Gallery, Network, the
/// Libraries page), like `BrowserWindowController.applyFilter(_:)` does for item lists. "" clears it.
protocol LocationPageFiltering: AnyObject {
    func applyFilter(_ text: String)
}

/// Optional: a custom page that keeps its selection and scroll position in the tab's history, so
/// Back, Forward and switching tabs return to the same place (Home). The values are opaque strings
/// the page itself understands; they are stored where item views store selected names and the top row.
protocol LocationPageViewState: AnyObject {
    var savedSelection: [String] { get }
    var savedScroll: String? { get }
    /// Called after the page is on screen.
    func restoreViewState(selection: [String], scroll: String?)
}

/// Quick Look and the Preview pane for items that aren't plain files on disk (archive members).
enum PreviewHooks {
    /// A local file to preview for `item`, or nil to preview `item.url`. May start preparing one and
    /// post `ready` when it exists.
    static let localURL = Handlers<FileItem, URL>(
        "PreviewHooks.localURL", "A local file to preview for an item that isn't on disk (archive members).",
        signature: "(item) -> url?")
    /// Posted (main thread) when a prepared preview file became available.
    static let ready = Notification.Name("ArborPreviewReady")

    static func url(for item: FileItem) -> URL { localURL.first(item) ?? item.url }
}
