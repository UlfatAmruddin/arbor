import AppKit
import ArborCore

/// Windows 11 style file-operation dialog look (DEC-017, DEC-018); our own approximations, no Windows assets.
enum FileOpsStyle {
    static let background = Theme.dynamic(light: 0xFFFFFF, dark: 0x2B2B2B)
    /// The "More details" strip and button row at the bottom.
    static let footer = Theme.dynamic(light: 0xF3F3F3, dark: 0x202020)
    static let footerLine = Theme.dynamic(light: 0xE5E5E5, dark: 0x1A1A1A)
    static let separator = Theme.dynamic(light: 0xE5E5E5, dark: 0x3A3A3A)
    /// The copy dialog's green progress, yellow while paused.
    static let progress = Theme.dynamic(light: 0x06B025, dark: 0x6CCB5F)
    static let paused = Theme.dynamic(light: 0xDCA000, dark: 0xFCE100)
    static let track = Theme.dynamic(light: 0xE6E6E6, dark: 0x454545)
    static let graphBackground = Theme.dynamic(light: 0xFFFFFF, dark: 0x262626)
    static let graphBorder = Theme.dynamic(light: 0xBFBFBF, dark: 0x5A5A5A)
    static let graphGrid = Theme.dynamic(light: 0xEEF6EE, dark: 0x2F3A2F)
    static let speedLine = Theme.dynamic(light: 0x1A1A1A, dark: 0xE6E6E6)
    static let link = NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return Theme.isDark(appearance) ? (accent.blended(withFraction: 0.35, of: .white) ?? accent)
                                        : (accent.blended(withFraction: 0.15, of: .black) ?? accent)
    }
    static let buttonFill = Theme.dynamic(light: 0xFDFDFD, dark: 0x373737)
    static let buttonBorder = Theme.dynamic(light: 0xD0D0D0, dark: 0x454545)

    static let captionFont = NSFont.systemFont(ofSize: 12)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let instructionFont = NSFont.systemFont(ofSize: 16)
    static let percentFont = NSFont.systemFont(ofSize: 17)
    static let optionFont = NSFont.systemFont(ofSize: 14)

    static func label(_ text: String, font: NSFont = bodyFont, color: NSColor = Theme.primaryText, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        if !wraps { field.lineBreakMode = .byTruncatingMiddle }
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// A view that paints one color (fills `bounds`, so it renders in snapshots).
final class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var topLine: NSColor? { didSet { needsDisplay = true } }
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        if let line = topLine {
            line.setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// Windows 11 push button: 4 pt corners, hairline border; the default button is accent-filled.
final class WinButton: NSButton {
    var isAccent = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    init(_ title: String, accent: Bool = false, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        isAccent = accent
        onPress = action
        isBordered = false
        bezelStyle = .regularSquare
        font = FileOpsStyle.bodyFont
        target = self
        self.action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        if accent { keyEquivalent = "\r" }
        let width = max(96, (title as NSString).size(withAttributes: [.font: FileOpsStyle.bodyFont]).width + 32)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let enabled = isEnabled
        if isAccent {
            let base = enabled ? FileOpsStyle.link : Theme.disabledText
            (hovering && enabled ? base.blended(withFraction: 0.1, of: .white) ?? base : base).setFill()
            path.fill()
        } else {
            FileOpsStyle.buttonFill.setFill()
            path.fill()
            if hovering && enabled { Theme.hover.setFill(); path.fill() }
            FileOpsStyle.buttonBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor = isAccent ? (Theme.isDark(effectiveAppearance) ? .black : .white) : (enabled ? Theme.primaryText : Theme.disabledText)
        let attrs: [NSAttributedString.Key: Any] = [.font: FileOpsStyle.bodyFont, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

/// The big choice rows of "Replace or Skip Files" (icon, title, optional detail line).
final class CommandLinkButton: NSButton {
    private let symbol: String
    private let detail: String?
    private var hovering = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    init(symbol: String, title: String, detail: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.detail = detail
        super.init(frame: .zero)
        self.title = title
        onPress = action
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: detail == nil ? 40 : 52).isActive = true
        setAccessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tinted = image.tinted(FileOpsStyle.link.resolved(for: effectiveAppearance))
            let y = detail == nil ? (bounds.height - tinted.size.height) / 2 : 9
            tinted.draw(in: NSRect(x: 12 + (20 - tinted.size.width) / 2, y: y, width: tinted.size.width, height: tinted.size.height))
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: FileOpsStyle.optionFont, .foregroundColor: Theme.primaryText]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let titleY = detail == nil ? (bounds.height - titleSize.height) / 2 : 7
        (title as NSString).draw(at: NSPoint(x: 44, y: titleY), withAttributes: titleAttrs)
        if let detail {
            let attrs: [NSAttributedString.Key: Any] = [.font: FileOpsStyle.captionFont, .foregroundColor: Theme.secondaryText]
            (detail as NSString).draw(in: NSRect(x: 44, y: titleY + titleSize.height + 1, width: bounds.width - 52, height: 18), withAttributes: attrs)
        }
    }
}

/// Accent-colored text that acts like a link (folder names in "Copying … from X to Y").
final class FileOpsLinkButton: NSButton {
    var onPress: (() -> Void)?

    init(_ title: String, font: NSFont = FileOpsStyle.captionFont, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: FileOpsStyle.link])
        self.title = title
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: FileOpsStyle.link])
        onPress = action
        target = self
        self.action = #selector(pressed)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// "More details" / "Fewer details" with a chevron, at the bottom left of a dialog.
final class DetailsToggle: NSButton {
    var expanded = false { didSet { refresh() } }
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading
        target = self
        action = #selector(toggle)
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = expanded ? L10n.tr("Fewer details") : L10n.tr("More details")
        attributedTitle = NSAttributedString(string: " " + title, attributes: [.font: FileOpsStyle.bodyFont, .foregroundColor: Theme.primaryText])
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        contentTintColor = Theme.primaryText
    }

    @objc private func toggle() {
        expanded.toggle()
        onToggle?(expanded)
    }
}

extension NSImage {
    /// A copy drawn in one color (for SF Symbols in custom-drawn controls and snapshots).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

/// Panel used by every file-operation dialog. Escape runs `onCancel` (like the title-bar ✕).
final class FileOpsPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
}

/// Base for non-modal dialogs centered on their browser window; jobs elsewhere keep running.
class FileOpsDialog: NSObject, NSWindowDelegate {
    /// Open dialogs, newest last (scripts click their buttons with `opbutton:`).
    static private(set) var open: [FileOpsDialog] = []
    static let changed = Notification.Name("ArborFileOpsDialogsChanged")

    let panel: FileOpsPanel
    let content = FillView(FileOpsStyle.background)
    let footer = FillView(FileOpsStyle.footer)
    private var finished = false

    init(title: String, width: CGFloat) {
        panel = FileOpsPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancelled() }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        footer.topLine = FileOpsStyle.footerLine
        root.addSubview(content)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: content.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
    }

    func present(over parent: NSWindow?) {
        guard let root = panel.contentView else { return }
        root.layoutSubtreeIfNeeded()
        panel.setContentSize(root.fittingSize)
        let size = panel.frame.size
        if let parent, parent.isVisible || AppDelegate.isHeadless {
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2 + 40))
        } else {
            panel.center()
        }
        if AppDelegate.isHeadless {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        Self.open.append(self)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Re-fits the panel after content changed (e.g. "More details"), keeping the top edge.
    func refit() {
        guard let root = panel.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    /// Closes once; subclasses deliver their answer before calling this.
    func dismiss() {
        guard !finished else { return }
        finished = true
        panel.orderOut(nil)
        Self.open.removeAll { $0 === self }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Escape or the title-bar close button. Subclasses answer "Cancel".
    func cancelled() {}

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelled()
        return false
    }

    func setButtons(_ buttons: [NSView], leading: [NSView] = []) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: leading + [spacer] + buttons)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: footer.topAnchor),
            row.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])
    }

    /// Puts a vertical stack into the content area with Explorer-like margins.
    @discardableResult
    func setBody(_ views: [NSView], spacing: CGFloat = 10, insets: NSEdgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        views.forEach { $0.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        return stack
    }

    // MARK: Scripting

    /// Clicks the button (or toggles the checkbox) titled `title` in the newest dialog.
    static func scriptClick(_ title: String) -> Bool {
        for dialog in open.reversed() {
            if let button = find(title, in: dialog.panel.contentView) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    private static func find(_ title: String, in view: NSView?) -> NSButton? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let button = view as? NSButton, button.title == title, button.isEnabled { return button }
        for sub in view.subviews { if let found = find(title, in: sub) { return found } }
        return nil
    }
}

/// "Copying 3 items from <Downloads> to <Desktop>" with the folder names as links.
func fromToLine(verb: String, count: Int, source: URL?, destination: URL?, open: @escaping (URL) -> Void) -> NSStackView {
    var views: [NSView] = [FileOpsStyle.label(L10n.format("%@ %@ from", TransferWords.localized(verb), StatusText.items(count)), font: FileOpsStyle.captionFont, color: Theme.secondaryText)]
    if let source {
        views.append(FileOpsLinkButton(displayName(of: source)) { open(source) })
    }
    if let destination {
        views.append(FileOpsStyle.label(L10n.tr("to"), font: FileOpsStyle.captionFont, color: Theme.secondaryText))
        views.append(FileOpsLinkButton(displayName(of: destination)) { open(destination) })
    }
    for view in views { view.setContentHuggingPriority(.required, for: .horizontal) }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.spacing = 3
    row.alignment = .firstBaseline
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
}
