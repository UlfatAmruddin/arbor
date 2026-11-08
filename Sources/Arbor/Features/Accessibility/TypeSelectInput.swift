import AppKit
import ArborCore

/// Text input client for type-to-select in the file lists, so CJK names can be typed (FE-068).
/// While composing, every key belongs to the input method (arrows pick candidates, not rows).
final class TypeSelectInput: NSObject, NSTextInputClient {
    private weak var view: NSView?
    private let onCommit: (String) -> Void
    private lazy var context = NSTextInputContext(client: self)
    private(set) var markedText = ""
    /// The last key reached `doCommand(by:)` without being used: the list handles it itself.
    private var passedThrough = false
    private lazy var box = CompositionBox()

    /// `onCommit` gets each committed piece: a letter or a whole composed word.
    init(view: NSView, onCommit: @escaping (String) -> Void) {
        self.view = view
        self.onCommit = onCommit
    }

    /// Routes a key: true when the input method took it (the list must not handle it again).
    func handle(_ event: NSEvent, typeSelectActive: Bool) -> Bool {
        let mods = event.modifierFlags
        guard TypeSelectRouting.goesToInputMethod(characters: event.characters, command: mods.contains(.command),
                                                  control: mods.contains(.control), typeSelectActive: typeSelectActive,
                                                  composing: hasMarkedText()) else { return false }
        if NSTextInputContext.current !== context { context.activate() }
        passedThrough = false
        let handled = context.handleEvent(event)
        return hasMarkedText() || (handled && !passedThrough)
    }

    /// Focus left the list: drop any composition, like a text field losing focus.
    func reset() {
        guard hasMarkedText() || NSTextInputContext.current === context else { return }
        context.discardMarkedText()
        setMarked("")
        if NSTextInputContext.current === context { context.deactivate() }
    }

    /// Scripted checks: what an input method does while composing and when committing.
    func scriptCompose(_ text: String) { setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                                       replacementRange: NSRange(location: NSNotFound, length: 0)) }
    func scriptCommit(_ text: String) { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        setMarked("")
        if !text.isEmpty { onCommit(text) }
    }

    func doCommand(by selector: Selector) {
        guard hasMarkedText() else { passedThrough = true; return }
        // Without an input method of its own (scripted composition), Return accepts and Escape cancels.
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): unmarkText()
        case #selector(NSResponder.cancelOperation(_:)): setMarked("")
        case #selector(NSResponder.deleteBackward(_:)): setMarked(String(markedText.dropLast()))
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setMarked((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
    }

    func unmarkText() {
        let text = markedText
        setMarked("")
        if !text.isEmpty { onCommit(text) }
    }

    func selectedRange() -> NSRange { NSRange(location: (markedText as NSString).length, length: 0) }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: (markedText as NSString).length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method puts its candidate window: just below the composition box.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let view, let window = view.window else { return .zero }
        let anchor = box.superview != nil ? box.convert(box.bounds, to: nil) : view.convert(view.visibleRect, to: nil)
        return window.convertToScreen(NSRect(x: anchor.minX, y: anchor.minY, width: max(anchor.width, 1), height: anchor.height))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Composition box

    fileprivate var ownerView: NSView? { view }

    private func setMarked(_ text: String) {
        markedText = text
        if !text.isEmpty { Self.noteComposing(self) }
        guard let view else { return }
        if text.isEmpty {
            box.removeFromSuperview()
            return
        }
        let host = view.enclosingScrollView ?? view
        if box.superview !== host { host.addSubview(box) }
        box.text = text
        let size = box.fittingSize
        // Below the column headers, at the top left of the items.
        let visible = (host as? NSScrollView)?.contentView.frame ?? view.visibleRect
        let header = (view as? NSTableView)?.headerView?.frame.height ?? 0
        let y = host.isFlipped ? visible.minY + header + 6 : visible.maxY - header - size.height - 6
        box.frame = NSRect(x: visible.minX + 8, y: y, width: size.width, height: size.height)
    }

    /// Debug/log text: the composition shown, if any.
    var debugText: String { hasMarkedText() ? "composing \"\(markedText)\"" : "idle" }
}

/// The marked (uncommitted) text, underlined, in a small bordered box.
final class CompositionBox: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String = "" {
        didSet {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: Theme.listFont, .foregroundColor: Theme.primaryText,
                .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Theme.accent,
            ])
            setAccessibilityValue(text)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel(L10n.tr("Type to select"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        Theme.fieldBackground.setFill()
        path.fill()
        Theme.fieldBorder.setStroke()
        path.stroke()
    }
}

/// Details type-to-select: `TypeSelect` rules on committed IME text, not NSTableView's raw-key version.
final class ListTypeSelect {
    private var buffer = TypeSelect()
    private let names: () -> [String]
    private let current: () -> Int?
    private let select: (Int) -> Void
    private(set) var input: TypeSelectInput!

    init(view: NSView, names: @escaping () -> [String], current: @escaping () -> Int?, select: @escaping (Int) -> Void) {
        self.names = names
        self.current = current
        self.select = select
        input = TypeSelectInput(view: view) { [weak self] text in self?.commit(text) }
    }

    /// While the input method is composing, every key is its own (checked before the list's shortcuts).
    func handleWhileComposing(_ event: NSEvent) -> Bool {
        input.hasMarkedText() && input.handle(event, typeSelectActive: true)
    }

    /// Typed text after the list's own keys had their chance.
    func handle(_ event: NSEvent) -> Bool {
        input.handle(event, typeSelectActive: buffer.isActive(at: Date()))
    }

    func reset() { input.reset() }

    private func commit(_ text: String) {
        guard let index = buffer.input(text, at: Date(), names: names(), current: current()) else { NSSound.beep(); return }
        select(index)
    }
}

extension TypeSelectInput {
    /// The list whose type-to-select text is being composed, if any (the app-wide key monitor defers to it).
    private static weak var composingInput: TypeSelectInput?

    static func isComposing(in view: NSView) -> Bool {
        guard let input = composingInput, input.hasMarkedText() else { return false }
        return input.owner === view
    }

    var owner: NSView? { ownerView }

    static func noteComposing(_ input: TypeSelectInput) { composingInput = input }
}
