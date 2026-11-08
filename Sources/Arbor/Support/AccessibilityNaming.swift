import AppKit

extension NSView {
    /// Hides a decorative image from accessibility, cell too (AppKit may expose a control through it).
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
