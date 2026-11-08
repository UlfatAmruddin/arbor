import AppKit
import ArborCore

/// Callbacks from an item view to its window. Every view mode reports the same events,
/// so sorting, filtering, selection, rename, clipboard and drag and drop work in all of them.
protocol ItemViewDelegate: AnyObject {
    func itemViewOpen(_ items: [FileItem], inNewTab: Bool)
    func itemViewSelectionDidChange()
    /// The context menu for the current selection (empty selection = background menu).
    func itemViewContextMenu() -> NSMenu?
    /// Returns false if the rename failed; the view then reopens the editor with the typed text.
    func itemViewRename(_ item: FileItem, to newName: String) -> Bool
    func itemViewTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL)
    /// The user clicked a column header (or similar) to change the order.
    func itemViewSortChanged(_ order: FileSortOrder)
    /// Keys the view doesn't handle itself (F2, F5, Delete, ⌥arrows…). Return true if handled.
    func itemViewKey(_ event: NSEvent) -> Bool
}

/// What to show. Items arrive already filtered and sorted by the window (one code path for all modes).
struct ItemViewUpdate {
    var items: [FileItem]
    /// The real folder being shown, for drops onto the background. nil for virtual locations.
    var folder: URL?
    /// Names to select; nil keeps the current selection (refresh), [] clears it.
    var select: [String]?
    /// Name of the row to scroll to the top (Back/Forward restore).
    var scrollTo: String?
    /// A different location: scroll to the top and drop per-folder caches.
    var locationChanged: Bool
    /// Shown when `items` is empty ("This folder is empty.").
    var emptyText: String
    /// Whether rename/drop are allowed here.
    var allowsEditing: Bool
    /// The location shown (for per-location columns, see `DetailsColumns`).
    var location: Location? = nil
}

/// One view mode's implementation (Details today; icons, list, tiles, content later).
/// The window owns one item view at a time and swaps it when the tab's mode needs a different class.
protocol ItemViewController: NSViewController {
    var itemDelegate: ItemViewDelegate? { get set }
    /// The mode currently displayed. Set by the window when `canDisplay(_:)` is true.
    var viewMode: ViewMode { get set }
    /// True if this instance can switch to `mode` without being replaced (e.g. icon sizes).
    func canDisplay(_ mode: ViewMode) -> Bool

    func display(_ update: ItemViewUpdate)
    /// Items in display order.
    var items: [FileItem] { get }
    var selectedItems: [FileItem] { get }
    var selectedNames: [String] { get }
    func select(names: [String])
    /// Selects exactly these items. Names can repeat (search results list items from many
    /// folders), so restoring or inverting a selection must use URLs (QA-CORE-4).
    func select(urls: [URL])
    /// Name of the first fully visible item, for scroll restoration.
    var topVisibleName: String? { get }
    func focus()
    /// The view that takes keyboard focus (for focus checks and Quick Look key forwarding).
    var focusView: NSView { get }
    var isEditingName: Bool { get }
    func beginRename(named name: String, text: String?)
    func beginRenameSelection()
    /// Redraw rows in place (cut marks, extensions toggle, compact view, check boxes).
    func reloadRows()
    /// The sort shown in headers, if the view has any.
    var sortOrder: FileSortOrder { get set }
    /// Optional "Size all columns to fit".
    func sizeToFit()
}

extension ItemViewController {
    var selectedNames: [String] { selectedItems.map(\.name) }
    func sizeToFit() {}
    /// Fallback for views without their own: by name, which is exact while names are unique.
    func select(urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        select(names: items.filter { wanted.contains($0.url.standardizedFileURL) }.map(\.name))
    }
}

/// Maps each view mode to the factory that builds its view (B4). Unregistered modes fall back to Details.
///
///     ViewModeRegistry.register([.largeIcons, .mediumIcons]) { IconGridViewController() }
enum ViewModeRegistry {
    private static var factories: [ViewMode: () -> ItemViewController] = [:]
    /// The feature that registered each mode, so a duplicate names both features.
    private static var owners: [ViewMode: String] = [:]

    /// Each mode has one factory; registering a mode twice is an extension error (DEC-024).
    static func register(_ modes: [ViewMode], factory: @escaping () -> ItemViewController) {
        for mode in modes {
            guard factories[mode] == nil else {
                ExtensionRegistry.shared.report(point: "ViewModeRegistry", "view mode \(mode.rawValue) is registered twice.",
                                                contribution: ExtensionRegistry.shared.currentFeature ?? "(unknown feature)",
                                                existing: owners[mode] ?? "(unknown feature)")
                continue
            }
            factories[mode] = factory
            owners[mode] = ExtensionRegistry.shared.currentFeature ?? ""
        }
    }

    static func isRegistered(_ mode: ViewMode) -> Bool { factories[mode] != nil }

    /// The mode that will actually be shown for a requested mode.
    static func effective(_ mode: ViewMode) -> ViewMode { isRegistered(mode) ? mode : .details }

    static func make(_ mode: ViewMode) -> ItemViewController {
        let effective = effective(mode)
        guard let factory = factories[effective] ?? factories[.details] else {
            fatalError("Details view must be registered (Features.registerAll)")
        }
        let view = factory()
        view.viewMode = effective
        return view
    }
}
