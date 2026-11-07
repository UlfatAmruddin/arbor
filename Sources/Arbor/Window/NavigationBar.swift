import AppKit
import ArborCore

/// Explorer search box: rounded field, "Search <location>", magnifier at the right,
/// accent underline while focused. Calls the window's `SearchController`.
final class SearchBox: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    let field = NSTextField()
    private let clearButton = ChromeButton(symbol: "xmark", tooltip: "Clear search")
    private let magnifier = NSImageView()
    private var isFocused = false { didSet { needsDisplay = true } }

    var placeholder: String = "Search" {
        didSet {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: Theme.secondaryText, .font: Theme.bodyFont,
            ])
            field.setAccessibilityLabel(placeholder)
        }
    }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; clearButton.isHidden = newValue.isEmpty }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.bodyFont
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        magnifier.contentTintColor = Theme.secondaryText
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        clearButton.symbolSize = 9
        clearButton.fixedWidth = 22
        clearButton.fixedHeight = 22
        clearButton.isHidden = true
        clearButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.text = ""
            self.onChange?("")
        }
        [field, magnifier, clearButton].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.fieldHeight),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            clearButton.trailingAnchor.constraint(equalTo: magnifier.leadingAnchor, constant: -2),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            magnifier.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        placeholder = "Search"
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { focus() }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        fillRounded(rect, radius: Theme.cornerRadius, Theme.fieldBackground)
        Theme.fieldBorder.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        border.stroke()
        if isFocused {
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 0, width: bounds.width - 2, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { isFocused = true }
    func controlTextDidEndEditing(_ obj: Notification) { isFocused = false }

    func controlTextDidChange(_ obj: Notification) {
        clearButton.isHidden = field.stringValue.isEmpty
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            onSubmit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !field.stringValue.isEmpty {
                text = ""
                onChange?("")
            } else {
                window?.makeFirstResponder(nil)
            }
            return true
        default:
            return false
        }
    }
}

/// Explorer's navigation row: Back, Forward, Up, the address bar, and the search box.
final class NavigationBar: ThemeBackgroundView {
    let back = ChromeButton(symbol: "arrow.left", tooltip: "Back (⌘[ or Delete)")
    let forward = ChromeButton(symbol: "arrow.right", tooltip: "Forward (⌘])")
    let up = ChromeButton(symbol: "arrow.up", tooltip: "Up to the parent folder (⌘↑)")
    let address = AddressBar()
    let search = SearchBox()

    init() {
        super.init(Theme.toolbarBackground)
        setAccessibilityElement(false)
        for (button, label) in [(back, "Back"), (forward, "Forward"), (up, "Up")] {
            button.fixedWidth = 34
            button.symbolSize = 14
            button.setAccessibilityLabel(label)
        }
        let stack = NSStackView(views: [back, forward, up, address, search])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setCustomSpacing(10, after: up)
        stack.setCustomSpacing(8, after: address)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        address.setContentHuggingPriority(.init(1), for: .horizontal)
        address.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let searchWidth = search.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.24)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.navRowHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchWidth,
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            search.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
