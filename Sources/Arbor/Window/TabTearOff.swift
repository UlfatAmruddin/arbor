import AppKit
import ArborCore

// Tear-off and merge (FE-020, reference §2.3). A dragged-out tab follows the pointer; dropped on
// another window's tab row it joins at the marked slot, elsewhere it becomes a new window.

extension BrowserWindowController {
    /// Another window whose visible tab row is frontmost at `screenPoint`; `below` skips the dragged window.
    func tabMergeTarget(at screenPoint: NSPoint, below windowNumber: Int = 0) -> BrowserWindowController? {
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: windowNumber)
        guard number > 0, let window = NSApp.window(withWindowNumber: number),
              let target = window.windowController as? BrowserWindowController, target !== self, !target.tabs.isEmpty,
              let row = target.tabStrip.screenFrame, row.insetBy(dx: 0, dy: -4).contains(screenPoint) else { return nil }
        return target
    }

    /// Moves tab `index` into `target` at `slot`, keeping its state; the last tab closes this window.
    func mergeTab(at index: Int, into target: BrowserWindowController, slot: Int) {
        guard target !== self, tabs.indices.contains(index), let tab = takeTab(at: index) else { return }
        target.adoptTab(tab, at: slot)
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// Tears tab `index` into a new window, its tab under `screenPoint` at `grabOffset` (from top-left).
    @discardableResult
    func tearOffTab(at index: Int, at screenPoint: NSPoint, grabOffset: NSPoint) -> BrowserWindowController? {
        guard tabs.count > 1, let tab = takeTab(at: index),
              let controller = (NSApp.delegate as? AppDelegate)?.openWindow(tabs: [tab]), let window = controller.window else { return nil }
        let rowTop = Theme.tabStripHeight - Theme.tabHeight
        window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - controller.tabStrip.leadingInset - grabOffset.x,
                                            y: screenPoint.y + rowTop + grabOffset.y))
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    // MARK: TabStripDelegate (drag)

    func tabStripTearOff(_ index: Int, at screenPoint: NSPoint, grabOffset: NSPoint) {
        if let target = tabMergeTarget(at: screenPoint) {
            mergeTab(at: index, into: target, slot: target.tabStrip.insertionSlot(atScreen: screenPoint))
        } else {
            tearOffTab(at: index, at: screenPoint, grabOffset: grabOffset)
        }
    }

    func tabStripDragWindow(with event: NSEvent) {
        guard let window else { return }
        let before = window.frame.origin
        window.performDrag(with: event)
        // A click without movement never merges, even when another window's tab row lies underneath.
        guard window.frame.origin != before else { return }
        let point = NSEvent.mouseLocation
        if let target = tabMergeTarget(at: point, below: window.windowNumber) {
            mergeTab(at: 0, into: target, slot: target.tabStrip.insertionSlot(atScreen: point))
        }
    }

    func tabStripDragHover(at screenPoint: NSPoint?) {
        let target = screenPoint.flatMap { tabMergeTarget(at: $0) }
        for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] where controller !== self {
            if controller === target, let point = screenPoint {
                controller.tabStrip.showDropMarker(at: controller.tabStrip.insertionSlot(atScreen: point))
            } else {
                controller.tabStrip.showDropMarker(at: nil)
            }
        }
    }
}

/// The tab scroll area: a vertical wheel or trackpad swipe scrolls the tabs sideways.
final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dy) > abs(dx) else { super.scrollWheel(with: event); return }
        let clip = contentView
        let step = event.hasPreciseScrollingDeltas ? dy : dy * 24
        let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(max(0, clip.bounds.minX - step), maxX), y: 0))
        reflectScrolledClipView(clip)
    }
}

/// A floating image of a tab that follows the pointer while the tab is dragged out of its strip.
final class TabDragGhost {
    private let panel: NSPanel
    private let grab: NSPoint

    /// `grab` is the pointer position inside `view` (flipped: y from the top). Nil when headless.
    init?(snapshotOf view: NSView, grab: NSPoint) {
        guard !AppDelegate.isHeadless, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        self.grab = grab
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.bounds.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.92
        let content = TabGhostView(image: image)
        content.frame = NSRect(origin: .zero, size: view.bounds.size)
        panel.contentView = content
        panel.orderFront(nil)
    }

    func move(to screenPoint: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - grab.x, y: screenPoint.y - (panel.frame.height - grab.y)))
    }

    func close() { panel.orderOut(nil) }
}

private final class TabGhostView: NSView {
    let image: NSImage
    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: TabStripView.feet, dy: 0)
        fillRounded(body, radius: Theme.tabCornerRadius, Theme.toolbarBackground)
        Theme.fieldBorder.setStroke()
        NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.tabCornerRadius, yRadius: Theme.tabCornerRadius).stroke()
        image.draw(in: bounds)
    }
}
