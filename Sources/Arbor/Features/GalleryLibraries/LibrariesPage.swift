import AppKit
import ArborCore

/// A library tile. It carries a name and no file identity, so no file command can reach it (FE-239).
final class LibraryTileView: TileView {
    private let onClickToOpen: () -> Void

    init(_ library: LibraryDefinition, onClickToOpen: @escaping () -> Void) {
        self.onClickToOpen = onClickToOpen
        super.init(frame: .zero)
        let icon = NSImageView(image: LibraryStore.icon(for: library.name, size: 40))
        icon.hideFromAccessibility()   // the tile reads the library's name
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: library.name)
        name.font = Theme.bodyFont
        name.textColor = Theme.primaryText
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: L10n.tr("Library"))
        detail.font = Theme.statusFont
        detail.textColor = Theme.secondaryText
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleField = name
        toolTip = library.folders.joined(separator: "\n")
        setAccessibilityLabel(library.name)
        setAccessibilityValue(L10n.tr("Library"))
        if Prefs.singleClickToOpen, Prefs.underlineTitles == "always" { ItemClickBehavior.setUnderline(name, true) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Folder Options' "Single-click to open"; tiles have no file for the page-wide click rule to open.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let plain = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        if Prefs.singleClickToOpen, plain, event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClickToOpen()
        }
    }
}

/// "Libraries": one tile per library, like Explorer's Libraries folder.
final class LibrariesPageController: NSViewController, LocationPageStatus, LocationPageViewState, TileGridDelegate {
    weak var host: LocationHost?
    let grid = TileGridView(sectionID: "libraries")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var shown: [LibraryDefinition] = []
    private var observer: NSObjectProtocol?
    /// Search text: only libraries whose names contain it are shown.
    var filterText = "" { didSet { if filterText != oldValue, isViewLoaded { rebuild() } } }

    init(host: LocationHost?) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private var browser: BrowserWindowController? { view.window?.windowController as? BrowserWindowController }

    var selectedNames: [String] { grid.selection.compactMap { shown.indices.contains($0) ? shown[$0].name : nil } }

    /// The commands that act on one library use this; several selected tiles have no single meaning.
    var selectedLibrary: String? { selectedNames.count == 1 ? selectedNames[0] : nil }

    var statusSummary: String {
        StatusText.explorerSummary(visible: shown.count, total: LibraryStore.all.count, query: filterText,
                                   selectedCount: selectedNames.count, selectedBytes: nil)
    }

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        grid.delegate = self
        grid.setAccessibilityLabel(LibraryLogic.rootName)
        emptyLabel.font = Theme.bodyFont
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        document.addSubview(emptyLabel)
        scroll.documentView = document
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            emptyLabel.topAnchor.constraint(equalTo: grid.topAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: grid.trailingAnchor),
        ])
        root.setAccessibilityLabel(LibraryLogic.rootName)
        view = root
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.firstResponder === view.window { view.window?.makeFirstResponder(grid) }
    }

    /// Selection survives by name; the tiles are rebuilt.
    private func rebuild() {
        let keep = Set(selectedNames)
        shown = LibraryStore.all.filter { PageFilter.matches($0.name, filterText) }
        let tiles = shown.map { library -> TileView in
            let location = Location.library(library.name)
            return LibraryTileView(library) { [weak self] in self?.host?.navigate(to: location, select: []) }
        }
        grid.setTiles(tiles, keepSelection: IndexSet(shown.indices.filter { keep.contains(shown[$0].name) }))
        emptyLabel.stringValue = filterText.isEmpty
            ? L10n.tr("There are no libraries. Use New to create one, or restore the default libraries from the “…” menu.")
            : L10n.format("No libraries match “%@”.", filterText)
        emptyLabel.isHidden = !shown.isEmpty
        browser?.itemViewSelectionDidChange()
    }

    func select(names: [String]) {
        let wanted = Set(names)
        grid.select(IndexSet(shown.indices.filter { wanted.contains(shown[$0].name) }))
    }

    // MARK: LocationPageViewState

    var savedSelection: [String] { selectedNames }
    var savedScroll: String? { nil }
    func restoreViewState(selection: [String], scroll: String?) { select(names: selection) }

    // MARK: Menus

    /// A tile and a tree node share one menu and one code path.
    func tileMenu(for name: String) -> NSMenu? {
        guard let browser else { return nil }
        var ctx = browser.context(surface: .treeContextMenu, sender: grid)
        ctx.treeLocation = .library(name)
        return CommandDispatcher.shared.menu(for: .treeContextMenu, context: ctx)
    }

    // MARK: TileGridDelegate

    func tileGrid(_ grid: TileGridView, open indexes: [Int], inNewTab: Bool) {
        let locations = indexes.filter(shown.indices.contains).map { Location.library(shown[$0].name) }
        guard let first = locations.first else { return }
        if inNewTab {
            locations.forEach { host?.openInNewTab($0) }
        } else {
            host?.navigate(to: first, select: [])
            locations.dropFirst().forEach { host?.openInNewTab($0) }
        }
    }

    func tileGridSelectionChanged(_ grid: TileGridView) { browser?.itemViewSelectionDidChange() }

    func tileGridMenu(_ grid: TileGridView) -> NSMenu? {
        guard !grid.selection.isEmpty, let focus = grid.focusIndex, shown.indices.contains(focus) else {
            return browser?.contextMenu(for: .backgroundContextMenu)
        }
        return tileMenu(for: shown[focus].name)
    }

    func tileGrid(_ grid: TileGridView, unhandledKey event: NSEvent) -> Bool { browser?.itemViewKey(event) ?? false }
}
