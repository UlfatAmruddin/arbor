import AppKit
import ArborCore

/// Extension points features contribute to from `register()`; without contributions the core is unchanged.
/// Core call sites are one line: search for `InteractionHooks.` (docs/EXTENSION-POINTS.md).
enum InteractionHooks {
    /// Opening a file (not a folder) from an item view. True if handled (archive member, shortcut, broken shortcut).
    static let openFile = Handlers<(BrowserWindowController, FileItem), Void>(
        "InteractionHooks.openFile", "Opening a file from an item view; true = handled.",
        signature: "(window, file) -> handled")

    /// An inline rename was committed. nil lets the core rename; else true = done, false = keep editing (multi-item).
    static let commitRename = Handlers<(BrowserWindowController, FileItem, String), Bool>(
        "InteractionHooks.commitRename", "An inline rename was committed; answer when the feature performs it.",
        signature: "(window, item, newName) -> done?")

    /// Files dropped on a folder (item view, row, nav tree). True if handled (right-drag menu, shortcuts, dedup).
    static let drop = Handlers<(BrowserWindowController, TransferKind, [URL], URL), Void>(
        "InteractionHooks.drop", "Files dropped on a folder; true = handled.",
        signature: "(window, kind, urls, folder) -> handled")

    /// A file drag hovers over a spring-loading target (`key`; nil = left it). `activate` opens or expands it.
    static let dragHover = Observers<(key: String?, activate: (() -> Void)?)>(
        "InteractionHooks.dragHover", "A file drag rests on something that can spring open (nil = left it).",
        signature: "(key?, activate?)")

    /// Right mouse press in the Details list. True if consumed (right-button drag); else the context menu opens.
    static let rightMouseDown = Handlers<(NSTableView, NSEvent), Void>(
        "InteractionHooks.rightMouseDown", "Right mouse press in the Details list; true = consumed (right-button drag).",
        signature: "(table, event) -> consumed")

    /// Right press on an item in icon layouts. `urls` gives the files to drag (selects it first). True if a drag started.
    static let rightDrag = Handlers<(view: NSView & NSDraggingSource, event: NSEvent, urls: () -> [URL]), Void>(
        "InteractionHooks.rightDrag", "Right mouse press on an item in icon layouts; true = a right-button drag started.",
        signature: "(view, event, urls) -> started")

    /// Decorates an item's icon once per cached icon (e.g. the shortcut arrow). Answer nil to keep it.
    static let decorateIcon = Handlers<(FileItem, NSImage, CGFloat), NSImage>(
        "InteractionHooks.decorateIcon", "Decorates an item's cached icon (shortcut arrow); nil keeps it.",
        signature: "(item, icon, size) -> icon?")

    /// Extra "Label: value" detail for layouts without columns (search results: "Folder: /path"). nil for none.
    static let itemDetail = Handlers<(FileItem, Location?), (label: String, value: String)>(
        "InteractionHooks.itemDetail", "An extra \"Label: value\" line for layouts without columns.",
        signature: "(item, location) -> (label, value)?")
}
