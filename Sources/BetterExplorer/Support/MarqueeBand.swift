import AppKit

/// The rubber band every layout draws (FE-058).
enum MarqueeBand {
    static func draw(_ rect: CGRect) {
        guard rect.width > 0 || rect.height > 0 else { return }
        Theme.accent.withAlphaComponent(0.16).setFill()
        rect.fill(using: .sourceOver)
        Theme.accent.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

/// Overlay for views that draw through subviews: a table's row views would cover anything drawn in the table itself.
final class MarqueeBandView: NSView {
    var band: CGRect? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let band { MarqueeBand.draw(band) }
    }
}
