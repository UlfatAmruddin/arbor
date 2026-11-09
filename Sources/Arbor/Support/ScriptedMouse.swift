import AppKit

/// Real mouse events for script steps, so scripted input takes the same path as the user's.
enum ScriptedMouse {
    /// A mouse event at a point in `view`.
    static func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint, flags: NSEvent.ModifierFlags = [],
                      count: Int = 1) -> NSEvent? {
        guard let window = view.window else { return nil }
        return event(type, in: window, at: view.convert(point, to: nil), flags: flags, count: count)
    }

    /// A mouse event at a point in window coordinates.
    static func event(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint, flags: NSEvent.ModifierFlags = [],
                      count: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
    }

    /// Queues a press and release at a point in window coordinates.
    static func postClick(in window: NSWindow, at point: NSPoint, count: Int = 1) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let click = event(type, in: window, at: point, count: count) { NSApp.postEvent(click, atStart: false) }
        }
    }
}
