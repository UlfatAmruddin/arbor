import AppKit
import ArborCore

/// Mouse and trackpad navigation (FE-012, FE-016):
/// - Mouse buttons 4 and 5 (the side "Back"/"Forward" buttons; AppKit numbers them 3 and 4) go Back and Forward.
/// - A two-finger horizontal swipe goes Back/Forward when "Swipe between pages" is on in System Settings ▸
///   Trackpad, but only once the content under the pointer can't scroll further that way, so horizontal
///   scrolling in List view and wide Details columns keeps working. Three-finger swipes (when the system
///   is set to them) work too. Go ▸ Swipe to Navigate turns both off.
enum PointerNavigation {
    static let prefKey = "swipeNavigation"
    private static var monitors: [Any] = []

    static var swipeEnabled: Bool {
        get { Prefs.store.object(forKey: prefKey) as? Bool ?? true }
        set {
            Prefs.store.set(newValue, forKey: prefKey)
            NotificationCenter.default.post(name: Prefs.changed, object: nil, userInfo: ["key": prefKey])
        }
    }

    static func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown], handler: { handleButton($0) ? nil : $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.swipe], handler: { handleSwipe($0) ? nil : $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { handleScroll($0) ? nil : $0 }) { monitors.append(m) }
        CommandRegistry.shared.register(ExplorerCommand(
            id: "nav.swipeToNavigate", title: "Swipe to Go Back and Forward",
            placements: [.mainMenu("Go", .tools, 90)],
            state: { _ in swipeEnabled ? .on : .off },
            perform: { _ in swipeEnabled.toggle() }))
    }

    private static func controller(for event: NSEvent) -> BrowserWindowController? {
        (event.window?.windowController ?? NSApp.keyWindow?.windowController) as? BrowserWindowController ?? BrowserWindowController.active
    }

    /// Back/Forward mouse buttons. Returns true if handled.
    static func handleButton(_ event: NSEvent) -> Bool {
        guard let c = controller(for: event), c.window?.attachedSheet == nil else { return false }
        return navigate(c, button: event.buttonNumber)
    }

    @discardableResult
    static func navigate(_ c: BrowserWindowController, button: Int) -> Bool {
        switch button {
        case 3: c.goBack(); return true
        case 4: c.goForward(); return true
        default: return false
        }
    }

    static func go(_ direction: SwipeNavigation.Direction, in c: BrowserWindowController) {
        switch direction {
        case .back: c.goBack()
        case .forward: c.goForward()
        }
    }

    private static func handleSwipe(_ event: NSEvent) -> Bool {
        guard swipeEnabled, let c = controller(for: event), let direction = SwipeNavigation.direction(swipeDeltaX: Double(event.deltaX)) else { return false }
        go(direction, in: c)
        return true
    }

    private static func handleScroll(_ event: NSEvent) -> Bool {
        guard swipeEnabled, event.phase == .began, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              let c = controller(for: event), let window = c.window, window.attachedSheet == nil,
              let frame = window.contentView?.superview else { return false }
        let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        // Only over the file list or a page, not over the tree or the side pane.
        guard let hit, FocusRegions.region(of: hit, in: c) == .items else { return false }
        let scroll = hit.enclosingScrollView ?? (hit as? NSScrollView)
        var canLeft = false, canRight = false
        if let scroll, let document = scroll.documentView {
            let clip = scroll.contentView.bounds
            canLeft = clip.minX > 0.5
            canRight = clip.maxX < document.frame.width - 0.5
        }
        guard let direction = SwipeNavigation.decision(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
                                                       canScrollLeft: canLeft, canScrollRight: canRight) else { return false }
        let canGo = direction == .back ? c.history.canGoBack : c.history.canGoForward
        guard canGo else { return false }
        var navigated = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: direction == .forward ? -1 : 0,
                              max: direction == .back ? 1 : 0) { [weak c] amount, phase, _, _ in
            guard let c, !navigated, phase == .ended, abs(amount) >= 0.5 else { return }
            navigated = true
            go(direction, in: c)
        }
        return true
    }
}
