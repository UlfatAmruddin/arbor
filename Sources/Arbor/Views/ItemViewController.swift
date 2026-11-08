import AppKit
import ArborCore

/// Item view to window callbacks; every view mode reports the same events.
protocol ItemViewDelegate: AnyObject {
    func itemViewOpen(_ items: [FileItem], inNewTab: Bool)
    func itemViewSelectionDidChange()
    /// The context menu for the current selection (empty selection = background menu).
    func itemViewContextMenu() -> NSMenu?
    /// False if the rename failed; the view reopens the editor with the typed text.
    func itemViewRename(_ item: FileItem, to newName: String) -> Bool
    func itemViewTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL)
    func itemViewSortChanged(_ order: FileSortOrder)
    /// Keys the view doesn't handle itself (F2, F5, Delete, ⌥arrows…). Return true if handled.
    func itemViewKey(_ event: NSEvent) -> Bool
}

/// What to show; items arrive filtered and sorted by the window.
struct ItemViewUpdate {
    var items: [FileItem]
    /// Real folder for background drops; nil for virtual locations.
    var folder: URL?
    /// Names to select; nil keeps the current selection (refresh), [] clears it.
    var select: [String]?
    /// Name of the row to scroll to the top (Back/Forward restore).
    var scrollTo: String?
    /// A different location: scroll to the top and drop per-folder caches.
    var locationChanged: Bool
    /// Shown when `items` is empty ("This folder is empty.").
    var emptyText: String
    var allowsEditing: Bool
    /// For per-location columns (`DetailsColumns`).
    var location: Location? = nil
}

/// One view mode's implementation; the window swaps it when the mode needs a different class.
protocol ItemViewController: NSViewController {
    var itemDelegate: ItemViewDelegate? { get set }
    /// Set by the window when `canDisplay(_:)` is true.
    var viewMode: ViewMode { get set }
    /// True if this instance can switch to `mode` without being replaced.
    func canDisplay(_ mode: ViewMode) -> Bool

    func display(_ update: ItemViewUpdate)
    /// Items in display order.
    var items: [FileItem] { get }
    var selectedItems: [FileItem] { get }
    var selectedNames: [String] { get }
    func select(names: [String])
    /// Selects exactly these items; by URL because names repeat in search results (QA-CORE-4).
    func select(urls: [URL])
    /// Name of the first fully visible item, for scroll restoration.
    var topVisibleName: String? { get }
    func focus()
    /// Takes keyboard focus (focus checks, Quick Look key forwarding).
    var focusView: NSView { get }
    var isEditingName: Bool { get }
    func beginRename(named name: String, text: String?)
    func beginRenameSelection()
    /// Redraws rows in place (cut marks, extensions, compact view, check boxes).
    func reloadRows()
    /// The sort shown in headers, if the view has any.
    var sortOrder: FileSortOrder { get set }
    /// Optional "Size all columns to fit".
    func sizeToFit()
}

extension ItemViewController {
    var selectedNames: [String] { selectedItems.map(\.name) }
    func sizeToFit() {}
    /// Fallback by name; exact while names are unique.
    func select(urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        select(names: items.filter { wanted.contains($0.url.standardizedFileURL) }.map(\.name))
    }
}

/// View mode factories (B4); unregistered modes fall back to Details.
///
///     ViewModeRegistry.register([.largeIcons, .mediumIcons]) { IconGridViewController() }
enum ViewModeRegistry {
    private static var factories: [ViewMode: () -> ItemViewController] = [:]
    /// Registering feature per mode, so a duplicate names both.
    private static var owners: [ViewMode: String] = [:]

    /// Registering a mode twice is an extension error (DEC-024).
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
