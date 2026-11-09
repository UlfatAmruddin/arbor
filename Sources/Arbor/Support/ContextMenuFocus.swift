import AppKit

extension NSView {
    /// A text field in this view has focus: an inline rename.
    var isEditingTextInside: Bool { (window?.firstResponder as? NSTextView)?.isDescendant(of: self) == true }

    /// AppKit moves focus on left-click only, and a field elsewhere would hide Services. A rename in this view stays open.
    func takeFocusForContextMenu() {
        if !isEditingTextInside { window?.makeFirstResponder(self) }
    }
}
