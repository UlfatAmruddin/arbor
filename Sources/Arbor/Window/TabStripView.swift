import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripSelect(_ index: Int)
    func tabStripClose(_ index: Int)
    func tabStripNewTab()
    func tabStripMove(from: Int, to: Int)
    func tabStripDetach(_ index: Int)
    func tabStripMenu(for index: Int) -> NSMenu?
}

struct TabStripItem: Equatable {
    var title: String
    var icon: NSImage
    var tooltip: String
}

/// Explorer-style tabs in the title bar row (FE-017–FE-020): icon + title + close button; the active
/// tab joins the navigation row below; "+" follows the last tab. Tabs shrink to a minimum width and
/// then scroll. Empty space drags the window; double-clicking it zooms (Mac convention).
final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    var leadingInset: CGFloat = Theme.trafficLightInset { didSet { needsLayout = true } }
    private(set) var items: [TabStripItem] = []
    private(set) var selectedIndex = 0
    private var tabViews: [TabItemView] = []
    private let scroll = NSScrollView()
    private let document = FlippedView()
    let plusButton = ChromeButton(symbol: "plus", tooltip: "New tab (⌘T)")
    /// The tab being dragged keeps its own frame during the drag.
    fileprivate var draggingIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        addSubview(scroll)
        plusButton.symbolSize = 13
        plusButton.fixedWidth = 32
        plusButton.fixedHeight = 28
        plusButton.translatesAutoresizingMaskIntoConstraints = true
        plusButton.onClick = { [weak self] _ in self?.delegate?.tabStripNewTab() }
        plusButton.setAccessibilityLabel("New tab")
        addSubview(plusButton)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Spring-loaded tabs (FE-108): a file drag resting on a tab switches to it. Tabs aren't drop targets.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = document.convert(sender.draggingLocation, from: nil)
        let index = tabViews.firstIndex { $0.frame.insetBy(dx: Self.feet, dy: 0).contains(point) }
        InteractionHooks.dragHover?(index.map { "tab:\(ObjectIdentifier(self).hashValue):\($0)" }, index.map { i in
            { [weak self] in self?.delegate?.tabStripSelect(i) }
        })
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { InteractionHooks.dragHover?(nil, nil) }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tabStripBackground.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
    }

    func reload(items: [TabStripItem], selected: Int) {
        let structural = items.count != self.items.count
        self.items = items
        selectedIndex = selected
        if structural {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = items.indices.map { _ in
                let view = TabItemView()
                view.strip = self
                return view
            }
        }
        for (i, view) in tabViews.enumerated() {
            view.index = i
            view.item = items[i]
            view.isSelected = i == selected
        }
        // The active tab draws over its neighbours' separators.
        tabViews.enumerated().filter { $0.offset != selected }.forEach { document.addSubview($0.element) }
        if tabViews.indices.contains(selected) { document.addSubview(tabViews[selected]) }
        updateSeparators()
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollToSelected()
    }

    fileprivate func updateSeparators() {
        for (i, view) in tabViews.enumerated() {
            let next = i + 1 < tabViews.count ? tabViews[i + 1] : nil
            view.showsTrailingSeparator = !view.isSelected && !view.isHovered && !(next?.isSelected ?? false) && !(next?.isHovered ?? false)
        }
    }

    /// Width every tab gets now.
    fileprivate var tabWidth: CGFloat {
        let available = bounds.width - leadingInset - 8 - plusButton.fixedWidth! - 4
        guard !items.isEmpty else { return Theme.tabMaxWidth }
        return min(Theme.tabMaxWidth, max(Theme.tabMinWidth, floor(available / CGFloat(items.count))))
    }

    /// Feet: the active tab's outward curves at the bottom corners, drawn inside the tab's frame.
    static let feet: CGFloat = 6

    override func layout() {
        super.layout()
        (window as? BrowserWindow)?.layoutTrafficLights()
        let width = tabWidth
        let total = width * CGFloat(items.count)
        let available = max(0, bounds.width - leadingInset - 8 - plusButton.fixedWidth! - 4)
        let visible = min(total, available)
        let top = bounds.height - Theme.tabHeight
        scroll.frame = NSRect(x: leadingInset - Self.feet, y: top, width: visible + Self.feet * 2, height: Theme.tabHeight)
        document.frame = NSRect(x: 0, y: 0, width: total + Self.feet * 2, height: Theme.tabHeight)
        for (i, view) in tabViews.enumerated() where i != draggingIndex {
            view.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width + Self.feet * 2, height: Theme.tabHeight)
        }
        plusButton.frame = NSRect(x: scroll.frame.maxX - Self.feet + 2, y: top + (Theme.tabHeight - 28) / 2 - 1,
                                  width: plusButton.fixedWidth!, height: 28)
    }

    private func scrollToSelected() {
        guard tabViews.indices.contains(selectedIndex) else { return }
        document.scrollToVisible(tabViews[selectedIndex].frame)
    }

    /// Converts a document x position to the slot index a dragged tab would land in.
    fileprivate func slot(forDocumentX x: CGFloat) -> Int {
        let index = Int(floor(x / max(tabWidth, 1)))
        return min(max(index, 0), max(items.count - 1, 0))
    }

    fileprivate func finishDrag(of view: TabItemView, at x: CGFloat, detachedFromStrip: Bool) {
        draggingIndex = nil
        let from = view.index
        if detachedFromStrip, items.count > 1 {
            needsLayout = true
            delegate?.tabStripDetach(from)
            return
        }
        let to = slot(forDocumentX: x + tabWidth / 2)
        needsLayout = true
        if to != from { delegate?.tabStripMove(from: from, to: to) }
    }

    var debugTitles: [String] { items.map(\.title) }

    // MARK: Empty-area mouse: drag the window, double-click to zoom

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
            return
        }
        window?.performDrag(with: event)
    }
}

/// One tab.
final class TabItemView: NSView {
    weak var strip: TabStripView?
    var index = 0
    var item = TabStripItem(title: "", icon: NSImage(), tooltip: "") {
        didSet {
            guard item != oldValue else { return }
            toolTip = item.tooltip
            setAccessibilityLabel(item.title)
            needsDisplay = true
        }
    }
    var isSelected = false {
        didSet {
            closeButton.isHidden = !(isSelected || isHovered)
            setAccessibilityValue(isSelected)
            needsDisplay = true
        }
    }
    fileprivate(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            closeButton.isHidden = !(isSelected || isHovered)
            strip?.updateSeparators()
            needsDisplay = true
        }
    }
    var showsTrailingSeparator = false { didSet { if showsTrailingSeparator != oldValue { needsDisplay = true } } }
    private let closeButton = ChromeButton(symbol: "xmark", tooltip: "Close tab (⌘W)")
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        closeButton.symbolSize = 9
        closeButton.fixedWidth = 22
        closeButton.fixedHeight = 22
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.isHidden = true
        closeButton.setAccessibilityLabel("Close tab")
        closeButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.strip?.delegate?.tabStripClose(self.index)
        }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var body: NSRect { bounds.insetBy(dx: TabStripView.feet, dy: 0) }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: body.maxX - 28, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = body
        if isSelected {
            Theme.toolbarBackground.setFill()
            tabPath(b).fill()
        } else if isHovered {
            fillRounded(NSRect(x: b.minX + 2, y: b.minY + 2, width: b.width - 4, height: b.height - 6), radius: 6, Theme.hover)
        }
        if showsTrailingSeparator {
            Theme.tabSeparator.setFill()
            NSRect(x: b.maxX - 0.5, y: b.minY + 9, width: 1, height: b.height - 18).fill(using: .sourceOver)
        }
        let iconRect = NSRect(x: b.minX + 12, y: (b.height - 16) / 2, width: 16, height: 16)
        item.icon.drawFlippedAware(in: iconRect)
        let textRight = b.maxX - ((isSelected || isHovered) ? 32 : 10)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.tabFont,
            .foregroundColor: isSelected ? Theme.primaryText : Theme.secondaryText,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }(),
        ]
        let titleHeight = ceil(Theme.tabFont.ascender - Theme.tabFont.descender)
        let titleRect = NSRect(x: iconRect.maxX + 8, y: (b.height - titleHeight) / 2, width: max(0, textRight - iconRect.maxX - 8), height: titleHeight)
        (item.title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    /// Rounded top corners plus outward "feet" at the bottom, so the tab flows into the row below.
    private func tabPath(_ b: NSRect) -> NSBezierPath {
        let r = Theme.tabCornerRadius, f = TabStripView.feet
        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX - f, y: b.maxY))
        p.appendArc(from: NSPoint(x: b.minX, y: b.maxY), to: NSPoint(x: b.minX, y: b.maxY - f), radius: f)
        p.line(to: NSPoint(x: b.minX, y: b.minY + r))
        p.appendArc(from: NSPoint(x: b.minX, y: b.minY), to: NSPoint(x: b.minX + r, y: b.minY), radius: r)
        p.line(to: NSPoint(x: b.maxX - r, y: b.minY))
        p.appendArc(from: NSPoint(x: b.maxX, y: b.minY), to: NSPoint(x: b.maxX, y: b.minY + r), radius: r)
        p.line(to: NSPoint(x: b.maxX, y: b.maxY - f))
        p.appendArc(from: NSPoint(x: b.maxX, y: b.maxY), to: NSPoint(x: b.maxX + f, y: b.maxY), radius: f)
        p.close()
        return p
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: body, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Press selects (like Explorer); dragging reorders; dragging well below the strip moves the tab to a new window.
    override func mouseDown(with event: NSEvent) {
        guard let strip, let window else { return }
        strip.delegate?.tabStripSelect(index)
        let start = event.locationInWindow
        let startX = frame.minX
        var dragging = false
        var lastX = startX
        var detached = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start.x
            let dy = next.locationInWindow.y - start.y
            if next.type == .leftMouseUp { break }
            if !dragging, abs(dx) > 5 { dragging = true; strip.draggingIndex = index; superview?.addSubview(self) }
            if dragging {
                let maxX = max(0, (superview?.bounds.width ?? 0) - frame.width)
                lastX = min(max(startX + dx, 0), maxX)
                setFrameOrigin(NSPoint(x: lastX, y: frame.minY))
            }
            detached = abs(dy) > 60
        }
        if dragging || detached { strip.finishDrag(of: self, at: lastX, detachedFromStrip: detached) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.delegate?.tabStripClose(index) } else { super.otherMouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { strip?.delegate?.tabStripMenu(for: index) }

    override func accessibilityPerformPress() -> Bool {
        strip?.delegate?.tabStripSelect(index)
        return true
    }
}
