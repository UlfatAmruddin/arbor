import AppKit
import ArborCore

/// Extension points that features contribute to (from their `register()`) to extend core interactions
/// without rewriting core files. With no contributions the core behaves as before. Core call sites are
/// one line each; search for `InteractionHooks.` to find them. See docs/EXTENSION-POINTS.md.
enum InteractionHooks {
    /// Opening a file (not a folder) from an item view. A handler returns true when it handled it
    /// (an archive member was opened, a shortcut was resolved, or a broken shortcut was reported).
    static let openFile = Handlers<(BrowserWindowController, FileItem), Void>(
        "InteractionHooks.openFile", "Opening a file from an item view; true = handled.",
        signature: "(window, file) -> handled")

    /// An inline rename was committed. Answer nil to let the core rename the item, or the result
    /// (true = done, false = keep the editor open) when the feature performed it (multi-item rename).
    static let commitRename = Handlers<(BrowserWindowController, FileItem, String), Bool>(
        "InteractionHooks.commitRename", "An inline rename was committed; answer when the feature performs it.",
        signature: "(window, item, newName) -> done?")

    /// Files were dropped on a folder (item view background or row, navigation tree). A handler returns
    /// true when it handled the drop (right-drag menu, shortcuts, de-duplicated sources).
    static let drop = Handlers<(BrowserWindowController, TransferKind, [URL], URL), Void>(
        "InteractionHooks.drop", "Files dropped on a folder; true = handled.",
        signature: "(window, kind, urls, folder) -> handled")

    /// A file drag hovers over something that can spring open (`key` identifies it; nil = left it).
    /// `activate` opens or expands it. Used for spring-loaded folders, tree nodes and tabs.
    static let dragHover = Observers<(key: String?, activate: (() -> Void)?)>(
        "InteractionHooks.dragHover", "A file drag rests on something that can spring open (nil = left it).",
        signature: "(key?, activate?)")

    /// A right mouse press in the Details list. A handler returns true when it consumed it (it
    /// started a right-button drag); otherwise the context menu opens as usual.
    static let rightMouseDown = Handlers<(NSTableView, NSEvent), Void>(
        "InteractionHooks.rightMouseDown", "Right mouse press in the Details list; true = consumed (right-button drag).",
        signature: "(table, event) -> consumed")

    /// A right mouse press on an item in another layout (icon views). `urls` returns the files to drag
    /// (it selects the pressed item first). A handler returns true when a right-button drag started.
    static let rightDrag = Handlers<(view: NSView & NSDraggingSource, event: NSEvent, urls: () -> [URL]), Void>(
        "InteractionHooks.rightDrag", "Right mouse press on an item in icon layouts; true = a right-button drag started.",
        signature: "(view, event, urls) -> started")

    /// Decorates an item's icon once per cached icon (e.g. the shortcut arrow). Answer nil to keep it.
    static let decorateIcon = Handlers<(FileItem, NSImage, CGFloat), NSImage>(
        "InteractionHooks.decorateIcon", "Decorates an item's cached icon (shortcut arrow); nil keeps it.",
        signature: "(item, icon, size) -> icon?")

    /// An extra "Label: value" detail for an item in a location (search results: "Folder: /path").
    /// Shown by layouts without columns (Content view, icon infotips). Answer nil for none.
    static let itemDetail = Handlers<(FileItem, Location?), (label: String, value: String)>(
        "InteractionHooks.itemDetail", "An extra \"Label: value\" line for layouts without columns.",
        signature: "(item, location) -> (label, value)?")
}
