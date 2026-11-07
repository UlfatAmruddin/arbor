import AppKit
import ArborCore

/// Gallery (FE-075): photos and videos from the collection's folders, newest first, grouped under
/// month headers, in justified rows without file names, with a date rail on the right.
/// Every tile is a real file: selection feeds the window's commands (Open, Copy, Delete via Trash,
/// Share, Quick Look, Open file location) through `LocationPageSelection`.
final class GalleryPageController: NSViewController, LocationPageStatus, LocationPageSelection {
    weak var host: LocationHost?
    let grid = GalleryGridView()
    private let scroll = NSScrollView()
    let rail = GalleryDateRail()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var observers: [NSObjectProtocol] = []
    private var pendingReload: DispatchWorkItem?
    private var attached = false
    private var showsPartialCoverage = false

    init(host: LocationHost?) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if attached { GalleryStore.shared.detach(self) }
    }

    var window: BrowserWindowController? { host as? BrowserWindowController }

    // MARK: LocationPageSelection / status

    var selectedItems: [FileItem] { grid.selectedItems.map(Self.fileItem) }

    var statusSummary: String {
        let store = GalleryStore.shared
        var text = StatusText.explorerSummary(visible: grid.itemCount, total: grid.itemCount, query: "", selected: selectedItems)
        if store.isScanning { text += "  Looking for photos and videos…" }
        return text
    }

    static func fileItem(_ item: GalleryItem) -> FileItem {
        FileItem(url: item.url, name: item.url.lastPathComponent, isFolder: false, size: item.size, modified: item.modified,
                 typeDescription: item.kind == .video ? "Video" : "Image")
    }

    // MARK: View

    override func loadView() {
        let root = GalleryRootView(Theme.contentBackground)
        root.onWindowChange = { [weak self] inWindow in self?.setAttached(inWindow) }
        scroll.documentView = grid
        scroll.hasVerticalScroller = false   // the date rail is the scroller
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.contentBackground
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        grid.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        grid.autoresizingMask = [.width]
        grid.page = self

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.onScrub = { [weak self] y in self?.scrollGrid(toDocumentY: y) }

        emptyLabel.font = Theme.bodyFont
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(rail)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rail.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            rail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rail.widthAnchor.constraint(equalToConstant: GalleryDateRail.width),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 64),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        root.setAccessibilityLabel("Gallery")
        view = root

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: GalleryStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReload()
        })
        observers.append(nc.addObserver(forName: GalleryPrefs.changed, object: nil, queue: .main) { [weak self] note in
            if note.userInfo?["size"] != nil { self?.grid.rowHeight = GalleryPrefs.rowHeight(GalleryPrefs.size) }
            self?.scheduleReload()
        })
        observers.append(nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            self?.grid.needsDisplay = true
        })
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.scrolled()
        })
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.grid.relayout()
            self?.scrolled()
        })
        scroll.contentView.postsFrameChangedNotifications = true
        grid.rowHeight = GalleryPrefs.rowHeight(GalleryPrefs.size)
        reloadNow()
    }

    private func setAttached(_ inWindow: Bool) {
        guard inWindow != attached else { return }
        attached = inWindow
        if inWindow {
            GalleryStore.shared.attach(self)
            reloadNow()
            DispatchQueue.main.async { [weak self] in self?.grid.window?.makeFirstResponder(self?.grid) }
        } else {
            GalleryStore.shared.detach(self)
            grid.cancelThumbnails()
        }
    }

    /// Reloads (Refresh / after Trash): rescans and keeps the scroll position and selection.
    func refresh() {
        GalleryStore.shared.refresh()
        reloadNow()
    }

    private func scheduleReload() {
        guard pendingReload == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReload = nil
            self?.reloadNow()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (GalleryStore.shared.isScanning ? 0.35 : 0.05), execute: work)
    }

    func reloadNow() {
        guard isViewLoaded else { return }
        let store = GalleryStore.shared
        let months = GalleryTimeline.months(store.items, newestFirst: GalleryPrefs.newestFirst)
        grid.setSections(months)
        if let wanted = pendingSelection, grid.allItems.contains(where: { $0.key == wanted }) {
            pendingSelection = nil
            grid.select(keys: [wanted])
        }
        rail.update(entries: grid.railEntries, documentHeight: grid.frame.height)
        scrolled()
        let collection = GalleryPrefs.collection
        if months.isEmpty {
            if collection.sources.isEmpty {
                emptyLabel.stringValue = "Your collection doesn't include any folders. Use Collection ▾ › Manage collection to add one."
            } else if !collection.sources.contains(where: \.included) {
                emptyLabel.stringValue = "Every folder in the collection is turned off. Turn one on in Collection ▾."
            } else if store.isScanning {
                emptyLabel.stringValue = "Looking for photos and videos…"
            } else {
                emptyLabel.stringValue = "No photos or videos were found in the collection's folders."
            }
        }
        emptyLabel.isHidden = !months.isEmpty
        rail.isHidden = months.isEmpty
        if !store.unavailable.isEmpty, !store.isScanning {
            let names = store.unavailable.map { "“\($0.path)”" }.joined(separator: ", ")
            host?.showStatusMessage("Some folders in the collection aren't available, so Gallery may be incomplete: \(names)", isError: true)
            showsPartialCoverage = true
        } else if store.unavailable.isEmpty, showsPartialCoverage {
            host?.showStatusMessage(nil, isError: false)
            showsPartialCoverage = false
        }
        window?.updateChrome()
    }

    private func scrolled() {
        let visible = scroll.contentView.bounds
        rail.setViewport(top: visible.minY, height: visible.height, documentHeight: grid.frame.height)
        grid.updateThumbnailRequests()
    }

    func scrollGrid(toDocumentY y: CGFloat) {
        let maxY = max(0, grid.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func selectionChanged() { window?.itemViewSelectionDidChange() }

    // MARK: Actions from the grid

    func open(_ items: [GalleryItem]) {
        guard !items.isEmpty else { return }
        window?.open(items.map(Self.fileItem), inNewTab: false)
    }

    func contextMenu() -> NSMenu? { window?.itemViewContextMenu() }

    func handleKey(_ event: NSEvent) -> Bool { window?.itemViewKey(event) ?? false }

    private var pendingSelection: String?

    /// Selects the item at `url` as soon as a scan has found it (after a rename).
    func selectAfterReload(_ url: URL) { pendingSelection = Location.normalizedKey(url) }

    /// Debug/test: select items by file name.
    func select(names: [String]) {
        grid.select(keys: Set(grid.allItems.filter { names.contains($0.url.lastPathComponent) }.map(\.key)))
    }
}

/// Reports when the page enters or leaves a window (start/stop scanning).
final class GalleryRootView: ThemeBackgroundView {
    var onWindowChange: ((Bool) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }
}

// MARK: - Grid

/// The justified thumbnail grid. Only visible tiles are drawn and only tiles near the viewport
/// request thumbnails; requests for tiles that scroll away are cancelled.
final class GalleryGridView: NSView, NSDraggingSource {
    weak var page: GalleryPageController?
    var rowHeight: CGFloat = 184 { didSet { if rowHeight != oldValue { relayout() } } }

    static let sideInset: CGFloat = 20
    static let spacing: CGFloat = 4
    static let headerHeight: CGFloat = 46

    struct Tile {
        let item: GalleryItem
        let rect: NSRect
        let row: Int
    }

    private(set) var sections: [GalleryMonth] = []
    private(set) var tiles: [Tile] = []
    private var headers: [(title: String, rect: NSRect)] = []
    private var rows: [[Int]] = []
    private var layoutWidth: CGFloat = 0
    private(set) var selection = Set<String>()
    private var anchor: Int?
    private var focusIndex: Int?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    /// Thumbnails come from the app-wide `ThumbnailService` budget (shared with the icon views).
    private lazy var loader: ThumbnailLoader = {
        let loader = ThumbnailLoader()
        loader.onLoaded = { [weak self] _ in self?.needsDisplay = true }
        return loader
    }()
    private var mouseDownIndex: Int?
    private var mouseDownPoint: NSPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var itemCount: Int { tiles.count }
    var allItems: [GalleryItem] { tiles.map(\.item) }
    var selectedItems: [GalleryItem] { tiles.filter { selection.contains($0.item.key) }.map(\.item) }

    var railEntries: [GalleryDateRail.Entry] {
        var entries: [GalleryDateRail.Entry] = []
        var lastYear: Int?
        for (index, section) in sections.enumerated() where index < headers.count {
            entries.append(.init(title: section.title, year: section.year, isYearStart: section.year != lastYear,
                                 y: headers[index].rect.minY))
            lastYear = section.year
        }
        return entries
    }

    func setSections(_ months: [GalleryMonth]) {
        sections = months
        let keys = Set(months.flatMap(\.items).map(\.key))
        let before = selection
        selection = selection.intersection(keys)
        relayout()
        if before != selection { page?.selectionChanged() }
    }

    func relayout() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = clip.bounds.width
        layoutWidth = width
        let usable = Double(max(100, width - Self.sideInset - GalleryDateRail.width))
        var y: CGFloat = 6
        var newTiles: [Tile] = []
        var newHeaders: [(String, NSRect)] = []
        var newRows: [[Int]] = []
        for section in sections {
            newHeaders.append((section.title, NSRect(x: Self.sideInset, y: y, width: CGFloat(usable), height: Self.headerHeight)))
            y += Self.headerHeight
            let rowsInSection = JustifiedLayout.rows(aspects: section.items.map(\.aspect), width: usable,
                                                     targetHeight: Double(rowHeight), spacing: Double(Self.spacing))
            for row in rowsInSection {
                var indexes: [Int] = []
                for (n, i) in row.indexes.enumerated() {
                    let frame = row.frames[n]
                    indexes.append(newTiles.count)
                    newTiles.append(Tile(item: section.items[i],
                                         rect: NSRect(x: Self.sideInset + CGFloat(frame.x), y: y, width: CGFloat(frame.width), height: CGFloat(row.height)).integral,
                                         row: newRows.count))
                }
                newRows.append(indexes)
                y += CGFloat(row.height) + Self.spacing
            }
            y += 14
        }
        tiles = newTiles
        headers = newHeaders
        rows = newRows
        if let focus = focusIndex, focus >= tiles.count { focusIndex = nil }
        let height = max(y + 20, clip.bounds.height)
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
        if let page { page.view.needsLayout = true }
        updateThumbnailRequests()
    }

    // MARK: Drawing

    private static let placeholder = Theme.dynamic(light: 0xEDEDED, dark: 0x2C2C2C)
    private static let headerFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.fill()
        for header in headers where header.rect.intersects(dirtyRect) {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.headerFont, .foregroundColor: Theme.primaryText]
            let text = NSAttributedString(string: header.title, attributes: attrs)
            let size = text.size()
            text.draw(at: NSPoint(x: header.rect.minX + 2, y: header.rect.maxY - size.height - 10))
        }
        let scale = window?.backingScaleFactor ?? 2
        let checkboxes = Prefs.itemCheckBoxes
        for (index, tile) in tiles.enumerated() where tile.rect.intersects(dirtyRect) {
            let rect = tile.rect
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if let hit = ThumbnailService.shared.image(for: thumbnailKey(tile, scale: scale)) {
                drawAspectFill(NSImage(cgImage: hit.image, size: NSSize(width: hit.image.width, height: hit.image.height)), in: rect)
            } else {
                Self.placeholder.setFill()
                rect.fill()
                if let glyph = NSImage.tintedSymbol(tile.item.kind == .video ? "film" : "photo", size: min(28, rect.height / 3),
                                                    color: Theme.secondaryText.withAlphaComponent(0.5)) {
                    let s = glyph.size
                    glyph.drawFlippedAware(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
                }
            }
            let selected = selection.contains(tile.item.key)
            if index == hoverIndex, !selected {
                NSColor(white: 1, alpha: 0.12).setFill()
                rect.fill(using: .sourceOver)
            }
            NSGraphicsContext.restoreGraphicsState()
            if tile.item.kind == .video { drawVideoBadge(in: rect) }
            if selected {
                Theme.accent.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                ring.lineWidth = 2
                ring.stroke()
                let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 2.5, yRadius: 2.5)
                inner.lineWidth = 1
                Theme.contentBackground.setStroke()
                inner.stroke()
            }
            if selected || index == hoverIndex || checkboxes { drawCheckbox(in: rect, checked: selected) }
            if index == focusIndex, window?.firstResponder === self, !selected {
                Theme.primaryText.withAlphaComponent(0.6).setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                ring.lineWidth = 1
                ring.setLineDash([2, 2], count: 2, phase: 0)
                ring.stroke()
            }
        }
    }

    private func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = rect.width / scale, h = rect.height / scale
        let source = NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let box = NSRect(x: rect.maxX - 26, y: rect.minY + 8, width: 18, height: 18)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        if checked {
            Theme.accent.setFill()
            path.fill()
            if let check = NSImage.tintedSymbol("checkmark", size: 10, weight: .bold, color: .white) {
                let s = check.size
                check.drawFlippedAware(in: NSRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height))
            }
        } else {
            NSColor(white: 0, alpha: 0.28).setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    private func drawVideoBadge(in rect: NSRect) {
        guard rect.width > 40 else { return }
        let badge = NSRect(x: rect.minX + 8, y: rect.maxY - 30, width: 22, height: 22)
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(ovalIn: badge).fill()
        if let play = NSImage.tintedSymbol("play.fill", size: 10, color: .white) {
            let s = play.size
            play.drawFlippedAware(in: NSRect(x: badge.midX - s.width / 2 + 1, y: badge.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    // MARK: Thumbnails

    /// The cache key for a tile at its drawn size, rounded up to the shared pixel sizes.
    private func thumbnailKey(_ tile: Tile, scale: CGFloat) -> ThumbnailKey {
        let needed = Int(max(tile.rect.width, tile.rect.height) * scale)
        let pixels = ThumbnailService.knownPixelSizes.first { $0 >= needed } ?? ThumbnailService.knownPixelSizes.last ?? 512
        return ThumbnailKey(item: GalleryPageController.fileItem(tile.item), pixels: pixels)
    }

    /// Requests thumbnails for tiles on screen plus one screen of buffer; cancels the rest.
    func updateThumbnailRequests() {
        guard window != nil, !tiles.isEmpty else { return }
        let margin = visibleRect.height
        let wanted = visibleRect.insetBy(dx: 0, dy: -margin)
        let scale = window?.backingScaleFactor ?? 2
        // Tiles nearest the middle of the viewport first, so the visible ones are requested first.
        let near = tiles.filter { $0.rect.intersects(wanted) }
            .sorted { abs($0.rect.midY - visibleRect.midY) < abs($1.rect.midY - visibleRect.midY) }
        loader.update(wanted: near.map { tile in
            let key = thumbnailKey(tile, scale: scale)
            return (GalleryPageController.fileItem(tile.item), key, CGFloat(key.pixels) / scale, scale)
        })
    }

    /// Stops every request (the page left the window).
    func cancelThumbnails() { loader.reset() }

    // MARK: Selection

    private func index(at point: NSPoint) -> Int? {
        tiles.firstIndex { $0.rect.contains(point) }
    }

    func select(keys: Set<String>) {
        selection = keys
        anchor = tiles.firstIndex { keys.contains($0.item.key) }
        focusIndex = anchor
        needsDisplay = true
        page?.selectionChanged()
    }

    func selectAll() { select(keys: Set(tiles.map(\.item.key))) }

    private func click(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        let key = tiles[index].item.key
        if modifiers.contains(.shift), let anchor {
            let range = min(anchor, index)...max(anchor, index)
            var keys = modifiers.contains(.command) ? selection : []
            range.forEach { keys.insert(tiles[$0].item.key) }
            selection = keys
        } else if modifiers.contains(.command) {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
            anchor = index
        } else {
            selection = [key]
            anchor = index
        }
        focusIndex = index
        needsDisplay = true
        page?.selectionChanged()
    }

    private func move(to index: Int, extend: Bool) {
        guard tiles.indices.contains(index) else { NSSound.beep(); return }
        if extend, let anchor {
            selection = Set((min(anchor, index)...max(anchor, index)).map { tiles[$0].item.key })
        } else {
            selection = [tiles[index].item.key]
            anchor = index
        }
        focusIndex = index
        scrollToVisible(tiles[index].rect.insetBy(dx: 0, dy: -Self.headerHeight / 2))
        needsDisplay = true
        page?.selectionChanged()
    }

    /// The tile in the row above/below whose center is closest horizontally.
    private func vertical(from index: Int, by step: Int) -> Int? {
        let row = tiles[index].row + step
        guard rows.indices.contains(row) else { return nil }
        let x = tiles[index].rect.midX
        return rows[row].min { abs(tiles[$0].rect.midX - x) < abs(tiles[$1].rect.midX - x) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { hoverIndex = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownIndex = index(at: point)
        guard let hit = mouseDownIndex else {
            if !event.modifierFlags.contains(.command), !selection.isEmpty { select(keys: []) }
            return
        }
        // Clicking the check box toggles that item, like Explorer's item check boxes.
        let box = NSRect(x: tiles[hit].rect.maxX - 28, y: tiles[hit].rect.minY + 6, width: 22, height: 22)
        if box.contains(point) {
            click(hit, modifiers: [.command])
        } else if event.clickCount == 2 {
            page?.open(selectedItems.isEmpty ? [tiles[hit].item] : selectedItems)
        } else if !(selection.contains(tiles[hit].item.key) && event.modifierFlags.intersection([.command, .shift]).isEmpty) {
            click(hit, modifiers: event.modifierFlags)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A plain click on an already selected tile narrows the selection to it (unless it was a drag).
        if let hit = mouseDownIndex, event.clickCount == 1, event.modifierFlags.intersection([.command, .shift]).isEmpty,
           selection.count > 1, selection.contains(tiles[hit].item.key) {
            click(hit, modifiers: [])
        }
        mouseDownIndex = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let hit = mouseDownIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        mouseDownIndex = nil
        if !selection.contains(tiles[hit].item.key) { click(hit, modifiers: []) }
        let items = tiles.filter { selection.contains($0.item.key) }
        let dragging = items.map { tile -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: tile.item.url as NSURL)
            let image = ThumbnailService.shared.image(for: thumbnailKey(tile, scale: window?.backingScaleFactor ?? 2))
                .map { NSImage(cgImage: $0.image, size: tile.rect.size) } ?? NSWorkspace.shared.icon(forFile: tile.item.url.path)
            item.setDraggingFrame(tile.rect, contents: image)
            return item
        }
        beginDraggingSession(with: dragging, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link] : [.copy, .move]
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = index(at: point) {
            if !selection.contains(tiles[hit].item.key) { click(hit, modifiers: []) }
        } else if !selection.isEmpty {
            select(keys: [])
        }
        return page?.contextMenu()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let extend = event.modifierFlags.contains(.shift)
        let current = focusIndex ?? anchor ?? (tiles.isEmpty ? nil : -1)
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.keyCode {
        case 123 where plain: if let c = current { move(to: max(0, c - 1), extend: extend) }   // ←
        case 124 where plain: if let c = current { move(to: min(tiles.count - 1, c + 1), extend: extend) }   // →
        case 125 where plain:   // ↓
            if let c = current { move(to: c < 0 ? 0 : vertical(from: c, by: 1) ?? c, extend: extend) }
        case 126 where plain:   // ↑
            if let c = current, c >= 0 { move(to: vertical(from: c, by: -1) ?? c, extend: extend) }
        case 115: if !tiles.isEmpty { move(to: 0, extend: extend) }   // Home
        case 119: if !tiles.isEmpty { move(to: tiles.count - 1, extend: extend) }   // End
        case 36, 76: page?.open(selectedItems)   // Return / Enter
        case 53: if !selection.isEmpty { select(keys: []) }   // Esc
        default:
            if page?.handleKey(event) != true { super.keyDown(with: event) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "a" {
            selectAll()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Gallery, \(StatusText.items(tiles.count))" }
    override func isAccessibilityElement() -> Bool { true }
}

// MARK: - Date rail

/// The timeline on the right edge (Gallery's date scrollbar): years at their position in the
/// collection, a tick per month, the visible span, and a month bubble while hovering or dragging.
/// Click or drag to jump; it snaps to the month under the pointer.
final class GalleryDateRail: NSView {
    static let width: CGFloat = 58

    struct Entry {
        let title: String
        let year: Int
        let isYearStart: Bool
        /// Header position in the grid's document coordinates.
        let y: CGFloat
    }

    var onScrub: ((CGFloat) -> Void)?
    private var entries: [Entry] = []
    private var documentHeight: CGFloat = 1
    private var viewport: (top: CGFloat, height: CGFloat) = (0, 0)
    private var pointerY: CGFloat?
    private var dragging = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    func update(entries: [Entry], documentHeight: CGFloat) {
        self.entries = entries
        self.documentHeight = max(documentHeight, 1)
        needsDisplay = true
    }

    func setViewport(top: CGFloat, height: CGFloat, documentHeight: CGFloat) {
        viewport = (top, height)
        self.documentHeight = max(documentHeight, 1)
        needsDisplay = true
    }

    private var track: NSRect { bounds.insetBy(dx: 0, dy: 10) }

    private func railY(_ docY: CGFloat) -> CGFloat { track.minY + docY / documentHeight * track.height }
    private func docY(_ railY: CGFloat) -> CGFloat { (railY - track.minY) / max(track.height, 1) * documentHeight }

    /// The month section under a rail position.
    private func entry(atRailY y: CGFloat) -> Entry? {
        let target = docY(y)
        return entries.last { $0.y <= target + 1 } ?? entries.first
    }

    /// Visible year labels and month ticks (for the debug log).
    var debugSummary: String {
        "rail: " + entries.filter(\.isYearStart).map { "\($0.year)@\(Int(railY($0.y)))" }.joined(separator: " ")
            + " months=\(entries.count)"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty else { return }
        if pointerY != nil || dragging {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        // Visible span.
        let top = railY(viewport.top), bottom = railY(min(viewport.top + viewport.height, documentHeight))
        let span = NSRect(x: bounds.maxX - 6, y: top, width: 3, height: max(18, bottom - top))
        Theme.secondaryText.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: span, xRadius: 1.5, yRadius: 1.5).fill()

        // Month ticks, then year labels (skipping ones that would overlap).
        Theme.secondaryText.withAlphaComponent(0.35).setFill()
        for entry in entries {
            let y = railY(entry.y)
            NSRect(x: bounds.maxX - 14, y: y, width: 4, height: 1).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText]
        var lastLabel: CGFloat = -100
        for entry in entries where entry.isYearStart {
            let y = railY(entry.y)
            guard y - lastLabel >= 16 else { continue }
            let text = NSAttributedString(string: String(entry.year), attributes: attrs)
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.maxX - 18 - size.width, y: min(y, bounds.maxY - size.height) - 1))
            lastLabel = y
        }
        if let pointerY, let entry = entry(atRailY: pointerY) { drawBubble(entry.title, at: pointerY) }
    }

    private func drawBubble(_ title: String, at y: CGFloat) {
        // Drawn inside the rail's left part; the rail is wide enough for a short month label.
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.primaryText]
        let short = title.split(separator: " ").map { $0.prefix(3) }.joined(separator: " ")
        let text = NSAttributedString(string: short, attributes: attrs)
        let size = text.size()
        let box = NSRect(x: 2, y: min(max(y - 11, 0), bounds.maxY - 22), width: min(bounds.width - 4, size.width + 10), height: 22)
        Theme.fieldBackground.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        path.fill()
        Theme.fieldBorder.setStroke()
        path.stroke()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.midY - size.height / 2))
        toolTip = title
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        pointerY = convert(event.locationInWindow, from: nil).y
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if !dragging { pointerY = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        scrub(event)
    }

    override func mouseDragged(with event: NSEvent) { scrub(event) }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        pointerY = bounds.contains(convert(event.locationInWindow, from: nil)) ? pointerY : nil
        needsDisplay = true
    }

    private func scrub(_ event: NSEvent) {
        let y = min(max(convert(event.locationInWindow, from: nil).y, track.minY), track.maxY)
        pointerY = y
        if let entry = entry(atRailY: y) { onScrub?(entry.y) }
        needsDisplay = true
    }

    /// Jumps to the first month of a year (keyboard/accessibility and scripts).
    func jump(toYear year: Int) -> Bool {
        guard let entry = entries.first(where: { $0.year == year }) else { return false }
        onScrub?(entry.y)
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .scrollBar }
    override func accessibilityLabel() -> String? { "Timeline" }
}
