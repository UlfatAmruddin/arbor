import AppKit
import ArborCore

/// Home (FE-069): Quick access tiles, Favorites and Recent, each under a collapsible header.
final class ExplorerHomeProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .home }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        let host = context.host
        return HomeLoader.load { snapshot in
            completion(.success(.custom(ExplorerHomePage(host: host, snapshot: snapshot))))
        }
    }

    func allowsItemEditing(in location: Location) -> Bool { false }
    func targetFolder(for location: Location) -> URL? { nil }
}

/// The Home sections, in Explorer's order.
enum HomeSection: String, CaseIterable {
    case quickAccess, favorites, recent

    var title: String {
        switch self {
        case .quickAccess: return "Quick access"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }

    var emptyText: String {
        switch self {
        case .quickAccess: return "Pin folders to Quick access, or visit some folders, and they'll show up here."
        case .favorites: return "After you’ve favorited some files, we’ll show them here."
        case .recent: return "After you’ve opened some files, we’ll show the most recent ones here."
        }
    }
}

/// A Quick access tile: big folder icon, name, location and a pin for pinned folders.
final class FolderTileView: TileView {
    let tile: HomeTile

    init(_ tile: HomeTile) {
        self.tile = tile
        super.init(frame: .zero)
        let icon = NSImageView(image: IconProvider.shared.folderIcon(IconProvider.shared.folderKind(for: tile.url), size: 48))
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: tile.name)
        name.font = Theme.bodyFont
        name.textColor = Theme.primaryText
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = NSTextField(labelWithString: tile.subtitle)
        subtitle.font = Theme.statusFont
        subtitle.textColor = Theme.secondaryText
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [subtitle])
        line.spacing = 4
        if tile.isPinned {
            let pin = NSImageView()
            pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
            pin.contentTintColor = Theme.secondaryText
            line.addArrangedSubview(pin)
        }
        let text = NSStackView(views: [name, line])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = tile.url.path
        setAccessibilityLabel(tile.isPinned ? "\(tile.name), \(tile.subtitle), pinned" : "\(tile.name), \(tile.subtitle)")
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class ExplorerHomePage: NSViewController, LocationPageStatus, LocationPageSelection, TileGridDelegate, HomeFileListDelegate {
    weak var host: LocationHost?
    private(set) var snapshot: HomeSnapshot
    private let grid = TileGridView(sectionID: HomeSection.quickAccess.rawValue)
    private let favorites = HomeFileList(sectionID: HomeSection.favorites.rawValue, dateTitle: "Date modified")
    private let recent = HomeFileList(sectionID: HomeSection.recent.rawValue, dateTitle: "Date accessed")
    private var headers: [HomeSection: SectionHeaderView] = [:]
    private var emptyLabels: [HomeSection: NSTextField] = [:]
    private var bodies: [HomeSection: NSView] = [:]
    private var spacers: [HomeSection: NSView] = [:]
    private let stack = NSStackView()
    private var observers: [NSObjectProtocol] = []
    private var pendingReload: DispatchWorkItem?
    private var loading: LoadHandle?
    private var syncingSelection = false

    init(host: LocationHost?, snapshot: HomeSnapshot) {
        self.host = host
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loading?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var browser: BrowserWindowController? { view.window?.windowController as? BrowserWindowController }

    // MARK: LocationPageStatus / LocationPageSelection

    var statusSummary: String {
        StatusText.explorerSummary(visible: snapshot.itemCount, total: snapshot.itemCount, query: "", selected: selectedItems)
    }

    /// The selection lives in one section at a time, like Explorer's Home.
    var selectedItems: [FileItem] {
        guard isViewLoaded else { return [] }
        if !grid.selection.isEmpty { return grid.selection.compactMap { $0 < snapshot.quickAccess.count ? snapshot.quickAccess[$0].item : nil } }
        if !favorites.selectedItems.isEmpty { return favorites.selectedItems }
        return recent.selectedItems
    }

    var activeSection: HomeSection? {
        if !grid.selection.isEmpty { return .quickAccess }
        if !favorites.selectedItems.isEmpty { return .favorites }
        if !recent.selectedItems.isEmpty { return .recent }
        return nil
    }

    // MARK: View

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 24, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        grid.delegate = self
        grid.setAccessibilityLabel("Quick access")
        favorites.delegate = self
        recent.delegate = self
        let sectionBodies: [HomeSection: NSView] = [.quickAccess: grid, .favorites: favorites, .recent: recent]
        for section in HomeSection.allCases {
            let header = SectionHeaderView(title: section.title, collapsed: Prefs.isHomeSectionCollapsed(section.rawValue))
            header.onToggle = { [weak self] collapsed in
                Prefs.setHomeSectionCollapsed(section.rawValue, collapsed)
                self?.applyVisibility()
            }
            let empty = NSTextField(wrappingLabelWithString: section.emptyText)
            empty.font = Theme.bodyFont
            empty.textColor = Theme.secondaryText
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
            headers[section] = header
            emptyLabels[section] = empty
            spacers[section] = spacer
            bodies[section] = sectionBodies[section]
            for v in [header, empty, sectionBodies[section]!, spacer] { stack.addArrangedSubview(v) }
            stack.setCustomSpacing(6, after: header)
            NSLayoutConstraint.activate([
                sectionBodies[section]!.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
                empty.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 26),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -16),
            ])
        }

        document.addSubview(stack)
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
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        root.setAccessibilityLabel("Home")
        view = root
        // Tab moves between the sections.
        grid.nextKeyView = favorites.table
        favorites.table.nextKeyView = recent.table
        recent.table.nextKeyView = grid
        apply(snapshot)
        observe()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.firstResponder === view.window { focusFirstSection() }
    }

    private func observe() {
        let nc = NotificationCenter.default
        let reload: (Notification) -> Void = { [weak self] _ in self?.scheduleReload() }
        observers.append(nc.addObserver(forName: HomeStore.changed, object: nil, queue: .main, using: reload))
        observers.append(nc.addObserver(forName: QuickAccess.changed, object: nil, queue: .main, using: reload))
        observers.append(nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? ""
            if key == HomePrefKeys.showRecentFiles || key == HomePrefKeys.showFrequentFolders || key == "showExtensions" {
                self?.scheduleReload()
            } else if key == "compactView" {
                self?.apply(self?.snapshot ?? HomeSnapshot())
            }
        })
    }

    /// Coalesces bursts (pin + store change) into one background reload.
    func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadNow() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func reloadNow() {
        loading?.cancel()
        loading = HomeLoader.load { [weak self] snapshot in self?.apply(snapshot) }
    }

    private func apply(_ new: HomeSnapshot) {
        let keepTiles = Set(grid.selection.compactMap { $0 < snapshot.quickAccess.count ? snapshot.quickAccess[$0].url : nil })
        snapshot = new
        let tiles = new.quickAccess.map { FolderTileView($0) }
        grid.setTiles(tiles, keepSelection: IndexSet(new.quickAccess.indices.filter { keepTiles.contains(new.quickAccess[$0].url) }))
        favorites.setRows(new.favorites)
        recent.setRows(new.recent)
        applyVisibility()
        browser?.updateChrome()
    }

    private func applyVisibility() {
        for section in HomeSection.allCases {
            let shown = section != .recent || snapshot.showsRecent
            let collapsed = headers[section]?.isCollapsed ?? false
            let count: Int
            switch section {
            case .quickAccess: count = snapshot.quickAccess.count
            case .favorites: count = snapshot.favorites.count
            case .recent: count = snapshot.recent.count
            }
            headers[section]?.isHidden = !shown
            spacers[section]?.isHidden = !shown
            bodies[section]?.isHidden = !shown || collapsed || count == 0
            emptyLabels[section]?.isHidden = !shown || collapsed || count > 0
            if collapsed || !shown { clearSelection(in: section) }
        }
    }

    private func clearSelection(in section: HomeSection) {
        switch section {
        case .quickAccess: grid.clearSelection()
        case .favorites: favorites.clearSelection()
        case .recent: recent.clearSelection()
        }
    }

    // MARK: Selection and focus

    private func selectionChanged(in section: HomeSection) {
        guard !syncingSelection else { return }
        syncingSelection = true
        for other in HomeSection.allCases where other != section { clearSelection(in: other) }
        syncingSelection = false
        browser?.itemViewSelectionDidChange()
    }

    /// Scripted checks and keyboard: select items by name in a section.
    func select(_ section: HomeSection, names: [String]) {
        let wanted = Set(names)
        switch section {
        case .quickAccess:
            grid.select(IndexSet(snapshot.quickAccess.indices.filter { wanted.contains(snapshot.quickAccess[$0].name) }))
            view.window?.makeFirstResponder(grid)
        case .favorites:
            favorites.select(names: names)
            view.window?.makeFirstResponder(favorites.table)
        case .recent:
            recent.select(names: names)
            view.window?.makeFirstResponder(recent.table)
        }
        selectionChanged(in: section)
    }

    func toggleSection(_ section: HomeSection) {
        guard let header = headers[section] else { return }
        header.setCollapsed(!header.isCollapsed, notify: true)
    }

    private var visibleSections: [HomeSection] {
        HomeSection.allCases.filter { bodies[$0]?.isHidden == false }
    }

    /// On arrival the first section gets keyboard focus, without selecting anything.
    private func focusFirstSection() {
        switch visibleSections.first {
        case .quickAccess: view.window?.makeFirstResponder(grid)
        case .favorites: view.window?.makeFirstResponder(favorites.table)
        case .recent: view.window?.makeFirstResponder(recent.table)
        case nil: break
        }
    }

    private func focus(_ section: HomeSection, fromEnd: Bool) {
        switch section {
        case .quickAccess: grid.takeFocus(selecting: true, fromEnd: fromEnd)
        case .favorites: favorites.focusFirstRow(last: fromEnd)
        case .recent: recent.focusFirstRow(last: fromEnd)
        }
    }

    /// Arrow keys continue into the next or previous visible section.
    private func leave(_ section: HomeSection, toward direction: Int) -> Bool {
        let sections = visibleSections
        guard let i = sections.firstIndex(of: section) else { return false }
        let j = i + direction
        guard sections.indices.contains(j) else { return false }
        clearSelection(in: section)
        focus(sections[j], fromEnd: direction < 0)
        selectionChanged(in: sections[j])
        return true
    }

    /// The menu for the current selection (or the page background), built from the registry so
    /// Open, Copy as path, Pin, Add to Favorites, Remove from Recent, Properties… all appear.
    func contextMenu(sender: NSView?) -> NSMenu? {
        guard let browser else { return nil }
        let ctx = browser.context(surface: selectedItems.isEmpty ? .backgroundContextMenu : .itemContextMenu, sender: sender)
        return CommandDispatcher.shared.menu(for: selectedItems.isEmpty ? .backgroundContextMenu : .itemContextMenu, context: ctx)
    }

    var sectionSender: NSView? {
        switch activeSection {
        case .quickAccess: return grid
        case .favorites: return favorites.table
        case .recent: return recent.table
        case nil: return nil
        }
    }

    private func open(_ items: [FileItem], inNewTab: Bool) {
        guard let browser, !items.isEmpty else { return }
        browser.open(items, inNewTab: inNewTab)
    }

    // MARK: TileGridDelegate (Quick access)

    func tileGrid(_ grid: TileGridView, open indexes: [Int], inNewTab: Bool) {
        open(indexes.compactMap { $0 < snapshot.quickAccess.count ? snapshot.quickAccess[$0].item : nil }, inNewTab: inNewTab)
    }

    func tileGridSelectionChanged(_ grid: TileGridView) {
        if !grid.selection.isEmpty { selectionChanged(in: .quickAccess) } else if !syncingSelection { browser?.itemViewSelectionDidChange() }
    }

    func tileGridMenu(_ grid: TileGridView) -> NSMenu? { contextMenu(sender: grid) }

    func tileGrid(_ grid: TileGridView, unhandledKey event: NSEvent) -> Bool { browser?.itemViewKey(event) ?? false }

    func tileGrid(_ grid: TileGridView, dragURLAt index: Int) -> URL? {
        index < snapshot.quickAccess.count ? snapshot.quickAccess[index].url : nil
    }

    func tileGrid(_ grid: TileGridView, dropFolderAt index: Int) -> URL? {
        index < snapshot.quickAccess.count ? snapshot.quickAccess[index].url : nil
    }

    /// Dropping folders on Quick access pins them (files go to Favorites); nothing is copied or moved.
    func tileGrid(_ grid: TileGridView, validateBackgroundDrop urls: [URL]) -> NSDragOperation {
        urls.isEmpty ? [] : .link
    }

    func tileGrid(_ grid: TileGridView, acceptBackgroundDrop urls: [URL]) -> Bool {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, !(FileItem(url: url)?.isPackage ?? false) { QuickAccess.pin(url) } else { files.append(url) }
        }
        if !files.isEmpty { HomeStore.addFavorites(files) }
        return true
    }

    func tileGrid(_ grid: TileGridView, leaveToward direction: Int) -> Bool { leave(.quickAccess, toward: direction) }

    // MARK: HomeFileListDelegate (Favorites, Recent)

    private func section(of list: HomeFileList) -> HomeSection { list === favorites ? .favorites : .recent }

    func fileListOpen(_ list: HomeFileList, rows: [Int], inNewTab: Bool) {
        open(rows.compactMap { $0 < list.rows.count ? list.rows[$0].item : nil }, inNewTab: inNewTab)
    }

    func fileListSelectionChanged(_ list: HomeFileList) {
        if !list.selectedItems.isEmpty { selectionChanged(in: section(of: list)) } else if !syncingSelection { browser?.itemViewSelectionDidChange() }
    }

    func fileListMenu(_ list: HomeFileList) -> NSMenu? { contextMenu(sender: list.table) }

    func fileList(_ list: HomeFileList, unhandledKey event: NSEvent) -> Bool { browser?.itemViewKey(event) ?? false }

    func fileList(_ list: HomeFileList, leaveToward direction: Int) -> Bool { leave(section(of: list), toward: direction) }

    // MARK: Debug

    var debugSummary: String {
        let qa = snapshot.quickAccess.map { "\($0.name)\($0.isPinned ? " (pinned)" : "")" }.joined(separator: ", ")
        let fav = snapshot.favorites.map(\.item.name).joined(separator: ", ")
        let rec = snapshot.recent.map(\.item.name).joined(separator: ", ")
        let collapsed = HomeSection.allCases.filter { headers[$0]?.isCollapsed == true }.map(\.rawValue).joined(separator: ",")
        let hidden = HomeSection.allCases.filter { headers[$0]?.isHidden == true }.map(\.rawValue).joined(separator: ",")
        return "home: quickAccess=[\(qa)] favorites=[\(fav)] recent=[\(rec)] collapsed=[\(collapsed)] hiddenSections=[\(hidden)] "
            + "active=\(activeSection?.rawValue ?? "-") focus=\(focusDescription)"
    }

    private var focusDescription: String {
        let responder = view.window?.firstResponder
        if responder === grid { return "quickAccess" }
        if responder === favorites.table { return "favorites" }
        if responder === recent.table { return "recent" }
        return "other"
    }
}
