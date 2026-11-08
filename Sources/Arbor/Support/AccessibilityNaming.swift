import AppKit

extension NSView {
    /// Hides a decorative image (an icon next to a name VoiceOver already reads) from the accessibility tree.
    /// AppKit can expose a control through its cell, so the cell is hidden too.
    func hideFromAccessibility() {
        setAccessibilityElement(false)
        (self as? NSControl)?.cell?.setAccessibilityElement(false)
    }

    /// Names a control for VoiceOver, on the cell as well (see `hideFromAccessibility`).
    func setAccessibleName(_ name: String) {
        setAccessibilityLabel(name)
        (self as? NSControl)?.cell?.setAccessibilityLabel(name)
    }
}
