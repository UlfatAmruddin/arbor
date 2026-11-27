import AppKit

/// A rubber-band drag for the marquee script steps: `x1,y1,x2,y2[:cmd|shift][:holdSeconds][:queued]`.
struct ScriptedMarquee {
    let start: CGPoint
    let end: CGPoint
    let flags: NSEvent.ModifierFlags
    let hold: Double
    /// Delivers the press through the event queue, so local event monitors see it and the script runs on during a hold.
    let queued: Bool

    init?(_ argument: String) {
        let parts = argument.components(separatedBy: ":")
        let numbers = parts[0].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite) else { return nil }
        start = CGPoint(x: numbers[0], y: numbers[1])
        end = CGPoint(x: numbers[2], y: numbers[3])
        flags = parts.count > 1 ? Self.modifiers(parts[1]) : []
        hold = parts.count > 2 ? max(Double(parts[2]) ?? 0, 0) : 0
        queued = parts.count > 3 && parts[3] == "queued"
    }

    private static func modifiers(_ text: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if text.contains("cmd") { flags.insert(.command) }
        if text.contains("shift") { flags.insert(.shift) }
        return flags
    }

    /// Runs the drag with its points offset by `origin`; returns the script's pause before the next step.
    func run(in view: NSView, origin: CGPoint) -> TimeInterval {
        let from = CGPoint(x: origin.x + start.x, y: origin.y + start.y)
        // Drag events use window coordinates now; the view may scroll meanwhile.
        let windowFrom = view.convert(from, to: nil)
        let windowTo = view.convert(CGPoint(x: origin.x + end.x, y: origin.y + end.y), to: nil)
        guard let window = view.window, let down = ScriptedMouse.event(.leftMouseDown, in: window, at: windowFrom, flags: flags) else { return 0.3 }
        if queued { NSApp.postEvent(down, atStart: false) }
        for step in 1...4 {
            let t = CGFloat(step) / 4
            let point = NSPoint(x: windowFrom.x + (windowTo.x - windowFrom.x) * t, y: windowFrom.y + (windowTo.y - windowFrom.y) * t)
            if let drag = ScriptedMouse.event(.leftMouseDragged, in: window, at: point, flags: flags) { NSApp.postEvent(drag, atStart: false) }
        }
        let postUp = { [flags] in
            if let up = ScriptedMouse.event(.leftMouseUp, in: window, at: windowTo, flags: flags) { NSApp.postEvent(up, atStart: false) }
        }
        if hold > 0 {
            // A run-loop timer fires in the tracking loop; a main-queue block would wait until this step ends.
            RunLoop.main.add(Timer(timeInterval: hold, repeats: false) { _ in postUp() }, forMode: .common)
        } else {
            postUp()
        }
        if queued { return 0.3 }
        view.mouseDown(with: down)
        return 0.5 + hold
    }
}
