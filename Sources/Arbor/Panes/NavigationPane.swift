import AppKit
import ArborCore

protocol NavigationPaneDelegate: AnyObject {
    func navigationPaneNavigate(to location: Location)
    func navigationPaneOpenInNewTab(_ location: Location)
    func navigationPaneTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL)
    func navigationPaneMenu(for node: NavNode) -> NSMenu?
}

final class NavNode: NSObject {
    enum Kind { case place, separator, favorite, thisMac, volume, folder }
    let kind: Kind
    let title: String
    let location: Location?
    let isEjectable: Bool
    /// nil until expanded: the tree never pre-scans folders (spec §15.3).
    var children: [NavNode]?

    init(kind: Kind, title: String, location: Location?, isEjectable: Bool = false, children: [NavNode]? = nil) {
        self.kind = kind
        self.title = title
        self.location = location
        self.isEjectable = isEjectable
        self.children = children
    }

    var url: URL? { location?.folderURL }

    lazy var icon: NSImage? = { location.map { IconProvider.shared.icon(for: $0, size: 16) } }()

    /// The node as an item, for commands (Pin, Open in new tab, Eject…).
    var asItem: FileItem? {
        guard let url else { return nil }
        return FileItem(url: url, name: title, isFolder: true)
    }
}

final class NavOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    var middleClick: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? menuProvider?(row) : nil
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0 { middleClick?(row) } else { super.otherMouseDown(with: event) }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        InteractionHooks.dragHover.send((nil, nil))
        super.draggingExited(sender)
    }

    /// Explorer-style chevrons instead of disclosure triangles.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier, let button = view as? NSButton {
            let tint = Theme.secondaryText.resolved(for: effectiveAppearance)
            button.image = NSImage.tintedSymbol(userInterfaceLayoutDirection == .rightToLeft ? "chevron.left" : "chevron.right",
                                                size: 9, weight: .semibold, color: tint)
            button.alternateImage = NSImage.tintedSymbol("chevron.down", size: 9, weight: .semibold, color: tint)
        }
        return view
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += 4
        return frame
    }

    // Group separators are decoration: VoiceOver skips them.
    override func accessibilityChildren() -> [Any]? { super.accessibilityChildren()?.filter { !isSeparatorElement($0) } }

    private func isSeparatorElement(_ element: Any) -> Bool {
        var row = -1
        if let view = element as? NSView {
            row = self.row(for: view)
        } else if let object = element as? NSObject {
            // AppKit's row proxies only answer the attribute-based API.
            let getter = NSSelectorFromString("accessibilityAttributeValue:")
            if object.responds(to: getter),
               let index = object.perform(getter, with: "AXIndex")?.takeUnretainedValue() as? NSNumber { row = index.intValue }
        }
        return row >= 0 && row < numberOfRows && (item(atRow: row) as? NavNode)?.kind == .separator
    }
}

/// Explorer-style navigation pane (FE-007). Chevron expands, label navigates; folders read only on expand.
final class NavigationPaneController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: NavigationPaneDelegate?
    let outline = NavOutlineView()
    private var roots: [NavNode] = []
    private var suppressNavigation = false
    /// Drives under "This Mac" (from the This Mac feature; nil = mounted volumes as-is).
    static let volumeNodes = Provided<(() -> [NavNode])?>(
        "NavigationPaneController.volumeNodes", "The drives listed under This Mac in the tree.",
        signature: "() -> [NavNode]", default: nil)

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = Theme.navPaneBackground
        outline.rowHeight = Theme.treeRowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL] + ItemHooks.dropTypes)   // file promises (Mail), like the item views
        outline.setAccessibilityLabel(L10n.tr("Navigation pane"))
        outline.menuProvider = { [weak self] row in
            guard let self, let node = self.outline.item(atRow: row) as? NavNode, node.kind != .separator else { return nil }
            return self.delegate?.navigationPaneMenu(for: node)
        }
        outline.middleClick = { [weak self] row in
            guard let node = self?.outline.item(atRow: row) as? NavNode, let location = node.location else { return }
            self?.delegate?.navigationPaneOpenInNewTab(location)
        }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.navPaneBackground
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = ThemeBackgroundView(Theme.navPaneBackground)
        container.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        view = container
        rebuild()
    }

    func rebuild() {
        let fm = FileManager.default
        let favorites = QuickAccess.urls.filter { fm.fileExists(atPath: $0.path) }.map {
            NavNode(kind: .favorite, title: displayName(of: $0), location: .folder($0))
        }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let volumes = Self.volumeNodes.value?() ?? (fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return NavNode(kind: .volume, title: values?.volumeLocalizedName ?? displayName(of: url), location: .folder(url),
                           isEjectable: (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false))
        }
        let thisMac = NavNode(kind: .thisMac, title: L10n.tr("This Mac"), location: .thisMac, children: volumes)
        let wasExpanded = roots.first { $0.kind == .thisMac }.map { outline.isItemExpanded($0) } ?? true
        roots = [NavNode(kind: .place, title: L10n.tr("Home"), location: .home),
                 NavNode(kind: .place, title: L10n.tr("Gallery"), location: .gallery)]
            + NavigationPaneExtras.nodes(.afterGallery)
            + [NavNode(kind: .separator, title: "", location: nil)]
            + favorites
            + [NavNode(kind: .separator, title: "", location: nil),
               thisMac,
               NavNode(kind: .place, title: L10n.tr("Network"), location: .network)]
            + NavigationPaneExtras.nodes(.afterNetwork)
        roots = NavigationPaneHooks.roots(roots)
        suppressNavigation = true
        outline.reloadData()
        if wasExpanded { outline.expandItem(thisMac) }
        suppressNavigation = false
    }

    /// Keeps expansion, unlike `rebuild()`; the guard stops a selection moved by the reload from navigating the tab.
    func replaceChildren(ofRootAt location: Location, with children: [NavNode]) {
        guard let root = roots.first(where: { $0.location == location }) else { return }
        root.children = children
        suppressNavigation = true
        outline.reloadItem(root, reloadChildren: true)
        suppressNavigation = false
    }

    /// Redraws one top-level row after `change`; its children, expansion and the selection stay.
    func updateRoot(at location: Location, _ change: (NavNode) -> Void) {
        guard let root = roots.first(where: { $0.location == location }) else { return }
        change(root)
        outline.reloadItem(root, reloadChildren: false)
    }

    /// The first visible row's node that `predicate` accepts.
    func visibleNode(where predicate: (NavNode) -> Bool) -> NavNode? {
        (0..<outline.numberOfRows).lazy.compactMap { self.outline.item(atRow: $0) as? NavNode }.first(where: predicate)
    }

    private func loadChildren(_ node: NavNode) -> [NavNode] {
        if let children = node.children { return children }
        guard let url = node.url else { node.children = []; return [] }
        let folders = NavigationPaneHooks.children((try? DirectoryLister.subfolders(of: url, includeHidden: Prefs.showHidden)) ?? [])
        let children = folders.map { NavNode(kind: .folder, title: $0.name, location: .folder($0.url)) }
        node.children = children
        return children
    }

    /// Marks the current location's node if visible. The marker is the selection; focus is separate (spec §5.1).
    func reveal(_ location: Location) {
        NavigationPaneHooks.willReveal.send((self, location))
        let row = visibleNode { $0.location == location }.map { outline.row(forItem: $0) } ?? -1
        suppressNavigation = true
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        suppressNavigation = false
    }

    /// Titles of visible rows, for scripted checks.
    var debugRows: [String] {
        (0..<outline.numberOfRows).compactMap { r in
            guard let node = outline.item(atRow: r) as? NavNode else { return nil }
            if node.kind == .separator { return "—" }
            let indent = String(repeating: "  ", count: outline.level(forRow: r))
            return indent + node.title + (node.kind == .favorite ? " (pinned)" : "")
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? NavNode else { return roots.count }
        return loadChildren(node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? NavNode else { return roots[index] }
        return loadChildren(node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? NavNode else { return false }
        switch node.kind {
        case .place, .separator: return false
        case .thisMac: return true
        case .favorite, .volume, .folder:
            // Unknown until expanded; empty folders lose the chevron after expanding.
            return node.children.map { !$0.isEmpty } ?? true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? NavNode)?.kind == .separator ? 13 : Theme.treeRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NavNode)?.kind != .separator
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ExplorerRowView()
        row.style = .navigation
        if (item as? NavNode)?.kind == .separator { row.setAccessibilityElement(false) }   // decoration only
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NavNode else { return nil }
        if node.kind == .separator {
            let id = NSUserInterfaceItemIdentifier("Separator")
            if let reused = outlineView.makeView(withIdentifier: id, owner: nil) { return reused }
            let line = NavSeparatorView()
            line.identifier = id
            return line
        }
        let id = NSUserInterfaceItemIdentifier("Node")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NavCellView ?? NavCellView()
        cell.identifier = id
        cell.textField?.stringValue = node.title
        cell.textField?.font = Theme.listFont
        cell.textField?.toolTip = node.url?.path ?? node.title
        cell.imageView?.image = node.icon
        cell.pin.isHidden = node.kind != .favorite
        cell.setAccessibilityLabel(node.kind == .favorite ? L10n.format("%@, pinned", "\(node.title)") : node.title)
        NavigationPaneHooks.decorateCell.send((cell, node))
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? NavNode else { return }
        NavigationPaneHooks.didExpand.send((self, node))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressNavigation, let node = outline.item(atRow: outline.selectedRow) as? NavNode,
              let location = node.location else { return }
        delegate?.navigationPaneNavigate(to: location)
    }

    // MARK: Drop onto a folder in the tree (FE-107)

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let node = index == NSOutlineViewDropOnItemIndex ? item as? NavNode : nil   // spring-loaded expansion (FE-108)
        InteractionHooks.dragHover.send((node?.url.map { "tree:" + $0.path }, node.map { node in
            { [weak outlineView] in outlineView?.expandItem(node) }
        }))
        guard let url = node?.url else { return [] }
        return DropPolicy.operation(info, onto: url)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        InteractionHooks.dragHover.send((nil, nil))
        guard let url = (item as? NavNode)?.url else { return false }
        return DropPolicy.accept(info, onto: url, window: outlineView.window) { kind, urls, folder in
            delegate?.navigationPaneTransfer(kind, urls, to: folder)
        }
    }
}

final class NavCellView: NSTableCellView {
    let pin = NSImageView()

    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = Theme.bodyFont
        label.textColor = Theme.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: L10n.tr("Pinned"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        pin.contentTintColor = Theme.secondaryText
        pin.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(pin)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -4),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class NavSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        NSRect(x: 12, y: floor(bounds.midY), width: max(0, bounds.width - 24), height: 1).fill(using: .sourceOver)
    }
}
