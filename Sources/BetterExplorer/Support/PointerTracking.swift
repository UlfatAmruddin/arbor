import AppKit

/// The mouse-tracking loops item views share (FE-058).
enum PointerTracking {
    enum PressOutcome {
        case dragged(NSEvent)
        case released(NSEvent)
        /// The view left its window while the button was down.
        case abandoned
    }

    /// Movement before a press counts as a drag.
    private static let dragThreshold: CGFloat = 4

    /// Waits for the pointer to pass the drag threshold or the button to come up.
    static func awaitDrag(in view: NSView, from down: NSEvent) -> PressOutcome {
        let start = down.locationInWindow
        while let next = view.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return .released(next) }
            let point = next.locationInWindow
            if hypot(point.x - start.x, point.y - start.y) > dragThreshold { return .dragged(next) }
        }
        return .abandoned
    }

    /// Puts a consumed mouse-up back first in the queue, so native tracking of the same press sees a whole click.
    static func replayRelease(_ up: NSEvent) { NSApp.postEvent(up, atStart: true) }

    /// Follows a marquee until mouse-up; periodic events keep it scrolling while the pointer rests outside the view.
    static func followMarquee(in view: NSView, from start: NSEvent, alreadyMoved: Bool,
                              moved: (NSPoint) -> Void, autoscroll: (NSPoint) -> Bool) {
        NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.04)
        defer { NSEvent.stopPeriodicEvents() }
        var last = start.locationInWindow
        var hasMoved = alreadyMoved
        while let next = view.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            switch next.type {
            case .leftMouseUp:
                return
            case .leftMouseDragged:
                last = next.locationInWindow
                hasMoved = true
                moved(last)
            default:
                if hasMoved, autoscroll(last) { moved(last) }
            }
        }
    }
}
