import AppKit

/// Colors and metrics for classic Windows property-sheet dialogs (Folder Options), drawn with original
/// shapes in Theme style. Light values approximate Windows 11's dialog surfaces; dark is our own variant.
enum DialogStyle {
    static let background = Theme.dynamic(light: 0xF0F0F0, dark: 0x202020)
    static let page = Theme.dynamic(light: 0xFFFFFF, dark: 0x2B2B2B)
    static let pageBorder = Theme.dynamic(light: 0xD9D9D9, dark: 0x464646)
    static let groupBorder = Theme.dynamic(light: 0xDCDCDC, dark: 0x4A4A4A)
    static let listBackground = Theme.dynamic(light: 0xFFFFFF, dark: 0x1F1F1F)
    static let listBorder = Theme.dynamic(light: 0xA0A0A0, dark: 0x5C5C5C)
    static let buttonFill = Theme.dynamic(light: 0xFDFDFD, dark: 0x373737)
    static let buttonHover = Theme.dynamic(light: 0xF3F3F3, dark: 0x3F3F3F)
    static let buttonPressed = Theme.dynamic(light: 0xE6E6E6, dark: 0x2F2F2F)
    static let buttonBorder = Theme.dynamic(light: 0xD0D0D0, dark: 0x4F4F4F)
    static let tabIdle = Theme.dynamic(light: 0xF0F0F0, dark: 0x262626)
    static let tabHover = Theme.dynamic(light: 0xF7F7F7, dark: 0x303030)

    static let font = NSFont.systemFont(ofSize: 12)
    static let noteFont = NSFont.systemFont(ofSize: 11)
    static let buttonHeight: CGFloat = 26
    static let buttonMinWidth: CGFloat = 82
}

/// Flat, rounded push button like a Windows 11 dialog button. The default button gets an accent border.
final class DialogButton: NSButton {
    var isDefaultButton = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(_ title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        font = DialogStyle.font
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: DialogStyle.font]).width + 28
        return NSSize(width: max(DialogStyle.buttonMinWidth, ceil(width)), height: DialogStyle.buttonHeight)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        let fill = !isEnabled ? DialogStyle.buttonFill : isHighlighted ? DialogStyle.buttonPressed : hovered ? DialogStyle.buttonHover : DialogStyle.buttonFill
        fill.setFill()
        path.fill()
        if isDefaultButton && isEnabled {
            Theme.accent.setStroke()
            path.lineWidth = 1.5
        } else {
            DialogStyle.buttonBorder.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
        let color = isEnabled ? Theme.primaryText : Theme.disabledText
        let attrs: [NSAttributedString.Key: Any] = [.font: DialogStyle.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

/// The tab row of a property sheet: left-aligned tabs; the selected one joins the page below it.
final class DialogTabBar: NSView {
    var titles: [String] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var hover: Int?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    private func tabRects() -> [NSRect] {
        var x: CGFloat = 0
        return titles.map { title in
            let width = ceil((title as NSString).size(withAttributes: [.font: DialogStyle.font]).width) + 22
            defer { x += width - 1 }
            return NSRect(x: x, y: 3, width: width, height: bounds.height - 3)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = tabRects()
        for (i, title) in titles.enumerated() {
            var r = rects[i]
            let isSelected = i == selected
            if isSelected { r = NSRect(x: r.minX - 1, y: 0, width: r.width + 2, height: bounds.height + 1) }
            let path = NSBezierPath()
            let radius: CGFloat = 3
            path.move(to: NSPoint(x: r.minX + 0.5, y: r.maxY))
            path.line(to: NSPoint(x: r.minX + 0.5, y: r.minY + radius))
            path.appendArc(withCenter: NSPoint(x: r.minX + radius + 0.5, y: r.minY + radius + 0.5), radius: radius, startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: r.maxX - radius - 0.5, y: r.minY + 0.5))
            path.appendArc(withCenter: NSPoint(x: r.maxX - radius - 0.5, y: r.minY + radius + 0.5), radius: radius, startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: r.maxX - 0.5, y: r.maxY))
            (isSelected ? DialogStyle.page : (hover == i ? DialogStyle.tabHover : DialogStyle.tabIdle)).setFill()
            path.fill()
            DialogStyle.pageBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: DialogStyle.font, .foregroundColor: Theme.primaryText]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 + (isSelected ? -1 : 0)), withAttributes: attrs)
        }
        // The page's top border, interrupted under the selected tab.
        DialogStyle.pageBorder.setFill()
        let y = bounds.height - 1
        let sel = rects.indices.contains(selected) ? rects[selected].insetBy(dx: -1, dy: 0) : .zero
        NSRect(x: 0, y: y, width: max(0, sel.minX + 1), height: 1).fill()
        NSRect(x: sel.maxX - 1, y: y, width: max(0, bounds.width - sel.maxX + 1), height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabRects().firstIndex(where: { $0.contains(p) }) { select(i) }
    }

    func select(_ index: Int) {
        guard titles.indices.contains(index) else { return }
        selected = index
        onSelect?(index)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = tabRects().firstIndex { $0.contains(p) }
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    // Keyboard: ⌃Tab / ⌃⇧Tab like Windows' Ctrl+Tab between property-sheet pages.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityValue() -> Any? { titles.indices.contains(selected) ? titles[selected] : nil }
}

/// The white page under the tab row, with its border (top border is drawn by the tab bar).
final class DialogPageView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DialogStyle.page.setFill()
        bounds.fill()
        DialogStyle.pageBorder.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A Windows group box: a thin rounded frame with its caption on the top edge, and an optional
/// illustration on the left (SF Symbols, original artwork).
final class GroupBoxView: NSView {
    let content = NSStackView()
    private let caption: NSTextField

    init(title: String, symbol: String?) {
        caption = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        caption.font = DialogStyle.font
        caption.textColor = Theme.primaryText
        caption.drawsBackground = true
        caption.backgroundColor = DialogStyle.page
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(caption)
        var leading: NSLayoutXAxisAnchor = leadingAnchor
        var leadingInset: CGFloat = 12
        if let symbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .light))
            icon.contentTintColor = Theme.accent
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                icon.topAnchor.constraint(equalTo: topAnchor, constant: 20),
                icon.widthAnchor.constraint(equalToConstant: 30),
                icon.heightAnchor.constraint(equalToConstant: 30),
            ])
            leading = icon.trailingAnchor
            leadingInset = 10
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            caption.topAnchor.constraint(equalTo: topAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: leading, constant: leadingInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let top = caption.frame.midY
        let rect = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: top - 0.5)
        let path = NSBezierPath(roundedRect: isFlipped ? rect.offsetBy(dx: 0, dy: bounds.height - top) : rect,
                                xRadius: 4, yRadius: 4)
        DialogStyle.groupBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// A one-pixel framed box (the Advanced settings list).
final class FramedView: NSView {
    var fill: NSColor = DialogStyle.listBackground
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        DialogStyle.listBorder.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

/// Solid background for the dialog window.
final class DialogBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DialogStyle.background.setFill()
        bounds.fill()
    }
}
