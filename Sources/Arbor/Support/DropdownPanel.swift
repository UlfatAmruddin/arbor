import AppKit
import ArborCore

/// A rounded panel hanging under a view. Never takes keyboard focus, so the field above keeps typing.
final class DropdownPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class Background: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            fillRounded(rect, radius: 8, Theme.fieldBackground)
            Theme.fieldBorder.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).stroke()
        }
    }

    private let panel: Panel

    init(content: NSView, accessibilityLabel: String) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        let background = Background()
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(accessibilityLabel)
        panel.contentView = background
        if AppDelegate.isHeadless {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        }
    }

    var contentView: NSView? { panel.contentView }
    var window: NSWindow { panel }
    var isVisible: Bool { panel.parent != nil }

    func show(below anchor: NSView) {
        guard let parent = anchor.window else { hide(); return }
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? .zero
        let height = max(size.height, 40)
        panel.setFrame(NSRect(x: anchorRect.minX, y: anchorRect.minY - height - 4, width: anchorRect.width, height: height), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For scripted checks; false when there is nothing laid out to draw.
    func writeSnapshot(to path: String) -> Bool {
        guard let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return true
    }
}
