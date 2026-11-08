import AppKit
import ArborCore

/// Windows-style property sheet colors and controls, self-drawn so light, dark and snapshots match (DEC-018).
enum SheetColors {
    static let windowBackground = Theme.dynamic(light: 0xF0F0F0, dark: 0x202020)
    static let panelBackground = Theme.dynamic(light: 0xFFFFFF, dark: 0x2B2B2B)
    static let panelBorder = Theme.dynamic(light: 0xD9D9D9, dark: 0x3D3D3D)
    static let separator = Theme.dynamic(light: 0xE5E5E5, dark: 0x3A3A3A)
    static let buttonFill = Theme.dynamic(light: 0xFDFDFD, dark: 0x373737)
    static let buttonBorder = Theme.dynamic(light: 0xD0D0D0, dark: 0x454545)
    static let buttonHover = Theme.dynamic(light: 0xF5F5F5, dark: 0x3C3C3C)
    static let checkBorder = Theme.dynamic(light: 0x8A8A8A, dark: 0x9A9A9A)
    static let fieldBorder = Theme.dynamic(light: 0xC8C8C8, dark: 0x4A4A4A)
    static let fieldBackground = Theme.dynamic(light: 0xFFFFFF, dark: 0x1F1F1F)
    static let usedSpace = Theme.dynamic(light: 0x2B78E4, dark: 0x4C9BF0)
    static let freeSpace = Theme.dynamic(light: 0xD6D6D6, dark: 0x5A5A5A)
    static let success = Theme.dynamic(light: 0x0F7B0F, dark: 0x6CCB5F)
    static let failure = Theme.dynamic(light: 0xC42B1C, dark: 0xFF99A4)
    static var accent: NSColor { .controlAccentColor }
    /// Text on an accent fill: white in light mode, near-black in dark (Windows 11's accent buttons).
    static let onAccent = NSColor(name: nil) { Theme.isDark($0) ? Theme.rgb(0x000000) : .white }

    static let font = NSFont.systemFont(ofSize: 12)
    static let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let smallFont = NSFont.systemFont(ofSize: 11)
}

// MARK: - Labels

enum SheetLabel {
    static func make(_ text: String, secondary: Bool = false, bold: Bool = false, selectable: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? SheetColors.boldFont : SheetColors.font
        label.textColor = secondary ? Theme.secondaryText : Theme.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.isSelectable = selectable
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func wrapping(_ text: String, secondary: Bool = true, small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = small ? SheetColors.smallFont : SheetColors.font
        label.textColor = secondary ? Theme.secondaryText : Theme.primaryText
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

// MARK: - Button

/// A Windows 11 push button: rounded, hairline border; the default button is filled with the accent.
final class SheetButton: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) } }
    var isDefault = false { didSet { needsDisplay = true } }
    var onClick: ((SheetButton) -> Void)?
    var minWidth: CGFloat = 76
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init(_ title: String, isDefault: Bool = false, onClick: ((SheetButton) -> Void)? = nil) {
        self.title = title
        self.isDefault = isDefault
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: SheetColors.font]).width + 24
        return NSSize(width: max(minWidth, ceil(w)), height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside { performClick(nil) }
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        onClick?(self)
    }

    override func accessibilityPerformPress() -> Bool { performClick(nil); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { performClick(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let accentFill = isDefault && isEnabled
        if accentFill {
            (pressed ? SheetColors.accent.withAlphaComponent(0.8) : hovered ? SheetColors.accent.withAlphaComponent(0.9) : SheetColors.accent).setFill()
            path.fill()
        } else {
            (pressed ? Theme.pressed : hovered && isEnabled ? SheetColors.buttonHover : SheetColors.buttonFill).setFill()
            path.fill()
            SheetColors.buttonBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor = !isEnabled ? Theme.disabledText : (accentFill ? SheetColors.onAccent : Theme.primaryText)
        let attrs: [NSAttributedString.Key: Any] = [.font: SheetColors.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Check box

/// A Windows 11 check box with an optional mixed state (multi-selections).
final class SheetCheckbox: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) } }
    var state: TriState = .off { didSet { needsDisplay = true; setAccessibilityValue(state == .on ? 1 : state == .mixed ? 2 : 0) } }
    /// Clicking a mixed box goes on → off → mixed (like Explorer) only when `allowsMixed`.
    var allowsMixed = false
    var onChange: ((SheetCheckbox) -> Void)?

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init(_ title: String, onChange: ((SheetCheckbox) -> Void)? = nil) {
        self.title = title
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = title.isEmpty ? 0 : (title as NSString).size(withAttributes: [.font: SheetColors.font]).width + 6
        return NSSize(width: 16 + ceil(w), height: 18)
    }

    override func mouseDown(with event: NSEvent) { toggle() }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49 { toggle() } else { super.keyDown(with: event) } }

    func toggle() {
        guard isEnabled else { return }
        switch state {
        case .off: state = .on
        case .on: state = allowsMixed ? .mixed : .off
        case .mixed: state = .off
        }
        onChange?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0.5, y: (bounds.height - 16) / 2 + 0.5, width: 15, height: 15)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        let filled = state != .off
        if filled && isEnabled {
            SheetColors.accent.setFill()
            path.fill()
        } else {
            SheetColors.fieldBackground.setFill()
            path.fill()
            (isEnabled ? SheetColors.checkBorder : Theme.disabledText).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let mark = filled && isEnabled ? SheetColors.onAccent : (isEnabled ? Theme.primaryText : Theme.disabledText)
        if state == .on {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 6.5, y: box.midY + (isFlipped ? 3 : -3)))
            check.line(to: NSPoint(x: box.maxX - 3, y: box.midY + (isFlipped ? -3.5 : 3.5)))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            mark.setStroke()
            check.stroke()
        } else if state == .mixed {
            mark.setFill()
            NSRect(x: box.minX + 4, y: box.midY - 0.75, width: box.width - 8, height: 1.5).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: SheetColors.font,
                                                    .foregroundColor: isEnabled ? Theme.primaryText : Theme.disabledText]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 22, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Text field

/// A bordered single-line text field in a Windows-style box (name boxes, Tags, Comments).
final class SheetTextField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var isEditable: Bool {
        get { field.isEditable }
        set { field.isEditable = newValue; field.isSelectable = true; needsDisplay = true }
    }

    init(_ text: String = "", placeholder: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = SheetColors.font
        field.textColor = Theme.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (field.isEditable ? SheetColors.fieldBackground : SheetColors.windowBackground).setFill()
        path.fill()
        SheetColors.fieldBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        if window?.firstResponder === field.currentEditor() && field.currentEditor() != nil {
            SheetColors.accent.setFill()
            NSRect(x: 1, y: isFlipped ? bounds.height - 2 : 0, width: bounds.width - 2, height: 2).fill()
        }
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { needsDisplay = true; onCommit?() }
}

// MARK: - Layout helpers

/// A thin horizontal line between groups of rows (Explorer's etched separators).
final class SheetSeparator: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        SheetColors.separator.setFill()
        bounds.fill()
    }
}

/// Builds the label/value grid used by General tabs.
final class SheetForm {
    let stack = NSStackView()
    let labelWidth: CGFloat

    init(labelWidth: CGFloat = 92) {
        self.labelWidth = labelWidth
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    @discardableResult
    func row(_ label: String, _ value: NSView, alignTop: Bool = false) -> NSView {
        let l = SheetLabel.make(label)
        l.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(l)
        row.addSubview(value)
        value.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            l.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            l.widthAnchor.constraint(equalToConstant: labelWidth),
            value.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: labelWidth + 4),
            value.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            value.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            value.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: l.heightAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: value.heightAnchor),
            // Collapse to the tallest child instead of stretching.
            row.heightAnchor.constraint(equalToConstant: 0).withPriority(.init(200)),
        ]
        if alignTop {
            constraints += [l.topAnchor.constraint(equalTo: row.topAnchor, constant: 2), value.topAnchor.constraint(equalTo: row.topAnchor)]
        } else {
            constraints += [l.centerYAnchor.constraint(equalTo: row.centerYAnchor), value.centerYAnchor.constraint(equalTo: row.centerYAnchor)]
        }
        if !(value is SheetCheckbox) && !(value is SheetButton) {
            constraints.append(value.trailingAnchor.constraint(equalTo: row.trailingAnchor).withPriority(.defaultLow))
        }
        NSLayoutConstraint.activate(constraints)
        add(row)
        return row
    }

    func separator() {
        let s = SheetSeparator()
        add(s)
        stack.setCustomSpacing(9, after: stack.arrangedSubviews[max(stack.arrangedSubviews.count - 2, 0)])
    }

    func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func spacer(_ height: CGFloat) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(height, after: last) }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = .centerY
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

/// A flipped plain container for a tab's content.
final class SheetPage: NSView {
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Pins `content` to the page with Explorer's 12 pt inset.
    func embed(_ content: NSView, inset: CGFloat = 12, fillHeight: Bool = false) {
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        var c = [
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ]
        c.append(fillHeight ? content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
                            : content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset))
        NSLayoutConstraint.activate(c)
    }
}

// MARK: - Tab bar

/// Classic property-sheet tabs: the selected tab joins the panel below it.
final class SheetTabBar: NSView {
    var titles: [String] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func frames() -> [NSRect] {
        var x: CGFloat = 0
        return titles.map { title in
            let w = ceil((title as NSString).size(withAttributes: [.font: SheetColors.font]).width) + 16
            defer { x += w }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = frames().firstIndex(where: { $0.contains(p) }), i != selectedIndex {
            selectedIndex = i
            onSelect?(i)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = frames()
        for (i, rect) in rects.enumerated() {
            let selected = i == selectedIndex
            let r = selected ? rect.insetBy(dx: -2, dy: 0) : NSRect(x: rect.minX, y: 2, width: rect.width, height: rect.height - 2)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.minX + 0.5, y: r.maxY + (selected ? 1 : 0)))
            path.line(to: NSPoint(x: r.minX + 0.5, y: r.minY + 0.5))
            path.line(to: NSPoint(x: r.maxX - 0.5, y: r.minY + 0.5))
            path.line(to: NSPoint(x: r.maxX - 0.5, y: r.maxY + (selected ? 1 : 0)))
            (selected ? SheetColors.panelBackground : SheetColors.windowBackground).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + (selected ? 1 : 0)).fill()
            SheetColors.panelBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        for (i, rect) in rects.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: SheetColors.font, .foregroundColor: Theme.primaryText]
            let size = (titles[i] as NSString).size(withAttributes: attrs)
            let y = (bounds.height - size.height) / 2 + (i == selectedIndex ? 0 : 1)
            (titles[i] as NSString).draw(at: NSPoint(x: rect.minX + (rect.width - size.width) / 2, y: y), withAttributes: attrs)
        }
    }
}

/// The bordered white panel under the tabs.
final class SheetPanel: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        SheetColors.panelBackground.setFill()
        bounds.fill()
        SheetColors.panelBorder.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Pie chart (drive properties)

final class PieChartView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // A shallow 3-D disc like Explorer's: the pie is stacked a few points deep in darker colors.
        let depth = (bounds.height * 0.14).rounded()
        let top = NSRect(x: 1, y: depth + 1, width: bounds.width - 2, height: bounds.height - depth - 2)
        func darker(_ c: NSColor) -> NSColor { c.blended(withFraction: 0.28, of: .black) ?? c }
        var y = depth
        while y > 0 {
            drawPie(in: top.offsetBy(dx: 0, dy: -y), used: darker(SheetColors.usedSpace), free: darker(SheetColors.freeSpace))
            y -= 1
        }
        drawPie(in: top, used: SheetColors.usedSpace, free: SheetColors.freeSpace)
        setAccessibilityLabel(L10n.format("%@%% used", "\(Int((fraction * 100).rounded()))"))
    }

    private func drawPie(in rect: NSRect, used: NSColor, free: NSColor) {
        free.setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard fraction > 0 else { return }
        used.setFill()
        if fraction >= 1 { NSBezierPath(ovalIn: rect).fill(); return }
        let wedge = NSBezierPath()
        wedge.move(to: .zero)
        wedge.appendArc(withCenter: .zero, radius: rect.width / 2, startAngle: 90,
                        endAngle: 90 - CGFloat(360 * fraction), clockwise: true)
        wedge.close()
        wedge.transform(using: AffineTransform(scaleByX: 1, byY: rect.height / rect.width))
        wedge.transform(using: AffineTransform(translationByX: rect.midX, byY: rect.midY))
        wedge.fill()
    }
}

final class SwatchView: NSView {
    let color: NSColor
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        SheetColors.panelBorder.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

func fixedImage(_ image: NSImage?, _ side: CGFloat) -> NSImageView {
    let v = NSImageView()
    v.image = image
    v.imageScaling = .scaleProportionallyUpOrDown
    v.translatesAutoresizingMaskIntoConstraints = false
    v.hideFromAccessibility()   // icons beside a name or heading VoiceOver already reads
    NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: side), v.heightAnchor.constraint(equalToConstant: side)])
    return v
}

/// A borderless, flipped vertical list inside a scroll view (Details tab, version lists).
final class SheetScrollList: NSScrollView {
    let content = SheetPage()
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func removeAll() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }
}

/// A bordered box around a list (Security's names list, Previous Versions).
final class SheetBox: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        SheetColors.fieldBackground.setFill()
        bounds.fill()
        SheetColors.fieldBorder.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// A selectable list row (Security names, version list).
final class SheetListRow: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    override var isFlipped: Bool { true }

    init(_ views: [NSView], height: CGFloat = 22) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = hstack(views, spacing: 6)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.selection.setFill()
        bounds.fill()
    }
}
