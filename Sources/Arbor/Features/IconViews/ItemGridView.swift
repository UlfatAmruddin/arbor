import AppKit
import ArborCore

/// What the grid reports to its view controller.
protocol ItemGridHost: AnyObject {
    func gridOpen(_ items: [FileItem], inNewTab: Bool)
    func gridSelectionChanged()
    func gridContextMenu() -> NSMenu?
    func gridTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL)
    /// Keys the grid doesn't handle (F2, Delete, Space for Quick Look, ⌥arrows…).
    func gridKey(_ event: NSEvent) -> Bool
    /// Slow second click on a selected item's name (Explorer starts rename).
    func gridBeginRename(at index: Int)
    var gridFolder: URL? { get }
    var gridAllowsEditing: Bool { get }
}

/// Paints the visible part of the grid. It is only as large as the visible area and follows scrolling,
/// so drawing memory stays bounded however many items the folder has (spec §15.3). Clicks pass
/// through to the grid.
final class ItemGridCanvas: NSView {
    weak var grid: ItemGridView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid else { return }
        NSGraphicsContext.saveGraphicsState()
        let shift = NSAffineTransform()
        shift.translateX(by: -frame.minX, yBy: -frame.minY)
        shift.concat()
        grid.drawContent(in: frame)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The document view behind the icon, List, Tiles and Content layouts (FE-029–FE-031). It keeps no
/// per-item views: geometry is arithmetic (`ItemFlowLayout`), drawing happens in one canvas sized to
/// the visible area, and thumbnails load only for what's on screen.
final class ItemGridView: NSView, NSDraggingSource, NSViewToolTipOwner {
    weak var host: ItemGridHost?
    let canvas = ItemGridCanvas()
    let thumbnails = ThumbnailLoader()

    private(set) var items: [FileItem] = []
    private(set) var mode: ViewMode = .largeIcons
    private(set) var metrics = IconLayoutMetrics(mode: .largeIcons, compact: false)
    private(set) var layout = IconLayoutMetrics(mode: .largeIcons, compact: false).makeLayout()
    var selection = ItemSelection()
    private(set) var hovered: Int?
    private var dropTarget: Int?
    private(set) var marqueeRect: CGRect?
    /// The item whose name is being edited (its label isn't drawn).
    var editingIndex: Int? { didSet { canvas.needsDisplay = true } }
    /// Draw the keyboard focus outline (after arrow keys, not after clicks).
    private(set) var showsFocus = false
    private var typeSelect = TypeSelect()
    /// Typed text reaches type-to-select through the input method (FE-068).
    private lazy var typeSelectText = TypeSelectInput(view: self) { [weak self] text in self?.typeSelectInput(text) }
    private var pendingScrollStart: Int?
    private var visibleWorkScheduled = false
    private var slowRename: DispatchWorkItem?
    private var windowObservers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    private var mouseDownEvent: NSEvent?

    let textCache = NSCache<NSString, NSString>()
    let heightCache = NSCache<NSString, NSNumber>()
    let widthCache = NSCache<NSString, NSNumber>()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        canvas.grid = self
        addSubview(canvas)
        registerForDraggedTypes([.fileURL] + ItemHooks.dropTypes)
        textCache.countLimit = 3000
        heightCache.countLimit = 6000
        widthCache.countLimit = 20000
        thumbnails.onLoaded = { [weak self] _ in
            self?.canvas.needsDisplay = true
            self?.scheduleVisibleWork()
        }
        setAccessibilityRole(.list)
        setAccessibilityLabel(L10n.tr("Items"))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        thumbnails.reset()
    }

    // MARK: Configuration

    var checkBoxes: Bool { Prefs.itemCheckBoxes }
    var iconsOnly: Bool { Prefs.alwaysShowIcons }
    var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Switches layout (or re-reads Compact view / check boxes / extensions) keeping selection, and
    /// keeping the first visible item at the start of the view.
    func configure(mode: ViewMode, keepTop: Bool) {
        let top = keepTop ? firstVisibleIndex : nil
        self.mode = mode
        metrics = IconLayoutMetrics(mode: mode, compact: Prefs.compactView)
        if mode == .list {
            metrics.cellSize.width = IconLayoutMetrics.listColumnWidth(names: items.map(displayName), font: metrics.nameFont,
                                                                       checkBoxes: checkBoxes)
        }
        layout = metrics.makeLayout()
        textCache.removeAllObjects()
        heightCache.removeAllObjects()
        relayout()
        if let top { scrollToStart(top) }
        canvas.needsDisplay = true
        scheduleVisibleWork()
    }

    /// New listing. Selection is restored by the controller (by name) afterwards.
    func setItems(_ newItems: [FileItem], locationChanged: Bool) {
        items = newItems
        if locationChanged {
            thumbnails.reset()
            ImageInfoService.shared.cancelPending()
            typeSelect.reset()
            selection = ItemSelection()
            showsFocus = false
        } else {
            selection.clamp(to: items.count)
        }
        hovered = nil
        dropTarget = nil
        configure(mode: mode, keepTop: false)
    }

    private var clipView: NSClipView? { enclosingScrollView?.contentView }

    private var viewportSize: CGSize {
        guard let clip = clipView else { return bounds.size }
        return clip.bounds.size
    }

    /// Re-flows for the current viewport and resizes the document.
    func relayout() {
        let viewport = viewportSize
        layout.update(count: items.count, viewport: viewport)
        let size = layout.contentSize
        if frame.size != size { setFrameSize(size) }
        if let pending = pendingScrollStart, viewport.width > 1, viewport.height > 1 {
            pendingScrollStart = nil
            scrollToStart(pending)
        }
        visibleAreaChanged()
    }

    /// Clip view resized (window resize, pane toggled): re-flow, keeping the first visible item.
    func viewportChanged() {
        let viewport = viewportSize
        guard viewport != layout.viewport else { visibleAreaChanged(); return }
        let top = firstVisibleIndex
        relayout()
        if let top, pendingScrollStart == nil { scrollToStart(top) }
    }

    /// Scrolled or resized: move the canvas over the visible area and load what's now on screen.
    func visibleAreaChanged() {
        var visible = visibleRect
        if visible.isEmpty { visible = NSRect(origin: .zero, size: viewportSize) }
        if canvas.frame != visible { canvas.frame = visible }
        canvas.needsDisplay = true
        scheduleVisibleWork()
    }

    // MARK: Scrolling

    var firstVisibleIndex: Int? { layout.firstVisibleIndex(in: visibleRect.isEmpty ? bounds : visibleRect) }

    /// Puts an item's row (or List column) at the top (or left) edge.
    func scrollToStart(_ index: Int) {
        guard index >= 0, index < items.count, let clip = clipView else { return }
        let viewport = viewportSize
        guard viewport.width > 1, viewport.height > 1, layout.viewport == viewport else {
            pendingScrollStart = index
            return
        }
        clip.scroll(to: layout.scrollOrigin(toShowAtStart: index))
        enclosingScrollView?.reflectScrolledClipView(clip)
        visibleAreaChanged()
    }

    func scrollToTop() {
        pendingScrollStart = nil
        clipView?.scroll(to: .zero)
        if let clip = clipView { enclosingScrollView?.reflectScrolledClipView(clip) }
        visibleAreaChanged()
    }

    func scrollItemToVisible(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        var rect = geometry(index).highlight
        rect = rect.insetBy(dx: layout.flow == .columns ? -metrics.spacing.width - 4 : 0,
                            dy: layout.flow == .rows ? -max(metrics.spacing.height, 4) : 0)
        if layout.flow == .rows { rect.origin.x = 0; rect.size.width = 1 } else { rect.origin.y = 0; rect.size.height = 1 }
        scrollToVisible(rect)
        visibleAreaChanged()
    }

    /// Scrolls when the pointer is outside the visible area during a marquee or a drag (FE-058).
    @discardableResult
    func autoscrollStep(windowPoint: NSPoint) -> Bool {
        guard let clip = clipView else { return false }
        let p = clip.convert(windowPoint, from: nil)
        let b = clip.bounds
        var delta: CGFloat = 0
        if layout.flow == .rows {
            if p.y < b.minY { delta = p.y - b.minY } else if p.y > b.maxY { delta = p.y - b.maxY }
        } else {
            if p.x < b.minX { delta = p.x - b.minX } else if p.x > b.maxX { delta = p.x - b.maxX }
        }
        guard delta != 0 else { return false }
        let step = (delta < 0 ? -1 : 1) * min(max(abs(delta) * 0.6, 6), 80)
        var origin = b.origin
        if layout.flow == .rows {
            origin.y = min(max(0, origin.y + step), max(0, frame.height - b.height))
        } else {
            origin.x = min(max(0, origin.x + step), max(0, frame.width - b.width))
        }
        guard origin != b.origin else { return false }
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        visibleAreaChanged()
        return true
    }

    // MARK: Thumbnails and metadata for visible items

    func scheduleVisibleWork() {
        guard !visibleWorkScheduled else { return }
        visibleWorkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibleWorkScheduled = false
            self.loadVisibleWork()
        }
    }

    /// Indexes on screen plus one line of look-ahead, in display order.
    var visibleIndexes: [Int] {
        guard window != nil else { return [] }
        var rect = visibleRect
        if layout.flow == .rows { rect = rect.insetBy(dx: 0, dy: -metrics.cellSize.height) } else { rect = rect.insetBy(dx: -metrics.cellSize.width, dy: 0) }
        return layout.indexes(in: rect)
    }

    private func loadVisibleWork() {
        let visible = visibleIndexes
        let points = metrics.iconSize
        let scale = self.scale
        let pixels = ThumbnailPolicy.pixelSize(points: points, scale: scale)
        var wanted: [(item: FileItem, key: ThumbnailKey, points: CGFloat, scale: CGFloat)] = []
        if !iconsOnly {
            for i in visible where ThumbnailPolicy.wantsThumbnail(items[i], iconPoints: points, iconsOnly: false) {
                wanted.append((items[i], ThumbnailKey(item: items[i], pixels: pixels), points, scale))
            }
        }
        thumbnails.update(wanted: wanted)
        if metrics.style == .content {
            for i in visible where ThumbnailPolicy.hasDimensions(items[i]) && ImageInfoService.shared.dimensions(for: items[i]) == nil {
                ImageInfoService.shared.request(items[i]) { [weak self] in self?.canvas.needsDisplay = true }
            }
        }
    }

    // MARK: Names

    func displayName(_ item: FileItem) -> String {
        guard !Prefs.showExtensions, !item.isFolder else { return item.name }
        let base = NameRules.splitExtension(item.name, treatAsFolder: false).base
        return base.isEmpty ? item.name : base
    }

    // MARK: Hit testing

    /// The item under a point: inside its highlight shape, not just its cell (gaps start a marquee).
    func itemHit(_ point: CGPoint) -> Int? {
        guard let i = layout.index(at: point) else {
            // The selected item's expanded label can reach into the next row.
            if let e = expandedIndex, geometry(e, expanded: true).highlight.contains(point) { return e }
            return nil
        }
        if let e = expandedIndex, e != i, geometry(e, expanded: true).highlight.contains(point) { return e }
        return geometry(i, expanded: i == expandedIndex).highlight.contains(point) ? i : nil
    }

    func checkboxHit(_ point: CGPoint) -> Int? {
        guard checkBoxes, let i = itemHit(point) else { return nil }
        return geometry(i).checkbox.insetBy(dx: -3, dy: -3).contains(point) ? i : nil
    }

    /// The selected, focused item shows its whole name under a large icon (Explorer).
    var expandedIndex: Int? {
        guard metrics.style == .iconAbove, editingIndex == nil, selection.selected.count == 1,
              let focus = selection.focus, selection.selected.contains(focus), focus < items.count else { return nil }
        return focus
    }

    // MARK: Selection

    var selectedItems: [FileItem] { selection.selected.compactMap { $0 < items.count ? items[$0] : nil } }

    /// Applies a selection change: redraws and tells the host if the selected set changed.
    func commit(_ old: ItemSelection) {
        canvas.needsDisplay = true
        if old.selected != selection.selected { host?.gridSelectionChanged() }
    }

    func setSelection(_ indexes: IndexSet, notify: Bool = true) {
        let old = selection
        selection.set(indexes)
        if notify { commit(old) } else { canvas.needsDisplay = true }
    }

    private func navigate(_ move: ItemFlowLayout.Move, extend: Bool, focusOnly: Bool) {
        guard let target = layout.target(from: selection.focus, move: move, visible: viewportSize) else { return }
        let old = selection
        selection.move(to: target, extend: extend, focusOnly: focusOnly)
        showsFocus = true
        scrollItemToVisible(target)
        commit(old)
    }

    private func typeSelectInput(_ text: String) {
        guard let match = typeSelect.input(text, at: Date(), names: items.map(\.name), current: selection.focus) else {
            NSSound.beep()
            return
        }
        let old = selection
        selection.move(to: match, extend: false, focusOnly: false)
        scrollItemToVisible(match)
        commit(old)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { setHovered(itemHit(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        removeAllToolTips()
        if let index { addToolTip(geometry(index, expanded: index == expandedIndex).highlight, owner: self, userData: nil) }
        canvas.needsDisplay = true
    }

    /// Infotip: full name, type, size and date (Explorer's "pop-up description").
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = hovered, i < items.count else { return "" }
        // Folder Options › "Show pop-up description for folder and desktop items"; off leaves the full name.
        return Prefs.bool("showPopupDescriptions", default: true) ? ItemGridView.infotip(items[i], location: location) : items[i].name
    }

    /// The location shown (for `InteractionHooks.itemDetail`, e.g. search results' folder).
    var location: Location?

    static func infotip(_ item: FileItem, location: Location? = nil) -> String {
        var lines = [item.name, L10n.format("Type: %@", "\(item.typeDescription)")]
        if let size = item.size, !item.isFolder { lines.append(L10n.format("Size: %@", "\(StatusText.bytes(size))")) }
        if let date = item.modified { lines.append(L10n.format("Date modified: %@", "\(ItemGridView.dateFormatter.string(from: date))")) }
        if let detail = InteractionHooks.itemDetail.first((item, location)) { lines.append("\(detail.label) \(detail.value)") }
        return lines.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    override func mouseDown(with event: NSEvent) {
        cancelSlowRename()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let command = flags.contains(.command), shift = flags.contains(.shift)
        showsFocus = false
        if let i = checkboxHit(point) {
            let old = selection
            selection.click(i, .toggle)
            commit(old)
            return
        }
        guard let i = itemHit(point) else {
            if event.clickCount == 1 { trackMarquee(from: event) }
            return
        }
        if event.clickCount >= 2, !command, !shift {
            if !selection.selected.contains(i) {
                let old = selection
                selection.click(i, .none)
                commit(old)
            }
            host?.gridOpen(selectedItems, inNewTab: false)
            return
        }
        let old = selection
        let wasOnlySelection = selection.selected == [i]
        let nameRect = geometry(i, expanded: i == expandedIndex).name
        var collapseOnMouseUp = false
        if command && shift { selection.click(i, .extendAdding) }
        else if command { selection.click(i, .toggle) }
        else if shift { selection.click(i, .extend) }
        else if selection.selected.contains(i) {
            // Keep a multiple selection so it can be dragged; collapse it on mouse up.
            collapseOnMouseUp = true
            selection.focus = i
            selection.anchor = i
        } else { selection.click(i, .none) }
        commit(old)
        if selection.selected.contains(i), trackDrag(from: event) { return }
        if collapseOnMouseUp {
            let before = selection
            selection.click(i, .none)
            commit(before)
        }
        if wasOnlySelection, !command, !shift, nameRect.contains(point), host?.gridAllowsEditing == true {
            scheduleSlowRename(i)
        }
    }

    /// Waits for a drag past the threshold (returns true once a drag session started) or mouse up.
    private func trackDrag(from down: NSEvent) -> Bool {
        let start = down.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return false }
            let p = next.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > 4 {
                beginDrag(with: down)
                return true
            }
        }
        return false
    }

    private func scheduleSlowRename(_ index: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.selection.selected == [index], self.window?.firstResponder === self else { return }
            self.host?.gridBeginRename(at: index)
        }
        slowRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.15, execute: work)
    }

    func cancelSlowRename() {
        slowRename?.cancel()
        slowRename = nil
    }

    /// A feature may start a right-button drag here (FE-106); otherwise the context menu opens.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let i = itemHit(point), !InteractionHooks.rightDrag.isEmpty {
            let urls: () -> [URL] = { [weak self] in
                guard let self else { return [] }
                if !self.selection.selected.contains(i) { self.setSelection(IndexSet(integer: i)) }
                return self.selectedItems.filter { ItemHooks.dragWriter(for: $0) == nil }.map(\.url)
            }
            if InteractionHooks.rightDrag.handle((self, event, urls)) { return }
        }
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let i = itemHit(convert(event.locationInWindow, from: nil)), items[i].isFolder else {
            super.otherMouseDown(with: event)
            return
        }
        host?.gridOpen([items[i]], inNewTab: true)
    }

    /// Right-clicking an unselected item selects it; empty space clears the selection (spec §7.1).
    override func menu(for event: NSEvent) -> NSMenu? {
        cancelSlowRename()
        let point = convert(event.locationInWindow, from: nil)
        let old = selection
        if let i = itemHit(point) {
            if !selection.selected.contains(i) { selection.click(i, .none) }
        } else {
            selection.clickBackground(keepSelection: false)
        }
        commit(old)
        return host?.gridContextMenu()
    }

    // MARK: Marquee (FE-058)

    private struct MarqueeState {
        var start: CGPoint
        var base: IndexSet
        var toggle: Bool
        var add: Bool
    }
    private var marquee: MarqueeState?

    private func trackMarquee(from event: NSEvent) {
        marqueeBegan(at: convert(event.locationInWindow, from: nil), toggle: event.modifierFlags.contains(.command),
                     add: event.modifierFlags.contains(.shift))
        NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.04)
        defer {
            NSEvent.stopPeriodicEvents()
            marqueeEnded()
        }
        var last = event.locationInWindow
        var moved = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            switch next.type {
            case .leftMouseUp:
                return
            case .leftMouseDragged:
                last = next.locationInWindow
                moved = true
                marqueeMoved(toWindowPoint: last)
            default:
                if moved, autoscrollStep(windowPoint: last) { marqueeMoved(toWindowPoint: last) }
            }
        }
    }

    func marqueeBegan(at point: CGPoint, toggle: Bool, add: Bool) {
        let old = selection
        if !toggle && !add { selection.clickBackground(keepSelection: false) }
        marquee = MarqueeState(start: point, base: selection.selected, toggle: toggle, add: add)
        commit(old)
    }

    func marqueeMoved(toWindowPoint point: NSPoint) { marqueeMoved(to: convert(point, from: nil)) }

    func marqueeMoved(to point: CGPoint) {
        guard let state = marquee else { return }
        let clamped = CGPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
        let rect = CGRect(x: min(state.start.x, clamped.x), y: min(state.start.y, clamped.y),
                          width: abs(clamped.x - state.start.x), height: abs(clamped.y - state.start.y))
        marqueeRect = rect
        var hits = IndexSet()
        let candidates = layout.indexes(in: rect)
        let precise = candidates.count <= 3000
        for i in candidates where !precise || marqueeShape(i).intersects(rect) { hits.insert(i) }
        let old = selection
        selection.selected = ItemSelection.marquee(base: state.base, hits: hits, toggle: state.toggle, add: state.add)
        if let last = hits.last { selection.focus = last; selection.anchor = hits.first }
        commit(old)
    }

    func marqueeEnded() {
        marquee = nil
        marqueeRect = nil
        canvas.needsDisplay = true
    }

    /// The part of an item a marquee must touch: icon and name, not the empty end of a List column.
    private func marqueeShape(_ i: Int) -> CGRect {
        let g = geometry(i)
        return metrics.style == .iconLeft ? g.highlight : g.cell.insetBy(dx: 2, dy: 0)
    }

    // MARK: Keyboard (FE-060)

    override func keyDown(with event: NSEvent) {
        cancelSlowRename()
        if typeSelectText.hasMarkedText(), typeSelectText.handle(event, typeSelectActive: true) { return }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let move: ItemFlowLayout.Move?
        switch event.keyCode {
        case 123: move = .left
        case 124: move = .right
        case 125: move = .down
        case 126: move = .up
        case 115: move = .home
        case 119: move = .end
        case 116: move = .pageUp
        case 121: move = .pageDown
        default: move = nil
        }
        if let move, !mods.contains(.command), !mods.contains(.option) {
            navigate(move, extend: mods.contains(.shift), focusOnly: mods.contains(.control))
            return
        }
        switch event.keyCode {
        case 36, 76:   // Return / Enter opens, like Explorer
            if !selection.selected.isEmpty, mods.isEmpty || mods == .command {
                host?.gridOpen(selectedItems, inNewTab: mods == .command)
                return
            }
        case 49 where mods == .control:   // Ctrl+Space toggles the focused item
            let old = selection
            selection.toggleFocused()
            showsFocus = true
            commit(old)
            return
        case 49 where mods.isEmpty && typeSelect.isActive(at: Date()):
            typeSelectInput(" ")
            return
        default:
            break
        }
        if host?.gridKey(event) == true { return }
        if typeSelectText.handle(event, typeSelectActive: typeSelect.isActive(at: Date())) { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        canvas.needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        canvas.needsDisplay = true
        typeSelectText.reset()
        return true
    }

    /// Scripted checks of input-method type-to-select.
    var typeSelectInputForScripts: TypeSelectInput { typeSelectText }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, SelectionEmphasis.changed] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: name == SelectionEmphasis.changed ? nil : window, queue: .main) { [weak self] _ in
                self?.canvas.needsDisplay = true
            })
        }
        scheduleVisibleWork()
    }

    /// Selection is drawn in the accent tint while the grid has focus in the key window.
    var isActive: Bool {
        guard let window else { return false }
        return window.firstResponder === self && SelectionEmphasis.windowIsActive(window)
    }

    // MARK: Drag source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link] : [.copy, .move]
    }

    private func beginDrag(with event: NSEvent) {
        let indexes = Array(selection.selected)
        guard !indexes.isEmpty else { return }
        var dragItems: [NSDraggingItem] = []
        dragItems.reserveCapacity(indexes.count)
        let anchorFrame = geometry(indexes[0]).icon
        for (n, i) in indexes.enumerated() {
            let dragItem = NSDraggingItem(pasteboardWriter: ItemHooks.dragWriter(for: items[i]) ?? items[i].url as NSURL)
            if n < 24 {
                dragItem.setDraggingFrame(geometry(i).icon, contents: dragImage(for: items[i]))
            } else {
                dragItem.setDraggingFrame(anchorFrame, contents: nil)
            }
            dragItems.append(dragItem)
        }
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    private func dragImage(for item: FileItem) -> NSImage {
        let size = metrics.iconSize
        if let key = thumbnailKey(for: item), let hit = ThumbnailService.shared.image(for: key) {
            return NSImage(cgImage: hit.image, size: NSSize(width: size, height: size))
        }
        return IconProvider.shared.icon(for: item, size: size)
    }

    func thumbnailKey(for item: FileItem) -> ThumbnailKey? {
        guard ThumbnailPolicy.wantsThumbnail(item, iconPoints: metrics.iconSize, iconsOnly: iconsOnly) else { return nil }
        return ThumbnailKey(item: item, pixels: ThumbnailPolicy.pixelSize(points: metrics.iconSize, scale: scale))
    }

    // MARK: Drop destination (same rules as Details: DropPolicy, folders or the background)

    private func dropDestination(_ info: NSDraggingInfo) -> (url: URL?, index: Int?) {
        let point = convert(info.draggingLocation, from: nil)
        if let i = itemHit(point), items[i].isFolder { return (items[i].url, i) }
        return (host?.gridFolder, nil)
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let (dest, index) = dropDestination(info)
        if let op = ItemHooks.dropOperation(info, destination: dest) { setDropTarget(index); return op }   // file promises
        guard let dest, let kind = DropPolicy.kind(sources: DropPolicy.fileURLs(from: info), destination: dest,
                                                   mask: info.draggingSourceOperationMask) else {
            setDropTarget(nil)
            return []
        }
        setDropTarget(index)
        let spring = index.map { items[$0] }   // spring-loaded folders (FE-108), as in Details
        InteractionHooks.dragHover.send((spring?.url.path, spring.map { item in
            { [weak self] in self?.host?.gridOpen([item], inNewTab: false) }
        }))
        return kind == .move ? .move : .copy
    }

    private func setDropTarget(_ index: Int?) {
        guard index != dropTarget else { return }
        dropTarget = index
        canvas.needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        autoscrollStep(windowPoint: sender.draggingLocation)
        return dropOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTarget(nil)
        InteractionHooks.dragHover.send((nil, nil))
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropTarget(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropTarget(nil) }
        InteractionHooks.dragHover.send((nil, nil))
        if ItemHooks.acceptDrop(sender, destination: dropDestination(sender).url, window: window) { return true }
        let urls = DropPolicy.fileURLs(from: sender)
        guard let dest = dropDestination(sender).url,
              let kind = DropPolicy.kind(sources: urls, destination: dest, mask: sender.draggingSourceOperationMask) else { return false }
        host?.gridTransfer(kind, urls, to: dest)
        return true
    }

    var dropTargetIndex: Int? { dropTarget }

    // MARK: Accessibility: one element per item (ItemGridAccessibility.swift)

    override func accessibilityChildren() -> [Any]? { ItemGridAccessibility.children(self) }

    override func accessibilitySelectedChildren() -> [Any]? { ItemGridAccessibility.selectedChildren(self) }
}
