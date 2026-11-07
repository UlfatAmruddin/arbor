import AppKit
import ArborCore

/// Optional hooks that features install (from their `register()`) to extend core interactions
/// without rewriting core files. Every hook is nil by default, and the core behaves as before.
/// Core call sites are one line each; search for `InteractionHooks.` to find them.
enum InteractionHooks {
    /// Opening a file (not a folder) from an item view. Return true when the feature handled it
    /// (e.g. a shortcut was resolved, or a broken shortcut was reported).
    static var openFile: ((BrowserWindowController, FileItem) -> Bool)?

    /// An inline rename was committed. Return nil to let the core rename the item, or the result
    /// (true = done, false = keep the editor open) when the feature performed it (multi-item rename).
    static var commitRename: ((BrowserWindowController, FileItem, String) -> Bool?)?

    /// Files were dropped on a folder (item view background or row, navigation tree). Return true
    /// when the feature handled the drop (right-drag menu, shortcuts, de-duplicated sources).
    static var drop: ((BrowserWindowController, TransferKind, [URL], URL) -> Bool)?

    /// A file drag hovers over something that can spring open (`key` identifies it; nil = left it).
    /// `activate` opens or expands it. Used for spring-loaded folders, tree nodes and tabs.
    static var dragHover: ((_ key: String?, _ activate: (() -> Void)?) -> Void)?

    /// A right mouse press in the Details list. Return true when the feature consumed it (it
    /// started a right-button drag); otherwise the context menu opens as usual.
    static var rightMouseDown: ((NSTableView, NSEvent) -> Bool)?

    /// A right mouse press on an item in another layout (icon views). `urls` returns the files to drag
    /// (it selects the pressed item first). Return true when a right-button drag started.
    static var rightDrag: ((NSView & NSDraggingSource, NSEvent, _ urls: @escaping () -> [URL]) -> Bool)?

    /// Decorates an item's icon once per cached icon (e.g. the shortcut arrow). Return nil to keep it.
    static var decorateIcon: ((FileItem, NSImage, CGFloat) -> NSImage?)?

    /// An extra "Label: value" detail for an item in a location (search results: "Folder: /path").
    /// Shown by layouts without columns (Content view, icon infotips). Return nil for none.
    static var itemDetail: ((FileItem, Location?) -> (label: String, value: String)?)?
}
