import AppKit
import ArborCore

/// Keyboard focus regions of a browser window (FE-062, FE-199): F6 / Shift+F6 and Tab / Shift+Tab move
/// between tabs, address bar, search box, command bar, navigation pane, items and side pane, in
/// Explorer's order. Inside the tab strip and the command bar, arrow keys move between buttons
/// (one Tab stop per toolbar, like Windows); pages with several sections (Home) keep their own Tab order
/// before focus moves on (DEC-accessibility-2).
enum FocusRegions {
    /// True while a keyboard command moves focus, so flat chrome buttons accept it then and only then
    /// (a mouse click on a command bar button must not take focus away from the file list).
    static var movingFocus = false

    // MARK: Where focus is

    /// The view that has focus: a text field rather than its field editor.
    static func focusedView(in window: NSWindow?) -> NSView? {
        guard let responder = window?.firstResponder else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return responder as? NSView
    }

    static func region(of view: NSView?, in c: BrowserWindowController) -> FocusRegion? {
        guard let view, view.window === c.window else { return nil }
        if view.isDescendant(of: c.tabStrip) { return .tabs }
        if view.isDescendant(of: c.addressBar) { return .address }
        if view.isDescendant(of: c.searchBox) { return .search }
        if view.isDescendant(of: c.commandBar) { return .commandBar }
        if view.isDescendant(of: c.navPane.view) { return .navigationPane }
        if view.isDescendant(of: c.sidePane) { return .sidePane }
        if let content = contentView(of: c), view.isDescendant(of: content) { return .items }
        return nil
    }

    static func current(in c: BrowserWindowController) -> FocusRegion? { region(of: focusedView(in: c.window), in: c) }

    /// The item view, or the page (Home, This Mac, Gallery…) on screen.
    static func contentView(of c: BrowserWindowController) -> NSView? {
        if !c.tabs.isEmpty, c.activeTab.showsPage, let page = c.activeTab.page, page.view.window != nil { return page.view }
        if let view = c.itemView?.view, !view.isHidden { return view }
        return nil
    }

    static func available(in c: BrowserWindowController) -> Set<FocusRegion> {
        var set: Set<FocusRegion> = [.tabs, .address, .search, .items]
        if !commandButtons(in: c).isEmpty { set.insert(.commandBar) }
        if !c.navPane.view.isHidden, c.navPane.view.window != nil { set.insert(.navigationPane) }
        if !c.sidePane.isHidden, !keyViews(in: c.sidePane).isEmpty { set.insert(.sidePane) }
        return set
    }

    // MARK: Moving focus

    /// F6 / Shift+F6.
    @discardableResult
    static func cycle(_ c: BrowserWindowController, forward: Bool) -> FocusRegion? {
        let from = current(in: c)
        let available = available(in: c)
        var target = FocusCycle.next(from: from, forward: forward, available: available)
        // A region that can't take focus right now (empty page) is skipped.
        var tries = 0
        while let region = target, !focus(region, in: c, fromEnd: !forward), tries < FocusRegion.allCases.count {
            target = FocusCycle.next(from: region, forward: forward, available: available)
            tries += 1
        }
        if let target { Announcer.focusMoved(to: target, in: c) }
        return target
    }

    /// Tab / Shift+Tab: the next stop inside a page or pane with several (Home sections, Details pane
    /// fields), else the next region.
    static func tab(_ c: BrowserWindowController, forward: Bool) {
        if let view = focusedView(in: c.window), let region = region(of: view, in: c),
           region == .items || region == .sidePane,
           let container = region == .items ? contentView(of: c) : c.sidePane {
            let stops = keyViews(in: container)
            if let index = stops.firstIndex(where: { view === $0 || view.isDescendant(of: $0) }) {
                let next = index + (forward ? 1 : -1)
                if stops.indices.contains(next) {
                    makeFocused(stops[next], in: c.window)
                    return
                }
            }
        }
        cycle(c, forward: forward)
    }

    @discardableResult
    static func focus(_ region: FocusRegion, in c: BrowserWindowController, fromEnd: Bool = false) -> Bool {
        guard let window = c.window else { return false }
        switch region {
        case .tabs:
            guard let tab = tabViews(in: c).first(where: \.isSelected) else { return false }
            return makeFocused(tab, in: window)
        case .address:
            c.focusAddressBar()
            return true
        case .search:
            c.focusSearch()
            return true
        case .commandBar:
            guard let first = commandButtons(in: c).first else { return false }
            return makeFocused(first, in: window)
        case .navigationPane:
            guard !c.navPane.view.isHidden else { return false }
            return window.makeFirstResponder(c.navPane.outline)
        case .items:
            if let page = contentView(of: c), c.activeTab.showsPage {
                let stops = keyViews(in: page)
                guard let stop = fromEnd ? stops.last : stops.first else { return false }
                return makeFocused(stop, in: window)
            }
            guard let view = c.itemView else { return false }
            view.focus()
            return window.firstResponder === view.focusView
        case .sidePane:
            let stops = keyViews(in: c.sidePane)
            guard let stop = fromEnd ? stops.last : stops.first else { return false }
            return makeFocused(stop, in: window)
        }
    }

    @discardableResult
    static func makeFocused(_ view: NSView, in window: NSWindow?) -> Bool {
        movingFocus = true
        defer { movingFocus = false }
        let ok = window?.makeFirstResponder(view) ?? false
        view.needsDisplay = true
        return ok
    }

    // MARK: Stops

    static func tabViews(in c: BrowserWindowController) -> [TabItemView] {
        descendants(of: c.tabStrip, as: TabItemView.self).sorted { $0.index < $1.index }
    }

    /// Command bar buttons in visual order (visible and enabled).
    static func commandButtons(in c: BrowserWindowController) -> [ChromeButton] {
        visibleButtons(in: c.commandBar)
    }

    static func visibleButtons(in container: NSView) -> [ChromeButton] {
        descendants(of: container, as: ChromeButton.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled && $0.frame.width > 0 }
            .sorted { frameInWindow($0).minX < frameInWindow($1).minX }
    }

    /// Views in a container that take keyboard focus, in reading order (rows top to bottom, then left to right).
    static func keyViews(in container: NSView) -> [NSView] {
        var result: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            let focusable = (view as? ChromeButton).map { $0.isEnabled } ?? (view.acceptsFirstResponder && view.canBecomeKeyView)
            let isLabel = (view as? NSTextField).map { !$0.isEditable && !$0.isSelectable } ?? false
            if view !== container, focusable, !isLabel, !(view is NSTextView) {
                result.append(view)
                return   // a list or grid is one stop; its rows are reached with arrows
            }
            view.subviews.forEach(walk)
        }
        walk(container)
        return result.sorted {
            let a = frameInWindow($0), b = frameInWindow($1)
            if abs(a.maxY - b.maxY) > 4 { return a.maxY > b.maxY }
            return a.minX < b.minX
        }
    }

    static func frameInWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var result: [T] = []
        for sub in view.subviews {
            if let match = sub as? T { result.append(match) }
            result += descendants(of: sub, as: type)
        }
        return result
    }

    // MARK: Composite toolbars: arrows move between buttons

    /// Left/Right/Home/End inside the tab strip or the command bar. Returns true if handled.
    static func moveWithinToolbar(_ c: BrowserWindowController, keyCode: UInt16) -> Bool {
        guard let view = focusedView(in: c.window), let region = region(of: view, in: c) else { return false }
        let rtl = c.window?.contentView?.userInterfaceLayoutDirection == .rightToLeft
        var step: Int
        switch keyCode {
        case 123: step = rtl ? 1 : -1
        case 124: step = rtl ? -1 : 1
        case 115: step = Int.min
        case 119: step = Int.max
        default: return false
        }
        switch region {
        case .tabs:
            // Tabs first, then the New tab button.
            var stops: [NSView] = tabViews(in: c)
            stops.append(c.tabStrip.plusButton)
            guard let index = stops.firstIndex(where: { $0 === view }) else { return false }
            let target = step == Int.min ? 0 : (step == Int.max ? stops.count - 1 : min(max(index + step, 0), stops.count - 1))
            if target == index { NSSound.beep(); return true }
            if let tab = stops[target] as? TabItemView {
                // Moving along the tabs selects them (Ctrl+Tab does the same); focus follows.
                c.selectTab(at: tab.index)
                if let selected = tabViews(in: c).first(where: \.isSelected) { makeFocused(selected, in: c.window) }
            } else {
                makeFocused(stops[target], in: c.window)
            }
            return true
        case .commandBar:
            let stops = commandButtons(in: c)
            guard let index = stops.firstIndex(where: { $0 === view }) else { return false }
            let target = step == Int.min ? 0 : (step == Int.max ? stops.count - 1 : (index + step + stops.count) % stops.count)
            makeFocused(stops[target], in: c.window)
            return true
        default:
            return false
        }
    }
}

// MARK: - Focus visual (windows11-reference §15: two-ring rectangle on keyboard focus only)

enum FocusVisual {
    /// Draws Explorer's keyboard focus rectangle inside `rect`: an outer ring in the text color and an
    /// inner ring in the background color, so it shows on any fill.
    static func draw(in rect: NSRect, radius: CGFloat) {
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius + 1, yRadius: radius + 1)
        outer.lineWidth = Theme.increasedContrast ? 2.5 : 2
        Theme.primaryText.setStroke()
        outer.stroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        inner.lineWidth = 1
        Theme.contentBackground.setStroke()
        inner.stroke()
    }
}

// MARK: - Keyboard focus for the flat chrome views

extension ChromeButton {
    var hasKeyboardFocus: Bool { window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    /// Drop-down buttons (New ▾, breadcrumb chevrons, See more) are menu buttons for VoiceOver.
    override func accessibilityRole() -> NSAccessibility.Role? {
        let base = super.accessibilityRole()
        return base == .button && (onPress != nil || showsMenuIndicator) ? .menuButton : base
    }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformShowMenu() -> Bool {
        guard onPress != nil else { return false }
        performClick()
        return true
    }
}

extension TabItemView {
    override var acceptsFirstResponder: Bool { FocusRegions.movingFocus || window?.firstResponder === self }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    var hasKeyboardFocus: Bool { window?.firstResponder === self }
}
