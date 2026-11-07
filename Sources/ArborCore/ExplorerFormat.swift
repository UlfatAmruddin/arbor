import Foundation

/// Explorer's size wording (reference §5.2).
///
/// - The Details view's size columns always use whole kilobytes, rounded up, with grouping:
///   `0 KB` for an empty file, `1 KB` for 1 byte, `12,345 KB`. Folders are blank (callers pass no size).
/// - Everywhere else (status bar, tiles, tooltips, Properties, dialogs) sizes are adaptive:
///   1024-based units with three significant digits (`2.35 KB`, `14.2 MB`), see `PropertyFormat.adaptiveSize`.
public enum ExplorerSize {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    /// Whole kilobytes, rounded up (1 KB = 1024 bytes).
    public static func kilobytes(_ bytes: Int64) -> Int64 {
        guard bytes > 0 else { return 0 }
        return (bytes - 1) / 1024 + 1
    }

    /// The Details Size column text: "0 KB", "1 KB", "12,345 KB".
    public static func detailsColumn(_ bytes: Int64) -> String {
        "\(grouped.string(from: NSNumber(value: kilobytes(bytes))) ?? "\(kilobytes(bytes))") KB"
    }

    /// Adaptive size for the status bar, tiles, tooltips and dialogs.
    public static func adaptive(_ bytes: Int64) -> String { PropertyFormat.adaptiveSize(bytes) }
}

/// Explorer's menu wording inside the window (command bar menus, context menus, tab and tree menus).
/// Windows 11 uses sentence case there ("Open in new tab", "Copy as path", "Group by"); the Mac menu bar
/// keeps Mac title case. Proper names (Quick access, Finder, Terminal, Trash, Quick Look) are untouched.
public enum ExplorerMenuWording {
    static let inWindow: [String: String] = [   // values go through the string table
        "Open in New Tab": L10n.tr("Open in new tab"),
        "Open in New Window": L10n.tr("Open in new window"),
        "Open With": L10n.tr("Open with"),
        "Copy as Path": L10n.tr("Copy as path"),
        "Paste Shortcut": L10n.tr("Paste shortcut"),
        "Move Item Here": L10n.tr("Move item here"),
        "Create Shortcut": L10n.tr("Create shortcut"),
        "Create Symbolic Link": L10n.tr("Create symbolic link"),
        "Sort By": L10n.tr("Sort by"),
        "Group By": L10n.tr("Group by"),
        "Folders First": L10n.tr("Folders first"),
        "Compact View": L10n.tr("Compact view"),
        "Navigation Pane": L10n.tr("Navigation pane"),
        "Details Pane": L10n.tr("Details pane"),
        "Preview Pane": L10n.tr("Preview pane"),
        "Item Check Boxes": L10n.tr("Item check boxes"),
        "File Name Extensions": L10n.tr("File name extensions"),
        "Hidden Items": L10n.tr("Hidden items"),
        "New Tab": L10n.tr("New tab"),
        "Duplicate Tab": L10n.tr("Duplicate tab"),
        "Close Tab": L10n.tr("Close tab"),
        "Close Other Tabs": L10n.tr("Close other tabs"),
        "Close Tabs to the Right": L10n.tr("Close tabs to the right"),
        "Move Tab to New Window": L10n.tr("Move tab to new window"),
        "New Window": L10n.tr("New window"),
        "Select All": L10n.tr("Select all"),
        "Select None": L10n.tr("Select none"),
        "Invert Selection": L10n.tr("Invert selection"),
        "Batch Rename…": L10n.tr("Batch rename…"),
        "Clear Filters": L10n.tr("Clear filters"),
        "Size All Columns to Fit": L10n.tr("Size all columns to fit"),
        "Show Package Contents": L10n.tr("Show package contents"),
        "Reset This Folder's View": L10n.tr("Reset this folder's view"),
        "Map Network Drive": L10n.tr("Map network drive"),
        "Map Network Drive…": L10n.tr("Map network drive"),
        "Disconnect Network Drives": L10n.tr("Disconnect network drive"),
        "Delete Permanently…": L10n.tr("Delete permanently…"),
        "Save Search…": L10n.tr("Save search"),
        "Go to Address…": L10n.tr("Go to address…"),
    ]

    /// The in-window wording for a menu title; unknown titles are returned unchanged.
    public static func inWindowTitle(_ title: String) -> String { inWindow[title] ?? title }
}

/// The Type column's wording. Real system type names are kept ("Plain Text Document", "PNG image"),
/// with Explorer's words where macOS uses Mac-only ones.
public enum ExplorerTypeName {
    /// Uniform type of a Finder alias, the Mac counterpart of a Windows shortcut (.lnk).
    public static let aliasTypeIdentifier = "com.apple.alias-file"
    public static var shortcut: String { L10n.tr("Shortcut") }
    public static var symbolicLink: String { L10n.tr("Symbolic link") }

    /// - Parameters:
    ///   - localized: the system's localized type description of the item itself.
    ///   - typeIdentifier: the item's uniform type identifier, when known.
    ///   - isSymbolicLink: the item is a symbolic link; `targetDescription` is the type of what it points at.
    public static func name(localized: String?, typeIdentifier: String?, isFolder: Bool,
                            isSymbolicLink: Bool = false, targetDescription: String? = nil) -> String {
        if typeIdentifier == aliasTypeIdentifier { return shortcut }
        if isSymbolicLink {
            // Explorer types a link by what it points to (a link to a folder is a folder).
            if let target = targetDescription, !target.isEmpty, target != "Alias" { return target }
            return isFolder ? "Folder" : symbolicLink
        }
        // Finder calls aliases "Alias"; the identifier isn't always fetched, so match the word too.
        if localized == "Alias" { return shortcut }
        if let localized, !localized.isEmpty { return localized }
        return isFolder ? "Folder" : "Document"
    }
}
