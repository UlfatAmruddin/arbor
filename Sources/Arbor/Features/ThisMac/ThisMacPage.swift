import AppKit
import ArborCore

/// This Mac (FE-074), Explorer's This PC: drive tiles grouped under "Devices and drives" and
/// "Network locations", with capacity bars. Reloads when volumes mount, unmount or are renamed.
final class ThisMacPageProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .thisMac }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        let handle = LoadHandle()
        let host = context.host
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = VolumeCatalog.summaries(detailed: true)
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                completion(.success(.custom(ThisMacPage(host: host, volumes: volumes))))
            }
        }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? { VolumeWatcher(onChange: onChange) }
    func allowsItemEditing(in location: Location) -> Bool { false }
    func targetFolder(for location: Location) -> URL? { nil }
    func emptyText(for location: Location) -> String { L10n.tr("No drives are connected.") }
}

/// A drive tile: icon, name, capacity bar and "X GB free of Y GB".
final class DriveTileView: TileView {
    let volume: VolumeSummary
    private let bar = CapacityBarView()

    init(_ volume: VolumeSummary) {
        self.volume = volume
        super.init(frame: .zero)
        let icon = NSImageView(image: VolumeCatalog.iconOverride?(volume, 48) ?? VolumeCatalog.icon(for: volume.kind, size: 48))
        icon.hideFromAccessibility()   // the tile reads the drive name
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: volume.name)
        name.font = Theme.bodyFont
        name.textColor = Theme.primaryText
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: Self.detailText(volume))
        detail.font = Theme.statusFont
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        bar.used = CapacityText.usedFraction(free: volume.free, total: volume.total)
        bar.isCritical = CapacityText.isNearlyFull(free: volume.free, total: volume.total)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let hasCapacity = (volume.total ?? 0) > 0 && volume.free != nil
        bar.isHidden = !hasCapacity
        let text = NSStackView(views: [name, bar, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(5, after: name)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 190),
            bar.heightAnchor.constraint(equalToConstant: 10),
        ])
        toolTip = Self.tooltip(volume)
        titleField = name
        setAccessibilityLabel(volume.name)
        setAccessibilityValue(Self.detailText(volume))
        setAccessibilityHelp(Self.tooltip(volume))
    }

    required init?(coder: NSCoder) { fatalError() }

    static func detailText(_ v: VolumeSummary) -> String {
        if let status = VolumeCatalog.statusOverride?(v) { return status }
        if let total = v.total, total > 0, let free = v.free { return CapacityText.freeOfTotal(free: free, total: total) }
        return v.kind.typeName
    }

    static func tooltip(_ v: VolumeSummary) -> String {
        var lines = [v.kind.typeName]
        if let fs = v.fileSystem, !fs.isEmpty { lines.append(L10n.format("File system: %@", "\(fs)")) }
        if let total = v.total, total > 0 {
            if let free = v.free { lines.append(L10n.format("Free space: %@", "\(CapacityText.size(free))")) }
            lines.append(L10n.format("Total size: %@", "\(CapacityText.size(total))"))
        }
        if v.isReadOnly { lines.append(L10n.tr("Read-only")) }
        lines.append(v.url.path)
        return lines.joined(separator: "\n")
    }
}

/// Explorer's capacity bar: accent fill on a neutral track, red when less than 10% is free.
final class CapacityBarView: NSView {
    var used: Double = 0 { didSet { needsDisplay = true } }
    var isCritical = false { didSet { needsDisplay = true } }

    static let track = Theme.dynamic(light: 0xE6E6E6, dark: 0x3C3C3C)
    static let critical = Theme.dynamic(light: 0xC42B1C, dark: 0xFF6B5C)

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 2
        fillRounded(bounds, radius: radius, Self.track)
        guard used > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(radius * 2, bounds.width * CGFloat(used)), height: bounds.height)
        fillRounded(fill, radius: radius, isCritical ? Self.critical : Theme.accent)
    }
}

final class ThisMacPage: NSViewController, LocationPageStatus, LocationPageSelection, TileGridDelegate {
    weak var host: LocationHost?
    let volumes: [VolumeSummary]
    private var grids: [(title: String, grid: TileGridView, volumes: [VolumeSummary], header: SectionHeaderView)] = []
    private var observers: [NSObjectProtocol] = []
    private var syncing = false

    init(host: LocationHost?, volumes: [VolumeSummary]) {
        self.host = host
        self.volumes = volumes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private var browser: BrowserWindowController? { view.window?.windowController as? BrowserWindowController }

    var shownCount: Int { grids.reduce(0) { $0 + $1.volumes.count } }

    var statusSummary: String {
        StatusText.explorerSummary(visible: shownCount, total: shownCount, query: "", selected: selectedItems)
    }

    var selectedItems: [FileItem] {
        for entry in grids where !entry.grid.selection.isEmpty {
            return entry.grid.selection.map { i in
                let v = entry.volumes[i]
                return FileItem(url: v.url, name: v.name, isFolder: true, typeDescription: v.kind.typeName)
            }
        }
        return []
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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 24, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let sections = VolumeSections.sections(volumes, hideEmpty: Prefs.hideEmptyDrives)
        for (index, section) in sections.enumerated() {
            let id = section.title == VolumeSections.networkLocations ? "network" : "drives"
            let header = SectionHeaderView(title: section.title, collapsed: Prefs.isHomeSectionCollapsed("thisMac." + id))
            let grid = TileGridView(sectionID: id)
            grid.tileSize = NSSize(width: 272, height: 72)
            grid.delegate = self
            grid.setAccessibilityLabel(section.title)
            grid.setTiles(section.volumes.map { DriveTileView($0) })
            grid.isHidden = header.isCollapsed
            header.onToggle = { [weak self, weak grid] collapsed in
                Prefs.setHomeSectionCollapsed("thisMac." + id, collapsed)
                grid?.isHidden = collapsed
                if collapsed { grid?.clearSelection(notify: false); self?.browser?.itemViewSelectionDidChange() }
            }
            stack.addArrangedSubview(header)
            stack.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            if index < sections.count - 1 { stack.setCustomSpacing(18, after: grid) }
            grids.append((section.title, grid, section.volumes, header))
        }
        if sections.isEmpty {
            let empty = NSTextField(labelWithString: L10n.tr("No drives are connected."))
            empty.font = Theme.bodyFont
            empty.textColor = Theme.secondaryText
            stack.addArrangedSubview(empty)
        }
        for (i, entry) in grids.enumerated() { entry.grid.nextKeyView = grids[(i + 1) % grids.count].grid }

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
        root.setAccessibilityLabel(L10n.tr("This Mac"))
        view = root
        observers.append(NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] note in
            if note.userInfo?["key"] as? String == HomePrefKeys.hideEmptyDrives { self?.host?.reloadLocation() }
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.firstResponder === view.window, let first = grids.first(where: { !$0.grid.isHidden })?.grid {
            view.window?.makeFirstResponder(first)
        }
    }

    // MARK: Selection

    func select(names: [String]) {
        let wanted = Set(names)
        for entry in grids {
            let hits = IndexSet(entry.volumes.indices.filter { wanted.contains(entry.volumes[$0].name) })
            if !hits.isEmpty {
                entry.grid.select(hits)
                view.window?.makeFirstResponder(entry.grid)
                return
            }
        }
    }

    var activeGrid: TileGridView? { grids.first { !$0.grid.selection.isEmpty }?.grid }

    /// The drive groups shown (Folder Options' click behaviors, ItemActionsEverywhere).
    var driveGrids: [(grid: TileGridView, volumes: [VolumeSummary])] { grids.map { ($0.grid, $0.volumes) } }

    func contextMenu(sender: NSView?) -> NSMenu? {
        guard let browser else { return nil }
        let surface: CommandSurface = selectedItems.isEmpty ? .backgroundContextMenu : .itemContextMenu
        let ctx = browser.context(surface: surface, sender: sender)
        return CommandDispatcher.shared.menu(for: surface == .itemContextMenu ? .itemContextMenu : .backgroundContextMenu, context: ctx)
    }

    // MARK: TileGridDelegate

    private func entry(_ grid: TileGridView) -> (title: String, grid: TileGridView, volumes: [VolumeSummary], header: SectionHeaderView)? {
        grids.first { $0.grid === grid }
    }

    func tileGrid(_ grid: TileGridView, open indexes: [Int], inNewTab: Bool) {
        guard let entry = entry(grid), let browser else { return }
        let items = indexes.map { FileItem(url: entry.volumes[$0].url, name: entry.volumes[$0].name, isFolder: true) }
        browser.open(items, inNewTab: inNewTab)
    }

    func tileGridSelectionChanged(_ grid: TileGridView) {
        guard !syncing else { return }
        if !grid.selection.isEmpty {
            syncing = true
            grids.filter { $0.grid !== grid }.forEach { $0.grid.clearSelection() }
            syncing = false
        }
        browser?.itemViewSelectionDidChange()
    }

    func tileGridMenu(_ grid: TileGridView) -> NSMenu? { contextMenu(sender: grid) }

    func tileGrid(_ grid: TileGridView, unhandledKey event: NSEvent) -> Bool { browser?.itemViewKey(event) ?? false }

    /// Dropping onto a drive copies into its root, like Explorer (the transfer engine decides copy vs move).
    func tileGrid(_ grid: TileGridView, dropFolderAt index: Int) -> URL? {
        guard let v = entry(grid)?.volumes[index], !v.isReadOnly else { return nil }
        return v.url
    }

    func tileGrid(_ grid: TileGridView, leaveToward direction: Int) -> Bool {
        let visible = grids.filter { !$0.grid.isHidden && !$0.volumes.isEmpty }
        guard let i = visible.firstIndex(where: { $0.grid === grid }), visible.indices.contains(i + direction) else { return false }
        let target = visible[i + direction].grid
        grid.clearSelection()
        target.select([direction > 0 ? 0 : target.tiles.count - 1])
        view.window?.makeFirstResponder(target)
        return true
    }

    var debugSummary: String {
        let text = grids.map { entry in
            "\(entry.title)\(entry.header.isCollapsed ? " (collapsed)" : ""): "
                + entry.volumes.map { "\($0.name) [\($0.kind.rawValue); \(DriveTileView.detailText($0))\(CapacityText.isNearlyFull(free: $0.free, total: $0.total) ? "; red" : "")]" }
                    .joined(separator: ", ")
        }.joined(separator: " | ")
        return "thismac: \(text)"
    }
}
