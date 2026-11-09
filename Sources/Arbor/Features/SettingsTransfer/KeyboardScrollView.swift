import AppKit

/// A read-only list that takes focus and scrolls from the keyboard; a plain NSScrollView declines focus.
final class KeyboardScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    // NSScrollView otherwise declines, and the window takes the focus instead.
    override func becomeFirstResponder() -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    /// Other keys go up the chain, or Escape would never reach the sheet's Cancel button.
    override func keyDown(with event: NSEvent) {
        guard let target = targetOffset(for: event.specialKey) else { return super.keyDown(with: event) }
        scrollVertically(to: target)
    }

    private func targetOffset(for key: NSEvent.SpecialKey?) -> CGFloat? {
        let current = contentView.bounds.minY
        let page = contentView.bounds.height - verticalPageScroll
        switch key {
        case .upArrow: return current - verticalLineScroll
        case .downArrow: return current + verticalLineScroll
        case .pageUp: return current - page
        case .pageDown: return current + page
        case .home: return 0
        case .end: return .greatestFiniteMagnitude
        default: return nil
        }
    }

    /// The document is flipped, so zero is its first row.
    private func scrollVertically(to offset: CGFloat) {
        guard let document = documentView else { return }
        let last = max(0, document.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(max(offset, 0), last)))
        reflectScrolledClipView(contentView)
    }
}
