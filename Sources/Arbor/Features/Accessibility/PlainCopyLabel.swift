import AppKit
import ArborCore

/// A selectable label that may show direction marks (FE-204): what is copied or dragged out of it has none.
final class PlainCopyLabel: NSTextField {
    fileprivate lazy var copyEditor: NSTextView = {
        let editor = PlainCopyEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    // The editor lives on the label because AppKit copies cells bitwise, which a stored reference wouldn't survive.
    private final class Cell: NSTextFieldCell {
        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            (controlView as? PlainCopyLabel)?.copyEditor ?? super.fieldEditor(for: controlView)
        }
    }

    private final class PlainCopyEditor: NSTextView {
        override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            pasteboard.declareTypes([.string], owner: nil)
            return pasteboard.setString(BidiText.withoutIsolates((string as NSString).substring(with: selectedRange())), forType: .string)
        }
    }
}
