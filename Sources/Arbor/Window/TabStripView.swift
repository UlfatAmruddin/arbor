import AppKit
import ArborCore

protocol TabStripDelegate: AnyObject {
    func tabStripSelect(_ index: Int)
    func tabStripClose(_ index: Int)
    func tabStripNewTab()
    func tabStripMove(from: Int, to: Int)
    func tabStripDetach(_ index: Int)
    func tabStripMenu(for index: Int) -> NSMenu?
    /// A tab was dragged out of the strip and released at a screen point: merge it into the window
    /// whose tab row is there, or tear it off into a new window (FE-020).
    func tabStripTearOff(_ index: Int, at screenPoint: NSPoint, grabOffset: NSPoint)
    /// The only tab is being dragged: the window moves with it and may merge into another window.
    func tabStripDragWindow(with event: NSEvent)
    /// While a tab is dragged outside its strip: show where it would land (nil clears).
    func tabStripDragHover(at screenPoint: NSPoint?)
}

extension TabStripDelegate {
    func tabStripTearOff(_ index: Int, at screenPoint: NSPoint, grabOffset: NSPoint) { tabStripDetach(index) }
    func tabStripDragWindow(with event: NSEvent) {}
    func tabStripDragHover(at screenPoint: NSPoint?) {}
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
    private let scroll = TabScrollView()
    private let document = FlippedView()
    let plusButton = ChromeButton(symbol: "plus", tooltip: "New tab (⌘T)")
    /// Overflow arrows, shown only when the tabs don't fit at their minimum width (WinUI TabView style).
    let scrollLeftButton = ChromeButton(symbol: "chevron.left", tooltip: "Scroll tab list backward")
    let scrollRightButton = ChromeButton(symbol: "chevron.right", tooltip: "Scroll tab list forward")
    /// Insertion marker while another window's tab hovers over this strip.
    private let dropMarker = ThemeBackgroundView(Theme.accent)
    /// The tab being dragged keeps its own frame during the drag.
    fileprivate var draggingIndex: Int?
    private(set) var isOverflowing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(L10n.tr("Tabs"))
        for (button, step) in [(scrollLeftButton, -1), (scrollRightButton, 1)] {
            button.symbolSize = 10
            button.fixedWidth = Theme.tabScrollButtonWidth
            button.fixedHeight = 28
            button.translatesAutoresizingMaskIntoConstraints = true
            button.isHidden = true
            button.onClick = { [weak self] _ in self?.scrollTabs(by: step) }
            addSubview(button)
        }
        dropMarker.translatesAutoresizingMaskIntoConstraints = true
        dropMarker.isHidden = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
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
        plusButton.setAccessibilityLabel(L10n.tr("New tab"))
        addSubview(plusButton)
        addSubview(dropMarker)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Overflow scrolling

    /// Scrolls the tab list by whole tabs (overflow arrows).
    func scrollTabs(by tabs: Int) {
        let clip = scroll.contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let x = min(max(0, clip.bounds.minX + CGFloat(tabs) * tabWidth), maxX)
        clip.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(clip)
        updateScrollButtons()
    }

    @objc private func scrolled() { updateScrollButtons() }

    private func updateScrollButtons() {
        let clip = scroll.contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        // The tabs' outer "feet" may stay clipped; only whole hidden tab bodies count.
        scrollLeftButton.isEnabled = clip.bounds.minX > Self.feet + 0.5
        scrollRightButton.isEnabled = clip.bounds.minX < maxX - Self.feet - 0.5
    }

    /// The slot a tab dropped at `screenPoint` would take (merging from another window).
    func insertionSlot(atScreen screenPoint: NSPoint) -> Int {
        guard let window else { return items.count }
        let local = document.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let x = RightToLeft.isActive(self) ? document.bounds.width - local.x : local.x   // FE-204
        return min(max(Int(((x - Self.feet) / max(tabWidth, 1)).rounded()), 0), items.count)
    }

    /// Shows (or hides, with nil) the insertion marker before slot `index`.
    func showDropMarker(at index: Int?) {
        guard let index else { dropMarker.isHidden = true; return }
        let slotX = Self.feet + CGFloat(index) * tabWidth
        let x = document.convert(NSPoint(x: RightToLeft.isActive(self) ? document.bounds.width - slotX : slotX, y: 0), to: self).x
        let top = bounds.height - Theme.tabHeight
        dropMarker.color = Theme.accent
        dropMarker.frame = NSRect(x: x - 1, y: top + 6, width: 2, height: Theme.tabHeight - 12)
        dropMarker.isHidden = false
    }

    /// The tab row in screen coordinates (where a dragged tab merges).
    var screenFrame: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // MARK: Spring-loaded tabs (FE-108): a file drag resting on a tab switches to it. Tabs aren't drop targets.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = document.convert(sender.draggingLocation, from: nil)
        let index = tabViews.firstIndex { $0.frame.insetBy(dx: Self.feet, dy: 0).contains(point) }
        InteractionHooks.dragHover.send((index.map { "tab:\(ObjectIdentifier(self).hashValue):\($0)" }, index.map { i in
            { [weak self] in self?.delegate?.tabStripSelect(i) }
        }))
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { InteractionHooks.dragHover.send((nil, nil)) }

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
        var available = max(0, bounds.width - leadingInset - 8 - plusButton.fixedWidth! - 4)
        isOverflowing = total > available + 0.5
        let arrow = Theme.tabScrollButtonWidth
        if isOverflowing { available = max(0, available - arrow * 2) }
        let visible = min(total, available)
        let top = bounds.height - Theme.tabHeight
        let buttonY = top + (Theme.tabHeight - 28) / 2 - 1
        let start = leadingInset + (isOverflowing ? arrow : 0)
        scroll.frame = NSRect(x: start - Self.feet, y: top, width: visible + Self.feet * 2, height: Theme.tabHeight)
        document.frame = NSRect(x: 0, y: 0, width: total + Self.feet * 2, height: Theme.tabHeight)
        for (i, view) in tabViews.enumerated() where i != draggingIndex {
            view.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width + Self.feet * 2, height: Theme.tabHeight)
        }
        scrollLeftButton.isHidden = !isOverflowing
        scrollRightButton.isHidden = !isOverflowing
        scrollLeftButton.frame = NSRect(x: leadingInset, y: buttonY, width: arrow, height: 28)
        scrollRightButton.frame = NSRect(x: scroll.frame.maxX - Self.feet, y: buttonY, width: arrow, height: 28)
        let plusX = (isOverflowing ? scrollRightButton.frame.maxX : scroll.frame.maxX - Self.feet) + 2
        plusButton.frame = NSRect(x: plusX, y: buttonY, width: plusButton.fixedWidth!, height: 28)
        RightToLeft.mirror(self, [scroll, plusButton, scrollLeftButton, scrollRightButton], contents: document, [tabViews])   // FE-204
        if RightToLeft.isActive(self) {
            // The arrows keep pointing at the side they scroll toward: swap them back after mirroring.
            let left = scrollLeftButton.frame
            scrollLeftButton.frame = scrollRightButton.frame
            scrollRightButton.frame = left
        }
        updateScrollButtons()
    }

    private func scrollToSelected() {
        guard tabViews.indices.contains(selectedIndex) else { return }
        document.scrollToVisible(tabViews[selectedIndex].frame.insetBy(dx: Self.feet, dy: 0))
        updateScrollButtons()
    }

    /// Visible tab range and overflow state, for scripted checks.
    var debugOverflow: String {
        let clip = scroll.contentView.bounds
        let first = Int((clip.minX / max(tabWidth, 1)).rounded())
        let last = min(items.count, Int(((clip.maxX - Self.feet * 2) / max(tabWidth, 1)).rounded()))
        return "overflow=\(isOverflowing) tabWidth=\(Int(tabWidth)) visible=\(first + 1)-\(last) of \(items.count)"
            + " back=\(scrollLeftButton.isEnabled) forward=\(scrollRightButton.isEnabled)"
    }

    /// Scripted checks: drop tab `index` (0-based) after dragging it `dx` points along the row, as the mouse does.
    func scriptDrag(_ index: Int, by dx: CGFloat) {
        guard tabViews.indices.contains(index) else { return }
        let view = tabViews[index]
        let maxX = max(0, document.bounds.width - view.frame.width)
        finishDrag(of: view, at: min(max(view.frame.minX + dx, 0), maxX), detachedFromStrip: false)
    }

    fileprivate func finishDrag(of view: TabItemView, at x: CGFloat, detachedFromStrip: Bool) {
        draggingIndex = nil
        let from = view.index
        if detachedFromStrip, items.count > 1 {
            needsLayout = true
            delegate?.tabStripDetach(from)
            return
        }
        // Counted from the leading edge, which is the right one in a right-to-left layout (FE-204).
        let to = TabStripGeometry.reorderSlot(tabMinX: x, tabWidth: tabWidth, viewWidth: view.frame.width,
                                              contentWidth: document.bounds.width, count: items.count,
                                              rightToLeft: RightToLeft.isActive(self))
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
        closeButton.setAccessibilityLabel(L10n.tr("Close tab"))
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
        let closeX = RightToLeft.isActive(self) ? body.minX + 6 : body.maxX - 28   // FE-204: ✕ on the trailing (left) side
        closeButton.frame = NSRect(x: closeX, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = body
        if isSelected {
            Theme.toolbarBackground.setFill()
            tabPath(b).fill()
        } else if isHovered {
            fillRounded(NSRect(x: b.minX + 2, y: b.minY + 2, width: b.width - 4, height: b.height - 6), radius: 6, Theme.hover)
        }
        // Right to left (FE-204): icon and title start at the right, the ✕ and the separator sit on the left.
        let rtl = RightToLeft.isActive(self)
        if showsTrailingSeparator {
            Theme.tabSeparator.setFill()
            NSRect(x: (rtl ? b.minX : b.maxX) - 0.5, y: b.minY + 9, width: 1, height: b.height - 18).fill(using: .sourceOver)
        }
        let iconRect = NSRect(x: rtl ? b.maxX - 28 : b.minX + 12, y: (b.height - 16) / 2, width: 16, height: 16)
        item.icon.drawFlippedAware(in: iconRect)
        let closeRoom: CGFloat = (isSelected || isHovered) ? 32 : 10
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.tabFont,
            .foregroundColor: isSelected ? Theme.primaryText : Theme.secondaryText,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = rtl ? .right : .left; return p }(),
        ]
        let titleHeight = ceil(Theme.tabFont.ascender - Theme.tabFont.descender)
        let titleLeft = rtl ? b.minX + closeRoom : iconRect.maxX + 8
        let titleRight = rtl ? iconRect.minX - 8 : b.maxX - closeRoom
        let titleRect = NSRect(x: titleLeft, y: (b.height - titleHeight) / 2, width: max(0, titleRight - titleLeft), height: titleHeight)
        (item.title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        if hasKeyboardFocus { FocusVisual.draw(in: NSRect(x: b.minX + 1, y: b.minY + 1, width: b.width - 2, height: b.height - 3), radius: 6) }
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

    /// Press selects (like Explorer); dragging along the strip reorders; dragging out of the tab row tears the
    /// tab off into a new window, or merges it into the window whose tab row it is dropped on (FE-020).
    /// The only tab of a window drags the window itself (and can merge the same way).
    override func mouseDown(with event: NSEvent) {
        guard let strip, let window else { return }
        strip.delegate?.tabStripSelect(index)
        if strip.items.count == 1 {
            strip.delegate?.tabStripDragWindow(with: event)
            return
        }
        let start = event.locationInWindow
        let startX = frame.minX
        let grab = convert(event.locationInWindow, from: nil)
        var dragging = false
        var lastX = startX
        var detached = false
        var ghost: TabDragGhost?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start.x
            if next.type == .leftMouseUp { break }
            if !dragging, abs(dx) > 5 || abs(next.locationInWindow.y - start.y) > 5 {
                dragging = true; strip.draggingIndex = index; superview?.addSubview(self)
            }
            if dragging {
                let maxX = max(0, (superview?.bounds.width ?? 0) - frame.width)
                lastX = min(max(startX + dx, 0), maxX)
                setFrameOrigin(NSPoint(x: lastX, y: frame.minY))
            }
            // Out of the tab row (with a little slack): the tab follows the pointer as a floating image.
            let inStrip = strip.convert(next.locationInWindow, from: nil)
            detached = dragging && (inStrip.y < -Theme.tabTearOffSlack || inStrip.y > strip.bounds.height + Theme.tabTearOffSlack
                                    || inStrip.x < -Theme.tabTearOffSlack || inStrip.x > strip.bounds.width + Theme.tabTearOffSlack)
            let screen = NSEvent.mouseLocation
            if detached {
                if ghost == nil { ghost = TabDragGhost(snapshotOf: self, grab: grab) }
                ghost?.move(to: screen)
                isHidden = true
                strip.delegate?.tabStripDragHover(at: screen)
            } else if ghost != nil {
                ghost?.close()
                ghost = nil
                isHidden = false
                strip.delegate?.tabStripDragHover(at: nil)
            }
        }
        ghost?.close()
        isHidden = false
        strip.delegate?.tabStripDragHover(at: nil)
        guard dragging else { return }
        if detached {
            strip.draggingIndex = nil
            strip.needsLayout = true
            let offset = NSPoint(x: grab.x - TabStripView.feet, y: grab.y)
            strip.delegate?.tabStripTearOff(index, at: NSEvent.mouseLocation, grabOffset: offset)
            return
        }
        strip.finishDrag(of: self, at: lastX, detachedFromStrip: false)
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
