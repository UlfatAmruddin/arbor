import AppKit
import ArborCore

/// Flat Explorer-style button (icon/title, optional ▾, hover/pressed fill), self-drawn so it looks
/// the same in light, dark and snapshots.
final class ChromeButton: NSControl {
    var symbolName: String? { didSet { invalidate() } }
    /// A full-color image (folder icons etc.), drawn as is. Ignored when `symbolName` is set.
    var image: NSImage? { didSet { invalidate() } }
    var title: String = "" { didSet { invalidate() } }
    var symbolSize: CGFloat = 15 { didSet { invalidate() } }
    var symbolTint: NSColor? { didSet { needsDisplay = true } }
    var titleFont: NSFont = Theme.bodyFont { didSet { invalidate() } }
    var showsMenuIndicator = false { didSet { invalidate() } }
    var isToggled = false { didSet { needsDisplay = true; setAccessibilityValue(isToggled) } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var horizontalPadding: CGFloat = 8 { didSet { invalidate() } }
    var fixedHeight: CGFloat = Theme.controlHeight { didSet { invalidate() } }
    var fixedWidth: CGFloat? { didSet { invalidate() } }
    var cornerRadius: CGFloat = Theme.cornerRadius
    /// Runs on mouse-up inside, or on VoiceOver press.
    var onClick: ((ChromeButton) -> Void)?
    /// Runs on mouse-down instead of `onClick` (menus open on press).
    var onPress: ((ChromeButton) -> Void)?
    var textColor: NSColor = Theme.primaryText

    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init(symbol: String? = nil, title: String = "", tooltip: String? = nil, onClick: ((ChromeButton) -> Void)? = nil) {
        super.init(frame: .zero)
        self.symbolName = symbol
        self.title = title
        self.onClick = onClick
        self.toolTip = tooltip.map { L10n.tr($0) }
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? self.toolTip : title)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func invalidate() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        if !title.isEmpty { setAccessibilityLabel(title) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    /// Only keyboard navigation (F6, Tab, arrows) focuses chrome buttons; clicks leave focus where it was.
    override var acceptsFirstResponder: Bool { FocusRegions.movingFocus || window?.firstResponder === self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    private var iconSide: CGFloat { symbolName != nil ? symbolSize + 3 : (image != nil ? 16 : 0) }

    private var titleSize: NSSize {
        title.isEmpty ? .zero : (title as NSString).size(withAttributes: [.font: titleFont])
    }

    override var intrinsicContentSize: NSSize {
        if let fixedWidth { return NSSize(width: fixedWidth, height: fixedHeight) }
        var w = horizontalPadding * 2
        if iconSide > 0 { w += iconSide }
        if !title.isEmpty { w += ceil(titleSize.width) + (iconSide > 0 ? 6 : 0) }
        if showsMenuIndicator { w += 14 }
        return NSSize(width: max(w, fixedHeight), height: fixedHeight)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        if isDropTarget {
            drawDropHighlight(in: rect)
        } else if isEnabled {
            if isPressed { fillRounded(rect, radius: cornerRadius, Theme.pressed) }
            else if isHovered { fillRounded(rect, radius: cornerRadius, Theme.hover) }
            else if isToggled { fillRounded(rect, radius: cornerRadius, Theme.toggled) }
        }
        let content = contentWidth
        var x = fixedWidth != nil || title.isEmpty ? (rect.width - content) / 2 : horizontalPadding
        let color = isEnabled ? textColor : Theme.disabledText
        if let symbolName {
            let tint = isEnabled ? (symbolTint ?? Theme.iconTint) : Theme.disabledText
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint.usingColorSpace(.sRGB) ?? tint]))
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                let side = iconSide
                img.drawFlippedAware(in: NSRect(x: x + (side - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            x += iconSide
        } else if let image {
            image.draw(in: NSRect(x: x, y: (rect.height - 16) / 2, width: 16, height: 16), from: .zero,
                       operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
            x += 16
        }
        if !title.isEmpty {
            if iconSide > 0 { x += 6 }
            let size = titleSize
            (title as NSString).draw(at: NSPoint(x: x, y: (rect.height - size.height) / 2),
                                     withAttributes: [.font: titleFont, .foregroundColor: color])
            x += ceil(size.width)
        }
        if showsMenuIndicator {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color.usingColorSpace(.sRGB) ?? color]))
            if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = chevron.size
                chevron.drawFlippedAware(in: NSRect(x: x + 6, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
        }
        if hasKeyboardFocus { FocusVisual.draw(in: rect, radius: cornerRadius) }
    }

    /// The border keeps the target distinct from the field background, also in increased contrast.
    private func drawDropHighlight(in rect: NSRect) {
        fillRounded(rect, radius: cornerRadius, Theme.selection)
        Theme.accent.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1.5
        border.stroke()
    }

    private var contentWidth: CGFloat {
        var w: CGFloat = iconSide
        if !title.isEmpty { w += ceil(titleSize.width) + (iconSide > 0 ? 6 : 0) }
        if showsMenuIndicator { w += 14 }
        return w
    }

    override var isFlipped: Bool { true }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let onPress {
            isPressed = true
            onPress(self)
            isPressed = false
            isHovered = false
            return
        }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, onPress == nil else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, onPress == nil else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick?(self) }
    }

    /// Programmatic click (scripts, accessibility).
    func performClick() {
        guard isEnabled else { return }
        if let onPress { onPress(self) } else { onClick?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        performClick()
        return true
    }

    /// Shows a menu under the button.
    func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 2), in: self)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Command bar and status bar separator.
final class VerticalSeparator: NSView {
    init(height: CGFloat = 20) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill(using: .sourceOver)
    }
}

extension NSImage {
    /// Draws upright in flipped and unflipped views alike.
    func drawFlippedAware(in rect: NSRect, fraction: CGFloat = 1) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
    }

    /// An SF Symbol tinted with a concrete color (resolve dynamic colors first).
    static func tintedSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.usingColorSpace(.sRGB) ?? color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
