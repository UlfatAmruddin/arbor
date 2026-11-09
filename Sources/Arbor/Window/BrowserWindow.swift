import AppKit

/// Full-size content under a transparent title bar, traffic lights in the tab row, window key bindings.
final class BrowserWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        minSize = NSSize(width: 780, height: 440)
        tabbingMode = .disallowed
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        backgroundColor = Theme.tabStripBackground
    }

    /// Centers the traffic lights vertically in the tab row (AppKit resets them on resize).
    func layoutTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton), let container = close.superview?.superview else { return }
        let height = Theme.tabStripHeight
        var frame = container.frame
        if frame.height != height || frame.minY != self.frame.height - height {
            frame.size.height = height
            frame.origin.y = self.frame.height - height
            container.frame = frame
        }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            let y = ((button.superview?.bounds.height ?? height) - button.frame.height) / 2
            if abs(button.frame.minY - y) > 0.5 { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    /// Window-scope command bindings; while editing text only those using ⌘ or ⌃.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let controller = windowController as? BrowserWindowController {
            if let command = CommandRegistry.shared.command(for: event, scope: .window) {
                let mods = event.modifierFlags.intersection([.command, .control])
                if !controller.isEditingText || !mods.isEmpty {
                    let context = controller.context(surface: .keyboard, sender: nil)
                    if command.isAvailable(context), command.isEnabled(context) {
                        command.perform(context)
                        return true
                    }
                }
            }
            if !controller.isEditingText, let command = CommandRegistry.shared.locationCommand(forShortcut: event),
               CommandDispatcher.shared.refuseIfLocationBlocks(command, controller.context(surface: .keyboard, sender: nil)) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌃Tab never reaches performKeyEquivalent on some systems; catch it before the key view loop.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.contains(.control), event.keyCode == 48,
           performKeyEquivalent(with: event) { return }
        super.sendEvent(event)
    }
}
