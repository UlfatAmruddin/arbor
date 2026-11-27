import AppKit

/// Row with Explorer-style hover and rounded selection instead of the Mac full-width blue bar.
final class ExplorerRowView: NSTableRowView {
    enum Style { case content, navigation }
    var style: Style = .content
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    /// Keep text dark on the light selection (no white "emphasized" text).
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// Focus apart from the selection (⌥⌘arrows) gets a thin accent outline.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard style == .content, let table = superview as? FileTableView, let focus = table.focusRow,
              table.row(for: self) == focus, SelectionEmphasis.hasFocus(table) else { return }
        Theme.accent.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        path.lineWidth = 1
        path.stroke()
    }

    /// Row icons are decoration: VoiceOver reads the name, not "image".
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? NSTableCellView)?.imageView?.hideFromAccessibility()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func prepareForReuse() { super.prepareForReuse(); isHovered = false }

    private var pill: NSRect {
        style == .navigation ? bounds.insetBy(dx: 6, dy: 1) : bounds.insetBy(dx: 4, dy: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected, isHovered else { return }
        fillRounded(pill, radius: Theme.cornerRadius, Theme.hover)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color: NSColor
        switch style {
        case .navigation:
            color = SelectionEmphasis.windowIsActive(window) ? Theme.navSelection : SelectionEmphasis.navInactive
        case .content:
            // Same rule as other views (SelectionEmphasis), also in headless snapshots.
            let focused = superview.map(SelectionEmphasis.hasFocus) ?? isEmphasized
            color = SelectionEmphasis.fill(focused: focused, hovered: isHovered)
        }
        fillRounded(pill, radius: Theme.cornerRadius, color)
        if style == .content { Theme.strokeSelectionIfContrast(pill, radius: Theme.cornerRadius) }   // Increase contrast (FE-201)
        if style == .navigation {
            // Accent bar at the left of the current location (windows11-reference.md §2.1).
            let bar = NSRect(x: pill.minX, y: pill.midY - 8, width: 3, height: 16)
            fillRounded(bar, radius: 1.5, SelectionEmphasis.windowIsActive(window) ? Theme.accent : SelectionEmphasis.inactiveMark)
        }
    }
}
