import AppKit
import ArborCore

/// Something a context menu can tell apart by section ("quickAccess", "recent", "drives"…).
/// Pages pass the clicked grid or list as the command context's `sender`.
protocol SectionTagged: AnyObject {
    var sectionID: String { get }
}

protocol TileGridDelegate: AnyObject {
    func tileGrid(_ grid: TileGridView, open indexes: [Int], inNewTab: Bool)
    func tileGridSelectionChanged(_ grid: TileGridView)
    func tileGridMenu(_ grid: TileGridView) -> NSMenu?
    /// Keys the grid doesn't use itself (window commands: Back, F5, Space…). Return true if handled.
    func tileGrid(_ grid: TileGridView, unhandledKey event: NSEvent) -> Bool
    /// The file URL dragged out for a tile (nil: the tile can't be dragged).
    func tileGrid(_ grid: TileGridView, dragURLAt index: Int) -> URL?
    /// The folder a drop onto a tile goes into (nil: not a drop target).
    func tileGrid(_ grid: TileGridView, dropFolderAt index: Int) -> URL?
    /// Drop on the grid's background (Quick access: pin folders). Return the operation, or [] to refuse.
    func tileGrid(_ grid: TileGridView, validateBackgroundDrop urls: [URL]) -> NSDragOperation
    func tileGrid(_ grid: TileGridView, acceptBackgroundDrop urls: [URL]) -> Bool
    /// Moves arrow-key focus out of the grid (to the next or previous section). Return true if it moved.
    func tileGrid(_ grid: TileGridView, leaveToward direction: Int) -> Bool
}

extension TileGridDelegate {
    func tileGrid(_ grid: TileGridView, dragURLAt index: Int) -> URL? { nil }
    func tileGrid(_ grid: TileGridView, dropFolderAt index: Int) -> URL? { nil }
    func tileGrid(_ grid: TileGridView, validateBackgroundDrop urls: [URL]) -> NSDragOperation { [] }
    func tileGrid(_ grid: TileGridView, acceptBackgroundDrop urls: [URL]) -> Bool { false }
    func tileGrid(_ grid: TileGridView, leaveToward direction: Int) -> Bool { false }
}

/// One tile. Subclasses add their content as subviews; the tile paints hover, selection, focus
/// and drop highlight behind it (Explorer's rounded 4 px item backplate).
class TileView: NSView {
    fileprivate(set) var index = 0
    fileprivate weak var grid: TileGridView?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; setAccessibilitySelected(isSelected) } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var showsFocus = false { didSet { if showsFocus != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    /// The tile's name label (Folder Options underlines it when items open with a single click).
    weak var titleField: NSTextField?

    /// Folder Options › "Show pop-up description for folder and desktop items" (set by that feature).
    static let showsDescriptions = Provided<() -> Bool>(
        "TileView.showsDescriptions", "Whether page tiles show pop-up descriptions.", signature: "() -> Bool", default: { true })
    private var storedTip: String?
    /// The tile's pop-up description; shown only while descriptions are turned on.
    override var toolTip: String? {
        get { super.toolTip }
        set { storedTip = newValue; super.toolTip = Self.showsDescriptions.value() ? newValue : nil }
    }
    /// Re-applies the description after the preference changed.
    func refreshToolTip() { super.toolTip = Self.showsDescriptions.value() ? storedTip : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Labels and images inside don't take clicks; the tile does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil   // `point` is in the superview's coordinates
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let active = grid?.isActive ?? false
        if isDropTarget {
            fillRounded(rect, radius: Theme.cornerRadius, Theme.selection)
        } else if isSelected {
            fillRounded(rect, radius: Theme.cornerRadius,
                        active ? (isHovered ? Theme.selectionHover : Theme.selection) : Theme.selectionInactive)
        } else if isHovered {
            fillRounded(rect, radius: Theme.cornerRadius, Theme.hover)
        }
        if showsFocus, active {
            // Keyboard focus is drawn apart from selection (spec §16.2).
            Theme.primaryText.withAlphaComponent(0.75).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { grid?.tileMouseDown(self, event: event) }
    override func mouseDragged(with event: NSEvent) { grid?.tileMouseDragged(self, event: event) }
    override func mouseUp(with event: NSEvent) { grid?.tileMouseUp(self, event: event) }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { grid?.openTile(index, inNewTab: true) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.menuForTile(self) }

    override func accessibilityPerformPress() -> Bool { grid?.openTile(index, inNewTab: false); return true }
}

/// A wrapping grid of tiles with Explorer selection rules: click selects, ⌘-click toggles,
/// ⇧-click extends, double-click or Return opens (⌘Return in a new tab), middle-click opens in a
/// new tab, arrows move, right-click selects then shows the menu. Tiles can be dragged out and
/// can accept drops.
final class TileGridView: NSView, SectionTagged, NSDraggingSource {
    weak var delegate: TileGridDelegate?
    let sectionID: String
    var tileSize = NSSize(width: 252, height: 64) { didSet { needsLayout = true } }
    var spacing: CGFloat = 4 { didSet { needsLayout = true } }

    private(set) var tiles: [TileView] = []
    private(set) var selection = IndexSet()
    private var anchor: Int?
    private(set) var focusIndex: Int?
    private var heightConstraint: NSLayoutConstraint!
    private var columns = 1
    private var mouseDownPoint: NSPoint?
    private var mouseDownHandled = false
    private weak var dropTile: TileView?

    init(sectionID: String) {
        self.sectionID = sectionID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The grid has keyboard focus in the key window (selection is drawn in the accent tint).
    var isActive: Bool { SelectionEmphasis.hasFocus(self) }
    private lazy var emphasisObserver = SelectionEmphasis.Observer { [weak self] in self?.tiles.forEach { $0.needsDisplay = true } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        emphasisObserver.attach(to: window)
    }

    override func becomeFirstResponder() -> Bool { tiles.forEach { $0.needsDisplay = true }; return true }
    override func resignFirstResponder() -> Bool {
        tiles.forEach { $0.needsDisplay = true; $0.showsFocus = false }
        return true
    }

    // MARK: Content

    func setTiles(_ newTiles: [TileView], keepSelection: IndexSet = []) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = newTiles
        for (i, tile) in tiles.enumerated() {
            tile.index = i
            tile.grid = self
            addSubview(tile)
        }
        setAccessibilityChildren(tiles)
        selection = keepSelection.filteredIndexSet { $0 < tiles.count }
        focusIndex = selection.first
        anchor = selection.first
        syncTiles()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        columns = max(1, Int((width + spacing) / (tileSize.width + spacing)))
        for (i, tile) in tiles.enumerated() {
            let row = i / columns, column = i % columns
            tile.frame = NSRect(x: CGFloat(column) * (tileSize.width + spacing), y: CGFloat(row) * (tileSize.height + spacing),
                                width: tileSize.width, height: tileSize.height)
        }
        let rows = tiles.isEmpty ? 0 : (tiles.count + columns - 1) / columns
        let height = rows == 0 ? 0 : CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * spacing
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }

    // MARK: Selection

    func select(_ indexes: IndexSet, notify: Bool = true) {
        let clean = indexes.filteredIndexSet { $0 < tiles.count }
        guard clean != selection else { return }
        selection = clean
        if let first = clean.first, focusIndex.map({ !clean.contains($0) }) ?? true { focusIndex = first }
        if anchor == nil || !clean.contains(anchor ?? -1) { anchor = clean.first }
        syncTiles()
        if notify { delegate?.tileGridSelectionChanged(self) }
    }

    func clearSelection(notify: Bool = false) { select([], notify: notify) }

    private func syncTiles() {
        for tile in tiles { tile.isSelected = selection.contains(tile.index) }
    }

    /// Takes keyboard focus; with `selecting`, also selects the first (or last) tile if none is.
    func takeFocus(selecting: Bool, fromEnd: Bool = false) {
        guard !tiles.isEmpty else { return }
        if selecting, selection.isEmpty { moveTo(fromEnd ? tiles.count - 1 : 0, extend: false) }
        window?.makeFirstResponder(self)
    }

    // MARK: Mouse

    fileprivate func tileMouseDown(_ tile: TileView, event: NSEvent) {
        window?.makeFirstResponder(self)
        tiles.forEach { $0.showsFocus = false }
        mouseDownPoint = event.locationInWindow
        mouseDownHandled = false
        let i = tile.index
        let mods = event.modifierFlags
        if event.clickCount >= 2 {
            openTile(i, inNewTab: mods.contains(.command))
            mouseDownHandled = true
            return
        }
        if mods.contains(.command) {
            var s = selection
            if s.contains(i) { s.remove(i) } else { s.insert(i) }
            focusIndex = i
            anchor = i
            select(s)
            mouseDownHandled = true
        } else if mods.contains(.shift), let a = anchor {
            focusIndex = i
            select(IndexSet(integersIn: min(a, i)...max(a, i)))
            mouseDownHandled = true
        } else if !selection.contains(i) {
            focusIndex = i
            anchor = i
            select([i])
            mouseDownHandled = true
        }
    }

    fileprivate func tileMouseUp(_ tile: TileView, event: NSEvent) {
        // Clicking an already-selected tile (without dragging) narrows the selection to it.
        if !mouseDownHandled, event.clickCount == 1 {
            focusIndex = tile.index
            anchor = tile.index
            select([tile.index])
        }
        mouseDownPoint = nil
    }

    fileprivate func tileMouseDragged(_ tile: TileView, event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        mouseDownHandled = true
        let indexes = selection.contains(tile.index) ? Array(selection) : [tile.index]
        let items: [NSDraggingItem] = indexes.compactMap { i in
            guard let url = delegate?.tileGrid(self, dragURLAt: i) else { return nil }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let t = tiles[i]
            let image = NSImage(size: t.bounds.size, flipped: false) { _ in
                if let rep = t.bitmapImageRepForCachingDisplay(in: t.bounds) {
                    t.cacheDisplay(in: t.bounds, to: rep)
                    rep.draw(in: NSRect(origin: .zero, size: t.bounds.size), from: .zero, operation: .sourceOver, fraction: 0.75,
                             respectFlipped: true, hints: nil)
                }
                return true
            }
            item.setDraggingFrame(t.frame, contents: image)
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .move] : [.copy, .move, .link, .generic]
    }

    override func mouseDown(with event: NSEvent) {
        // Background click clears the selection.
        window?.makeFirstResponder(self)
        clearSelection(notify: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        clearSelection(notify: true)
        return delegate?.tileGridMenu(self)
    }

    fileprivate func menuForTile(_ tile: TileView) -> NSMenu? {
        window?.makeFirstResponder(self)
        if !selection.contains(tile.index) {
            focusIndex = tile.index
            anchor = tile.index
            select([tile.index])
        }
        return delegate?.tileGridMenu(self)
    }

    fileprivate func openTile(_ index: Int, inNewTab: Bool) {
        guard index < tiles.count else { return }
        if !selection.contains(index) { select([index]) }
        delegate?.tileGrid(self, open: Array(selection), inNewTab: inNewTab)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let extend = mods.contains(.shift)
        switch event.keyCode {
        case 123: move(by: -1, extend: extend, event: event)            // ←
        case 124: move(by: 1, extend: extend, event: event)             // →
        case 126: move(by: -columns, extend: extend, event: event)      // ↑
        case 125: move(by: columns, extend: extend, event: event)       // ↓
        case 115: moveTo(0, extend: extend)                             // Home
        case 119: moveTo(tiles.count - 1, extend: extend)               // End
        case 36, 76:                                                    // Return / Enter
            guard !selection.isEmpty, mods.isEmpty || mods == .command else { break }
            delegate?.tileGrid(self, open: Array(selection), inNewTab: mods == .command)
        case 49 where mods == .control:                                 // ⌃Space toggles the focused tile
            if let f = focusIndex { var s = selection; if s.contains(f) { s.remove(f) } else { s.insert(f) }; select(s) }
        default:
            if delegate?.tileGrid(self, unhandledKey: event) != true { super.keyDown(with: event) }
        }
    }

    private func move(by step: Int, extend: Bool, event: NSEvent) {
        guard !tiles.isEmpty else { return }
        // Nothing focused yet: the first arrow press lands on the first tile.
        guard let current = focusIndex else { moveTo(0, extend: false); return }
        let target = current + step
        if target < 0 || target >= tiles.count {
            // Up from the first row or down from the last row moves to the neighboring section.
            if abs(step) == columns, delegate?.tileGrid(self, leaveToward: step > 0 ? 1 : -1) == true { return }
            if abs(step) == 1 || target < 0 { return }
            moveTo(tiles.count - 1, extend: extend)
            return
        }
        moveTo(target, extend: extend)
    }

    private func moveTo(_ index: Int, extend: Bool) {
        guard tiles.indices.contains(index) else { return }
        tiles.forEach { $0.showsFocus = false }
        focusIndex = index
        if extend, let a = anchor {
            select(IndexSet(integersIn: min(a, index)...max(a, index)))
            focusIndex = index
        } else {
            anchor = index
            select([index])
        }
        tiles[index].showsFocus = true
        tiles[index].scrollToVisible(tiles[index].bounds.insetBy(dx: 0, dy: -8))
    }

    override func selectAll(_ sender: Any?) { select(IndexSet(integersIn: 0..<tiles.count)) }

    // MARK: Drop

    private func tile(at windowPoint: NSPoint) -> TileView? {
        let p = convert(windowPoint, from: nil)
        return tiles.first { $0.frame.contains(p) }
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = DropPolicy.fileURLs(from: info)
        let target = tile(at: info.draggingLocation)
        if dropTile !== target { dropTile?.isDropTarget = false; dropTile = nil }
        if let target, let folder = delegate?.tileGrid(self, dropFolderAt: target.index) {
            guard let kind = DropPolicy.kind(sources: urls, destination: folder, mask: info.draggingSourceOperationMask) else { return [] }
            target.isDropTarget = true
            dropTile = target
            return kind == .move ? .move : .copy
        }
        return delegate?.tileGrid(self, validateBackgroundDrop: urls) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropTile?.isDropTarget = false; dropTile = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropPolicy.fileURLs(from: sender)
        defer { dropTile?.isDropTarget = false; dropTile = nil }
        if let target = tile(at: sender.draggingLocation), let folder = delegate?.tileGrid(self, dropFolderAt: target.index) {
            guard let kind = DropPolicy.kind(sources: urls, destination: folder, mask: sender.draggingSourceOperationMask),
                  let window = window?.windowController as? BrowserWindowController else { return false }
            window.startTransfer(kind, urls, to: folder)
            return true
        }
        return delegate?.tileGrid(self, acceptBackgroundDrop: urls) ?? false
    }
}

/// Explorer's collapsible section header: chevron, title, and a hairline to the right.
final class SectionHeaderView: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isCollapsed: Bool
    private let chevron = NSImageView()
    private let label: NSTextField
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String, collapsed: Bool) {
        isCollapsed = collapsed
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = Theme.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
        updateChevron()
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String { label.stringValue }

    private func updateChevron() {
        let tint = Theme.secondaryText.resolved(for: effectiveAppearance)
        chevron.image = NSImage.tintedSymbol(isCollapsed ? "chevron.right" : "chevron.down", size: 10, weight: .semibold, color: tint)
        setAccessibilityValue(isCollapsed ? 0 : 1)
        setAccessibilityExpanded(!isCollapsed)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChevron()
    }

    func setCollapsed(_ collapsed: Bool, notify: Bool) {
        isCollapsed = collapsed
        updateChevron()
        if notify { onToggle?(collapsed) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let textEnd = label.frame.maxX
        if hovered { fillRounded(NSRect(x: 0, y: 2, width: textEnd + 10, height: bounds.height - 4), radius: Theme.cornerRadius, Theme.hover) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { setCollapsed(!isCollapsed, notify: true) }
    }
    override func accessibilityPerformPress() -> Bool { setCollapsed(!isCollapsed, notify: true); return true }
}
