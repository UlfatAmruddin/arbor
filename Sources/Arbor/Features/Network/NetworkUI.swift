import AppKit
import ArborCore

// MARK: - Icons (original artwork: SF Symbols and code-drawn shapes, DEC-018)

enum NetworkIcons {
    private static let cache = NSCache<NSString, NSImage>()

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let image = make()
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    static func computer(_ size: CGFloat) -> NSImage { IconProvider.shared.symbolIcon("desktopcomputer", color: 0x3A6EA5, size: size) }
    static func infrastructure(_ size: CGFloat) -> NSImage { IconProvider.shared.symbolIcon("wifi.router", color: 0x5A6B7D, size: size) }
    static func mediaDevice(_ size: CGFloat) -> NSImage { IconProvider.shared.symbolIcon("tv", color: 0x5A6B7D, size: size) }

    /// A network drive: a drive with a cable below it (Explorer's mapped-drive idea, our own drawing).
    static func drive(_ size: CGFloat, disconnected: Bool = false) -> NSImage {
        cached("drive-\(size)-\(disconnected)") {
            NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
                let u = rect.width / 32
                // Drive body.
                let body = NSRect(x: rect.minX + 3 * u, y: rect.minY + 7 * u, width: 26 * u, height: 12 * u)
                let path = NSBezierPath(roundedRect: body, xRadius: 2.5 * u, yRadius: 2.5 * u)
                (NSGradient(starting: Theme.rgb(0xD9DEE4), ending: Theme.rgb(0xAEB6BF)) ?? NSGradient()).draw(in: path, angle: 90)
                Theme.rgb(0x7D8794).setStroke()
                path.lineWidth = max(1, 0.8 * u)
                path.stroke()
                // Activity light.
                (disconnected ? Theme.rgb(0x9A9A9A) : Theme.rgb(0x2FA84F)).setFill()
                NSBezierPath(ovalIn: NSRect(x: body.maxX - 6 * u, y: body.midY - 1.3 * u, width: 2.6 * u, height: 2.6 * u)).fill()
                // Cable: down from the drive, then along the bottom.
                let cable = NSBezierPath()
                cable.move(to: NSPoint(x: rect.midX, y: body.maxY))
                cable.line(to: NSPoint(x: rect.midX, y: rect.minY + 26 * u))
                cable.move(to: NSPoint(x: rect.minX + 6 * u, y: rect.minY + 26 * u))
                cable.line(to: NSPoint(x: rect.minX + 26 * u, y: rect.minY + 26 * u))
                cable.lineWidth = max(1, 1.6 * u)
                (disconnected ? Theme.rgb(0x9A9A9A) : Theme.rgb(0x3A8F4A)).setStroke()
                cable.stroke()
                if disconnected {
                    // A red cross over the cable: unavailable.
                    let c = NSRect(x: rect.minX + 18 * u, y: rect.minY + 20 * u, width: 11 * u, height: 11 * u)
                    Theme.rgb(0xC42B1C).setFill()
                    NSBezierPath(ovalIn: c).fill()
                    let x = NSBezierPath()
                    let i = 3.2 * u
                    x.move(to: NSPoint(x: c.minX + i, y: c.minY + i)); x.line(to: NSPoint(x: c.maxX - i, y: c.maxY - i))
                    x.move(to: NSPoint(x: c.maxX - i, y: c.minY + i)); x.line(to: NSPoint(x: c.minX + i, y: c.maxY - i))
                    x.lineWidth = max(1, 1.4 * u)
                    NSColor.white.setStroke()
                    x.stroke()
                }
                return true
            }
        }
    }

    /// A shared folder: our folder artwork with a cable beneath it.
    static func share(_ size: CGFloat) -> NSImage {
        cached("share-\(size)") {
            NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
                let u = rect.width / 32
                IconProvider.drawFolder(in: NSRect(x: rect.minX + 2 * u, y: rect.minY, width: 28 * u, height: 28 * u), glyph: nil)
                let cable = NSBezierPath()
                cable.move(to: NSPoint(x: rect.midX, y: rect.minY + 25 * u))
                cable.line(to: NSPoint(x: rect.midX, y: rect.minY + 30 * u))
                cable.move(to: NSPoint(x: rect.minX + 8 * u, y: rect.minY + 30 * u))
                cable.line(to: NSPoint(x: rect.minX + 24 * u, y: rect.minY + 30 * u))
                cable.lineWidth = max(1, 1.6 * u)
                Theme.rgb(0x3A8F4A).setStroke()
                cable.stroke()
                return true
            }
        }
    }

    static func icon(for device: NetworkDevice, size: CGFloat) -> NSImage {
        switch device.category {
        case .computer: return computer(size)
        case .mediaDevices: return mediaDevice(size)
        case .infrastructure: return infrastructure(size)
        }
    }
}

// MARK: - Fluent-style push button

/// A Windows 11 style button: 4 px corners, subtle border; `isPrimary` fills with the accent color.
final class FluentButton: NSButton {
    var isPrimary = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    convenience init(_ title: String, primary: Bool = false, action: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.title = title
        isPrimary = primary
        onClick = action
        target = self
        self.action = #selector(fire)
        isBordered = false
        font = Theme.bodyFont
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryPushIn)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
    }

    @objc private func fire() { onClick?() }

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: font ?? Theme.bodyFont]).width
        return NSSize(width: ceil(w) + 36, height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        let dark = Theme.isDark(effectiveAppearance)
        let text: NSColor
        if isPrimary {
            let accent = Theme.accent.usingColorSpace(.sRGB) ?? .systemBlue
            (isEnabled ? (hovered ? accent.blended(withFraction: 0.1, of: dark ? .black : .white) ?? accent : accent)
                       : Theme.rgb(dark ? 0x434343 : 0xBFBFBF)).setFill()
            path.fill()
            text = isEnabled ? (dark ? .black : .white) : Theme.rgb(dark ? 0x9A9A9A : 0xFFFFFF)
        } else {
            Theme.rgb(dark ? (hovered ? 0x3C3C3C : 0x373737) : (hovered ? 0xF6F6F6 : 0xFDFDFD)).setFill()
            path.fill()
            Theme.rgb(dark ? 0x454545 : 0xD5D5D5).setStroke()
            path.lineWidth = 1
            path.stroke()
            text = isEnabled ? Theme.primaryText : Theme.disabledText
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? Theme.bodyFont, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

/// A link-style button ("Reconnect", "Open Privacy Settings").
final class LinkButton: NSButton {
    var onClick: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        onClick = action
        isBordered = false
        target = self
        self.action = #selector(fire)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.statusFont, .foregroundColor: NSColor.linkColor])
        translatesAutoresizingMaskIntoConstraints = false
    }
    @objc private func fire() { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Info bar (Windows InfoBar)

final class InfoBarView: NSView {
    enum Severity { case informational, warning, error }
    private let severity: Severity

    init(severity: Severity, title: String, message: String, actions: [NSView]) {
        self.severity = severity
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let symbol: String, color: UInt32
        switch severity {
        case .informational: symbol = "info.circle.fill"; color = 0x005FB8
        case .warning: symbol = "exclamationmark.circle.fill"; color = 0x9D5D00
        case .error: symbol = "xmark.circle.fill"; color = 0xC42B1C
        }
        // Fluent InfoBar icons: a white glyph on a colored circle.
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, Theme.rgb(color)]))
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage())
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.primaryText
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Theme.bodyFont
        messageLabel.textColor = Theme.primaryText
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, titleLabel, messageLabel] + actions)
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(16, after: messageLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title) \(message)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dark = Theme.isDark(effectiveAppearance)
        let fill: UInt32, border: UInt32
        switch severity {
        case .informational: fill = dark ? 0x2B2B2B : 0xF6F6F6; border = dark ? 0x3A3A3A : 0xE5E5E5
        case .warning: fill = dark ? 0x433519 : 0xFFF4CE; border = dark ? 0x5A4A22 : 0xF2E3B3
        case .error: fill = dark ? 0x442726 : 0xFDE7E9; border = dark ? 0x5C3432 : 0xF4C6CA
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        Theme.rgb(fill).setFill()
        path.fill()
        Theme.rgb(border).setStroke()
        path.stroke()
    }
}

// MARK: - Tiles and grouped sections (Explorer "Tiles" view with group headers)

/// One tile: 48 px icon, name, up to two caption lines, optional capacity bar and link.
final class NetworkTileView: NSView {
    let identifier2: String
    var onOpen: (() -> Void)?
    var onOpenInNewTab: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var onSelect: ((NetworkTileView, NSEvent?) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    var isDimmed = false { didSet { alphaValue = isDimmed ? 0.62 : 1 } }
    private var hovered = false { didSet { needsDisplay = true } }
    let titleText: String
    let captionText: String

    static let size = NSSize(width: 262, height: 66)

    init(id: String, icon: NSImage, title: String, caption: String, caption2: String? = nil, capacity: Double? = nil,
         link: LinkButton? = nil) {
        identifier2 = id
        titleText = title
        captionText = caption
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: title)
        name.font = Theme.bodyFont
        name.textColor = Theme.primaryText
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lines: [NSView] = [name]
        if let capacity {
            let bar = CapacityBar(fraction: capacity)
            lines.append(bar)
            bar.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
        for text in [caption, caption2].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            let label = NSTextField(labelWithString: text)
            label.font = Theme.statusFont
            label.textColor = Theme.secondaryText
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.append(label)
        }
        if let link { lines.append(link) }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(text)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 48),
            image.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([title, caption, caption2 ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if isSelected {
            // Accent while the tiles have focus in the active window, grey otherwise (SelectionEmphasis).
            let focused = superview.map(SelectionEmphasis.hasFocus) ?? false
            fillRounded(rect, radius: Theme.cornerRadius, SelectionEmphasis.fill(focused: focused, hovered: hovered))
        } else if hovered {
            fillRounded(rect, radius: Theme.cornerRadius, Theme.hover)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        onSelect?(self, event)
        if event.clickCount == 2 { onOpen?() }
    }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onOpenInNewTab?() } }
    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?(self, nil)
        return menuProvider?()
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

/// Explorer's thin capacity bar (accent, red under 10% free).
final class CapacityBar: NSView {
    let fraction: Double
    init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 6).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let dark = Theme.isDark(effectiveAppearance)
        fillRounded(bounds, radius: 1, Theme.rgb(dark ? 0x3B3B3B : 0xE1E1E1))
        var fill = bounds
        fill.size.width = bounds.width * fraction
        fillRounded(fill, radius: 1, fraction > 0.9 ? Theme.rgb(0xC42B1C) : Theme.accent)
    }
}

struct TileSection {
    var id: String
    var title: String
    var tiles: [NetworkTileView]
}

/// Grouped tiles with collapsible "Computer (3)" headers; arrow keys move the selection, Return opens.
final class TileSectionsView: NSView {
    private(set) var sections: [TileSection] = []
    private var headers: [String: SectionHeader] = [:]
    private(set) var collapsed: Set<String> = []
    private(set) var selected: NetworkTileView?
    var onSelectionChange: (() -> Void)?
    var emptyView: NSView? { didSet { oldValue?.removeFromSuperview(); if let emptyView { addSubview(emptyView) }; needsLayout = true } }
    private let inset = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
    /// Only tiles whose titles contain this are shown.
    var filterText = "" { didSet { if filterText != oldValue { setSections(unfiltered) } } }
    private var unfiltered: [TileSection] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private lazy var emphasisObserver = SelectionEmphasis.Observer { [weak self] in self?.selected?.needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        emphasisObserver.attach(to: window)
    }
    override func becomeFirstResponder() -> Bool { selected?.needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { selected?.needsDisplay = true; return true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        superview?.postsFrameChangedNotifications = true
        if let clip = superview {
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.needsLayout = true
            }
        }
    }

    func setSections(_ newSections: [TileSection]) {
        let previous = selected?.identifier2
        subviews.filter { $0 !== emptyView }.forEach { $0.removeFromSuperview() }
        headers = [:]
        unfiltered = newSections
        let query = filterText
        let shown = query.isEmpty ? newSections : newSections.map { section in
            TileSection(id: section.id, title: section.title, tiles: section.tiles.filter { PageFilter.matches($0.titleText, query) })
        }
        sections = shown.filter { !$0.tiles.isEmpty }
        selected = nil
        for section in sections {
            let header = SectionHeader(title: "\(section.title) (\(section.tiles.count))", collapsed: collapsed.contains(section.id)) { [weak self] in
                self?.toggle(section.id)
            }
            headers[section.id] = header
            addSubview(header)
            for tile in section.tiles {
                tile.onSelect = { [weak self] tile, event in
                    if event != nil, let self { self.window?.makeFirstResponder(self) }
                    self?.select(tile)
                }
                addSubview(tile)
                if tile.identifier2 == previous { select(tile, notify: false) }
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    var allTiles: [NetworkTileView] { sections.flatMap { collapsed.contains($0.id) ? [] : $0.tiles } }

    func select(_ tile: NetworkTileView?, notify: Bool = true) {
        selected?.isSelected = false
        selected = tile
        tile?.isSelected = true
        if let tile { scrollToVisible(tile.frame.insetBy(dx: 0, dy: -8)) }
        if notify { onSelectionChange?() }
    }

    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        headers[id]?.collapsed = collapsed.contains(id)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Track the visible width so tiles wrap instead of overflowing.
        let width = max(superview?.bounds.width ?? bounds.width, 300)
        let tile = NetworkTileView.size
        let columns = max(1, Int((width - inset.left - inset.right + 4) / (tile.width + 4)))
        var y = inset.top
        for section in sections {
            let header = headers[section.id]!
            header.frame = NSRect(x: inset.left - 4, y: y, width: width - inset.left - inset.right + 4, height: 30)
            y += 34
            let hidden = collapsed.contains(section.id)
            for (i, t) in section.tiles.enumerated() {
                t.isHidden = hidden
                guard !hidden else { continue }
                let col = i % columns, row = i / columns
                t.frame = NSRect(x: inset.left + CGFloat(col) * (tile.width + 4), y: y + CGFloat(row) * (tile.height + 4),
                                 width: tile.width, height: tile.height)
            }
            if !hidden { y += CGFloat((section.tiles.count + columns - 1) / columns) * (tile.height + 4) }
            y += 12
        }
        if let emptyView {
            let size = emptyView.fittingSize
            emptyView.frame = NSRect(x: inset.left, y: y + 4, width: min(width - inset.left - inset.right, max(size.width, 420)), height: size.height)
            y += size.height + 8
        }
        let height = max(y + inset.bottom, superview?.bounds.height ?? 0)
        if abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: height)) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        select(nil)
    }

    override func keyDown(with event: NSEvent) {
        let tiles = allTiles
        guard !tiles.isEmpty else { super.keyDown(with: event); return }
        let index = selected.flatMap { s in tiles.firstIndex { $0 === s } }
        let columns = max(1, Int((bounds.width - inset.left - inset.right + 4) / (NetworkTileView.size.width + 4)))
        switch event.keyCode {
        case 123: select(tiles[max(0, (index ?? 0) - 1)])
        case 124: select(tiles[min(tiles.count - 1, (index ?? -1) + 1)])
        case 125: select(tiles[min(tiles.count - 1, (index ?? -columns) + columns)])
        case 126: select(tiles[max(0, (index ?? columns) - columns)])
        case 36, 76: selected?.onOpen?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

final class SectionHeader: NSView {
    private let label: NSTextField
    private let chevron = NSImageView()
    private let onToggle: () -> Void
    var collapsed: Bool { didSet { updateChevron() } }

    init(title: String, collapsed: Bool, onToggle: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        self.collapsed = collapsed
        self.onToggle = onToggle
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(label)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateChevron()
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateChevron() {
        chevron.image = NSImage.tintedSymbol(collapsed ? "chevron.right" : "chevron.down", size: 9, weight: .semibold,
                                             color: Theme.secondaryText.resolved(for: effectiveAppearance))
        setAccessibilityValue(collapsed ? L10n.tr("collapsed") : L10n.tr("expanded"))
    }

    override func viewDidChangeEffectiveAppearance() { updateChevron() }

    override func draw(_ dirtyRect: NSRect) {
        let start = label.frame.maxX + 10
        Theme.separator.setFill()
        NSRect(x: start, y: floor(bounds.midY), width: max(0, bounds.width - start - 4), height: 1).fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) { onToggle() }
    override func accessibilityPerformPress() -> Bool { onToggle(); return true }
}

// MARK: - Message pages (not responding, disconnected, can't connect)

/// A centered message with actions, used for network failure states (spec §16.1).
final class NetworkMessagePage: NSViewController, LocationPageStatus {
    struct Action {
        var title: String
        var primary: Bool
        var perform: () -> Void
    }

    let symbolImage: NSImage
    let titleText: String
    let messageText: String
    let actions: [Action]
    var showsSpinner = false
    var statusSummary: String { "" }
    /// Called on every network change while the page exists (e.g. to reload once a share is back).
    var onNetworkChange: (() -> Void)?
    private var observer: NSObjectProtocol?

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    init(icon: NSImage, title: String, message: String, actions: [Action], spinner: Bool = false) {
        symbolImage = icon
        titleText = title
        messageText = message
        self.actions = actions
        showsSpinner = spinner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let icon = NSImageView(image: symbolImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = NSTextField(wrappingLabelWithString: titleText)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.primaryText
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: messageText)
        detail.font = Theme.bodyFont
        detail.textColor = Theme.secondaryText
        detail.alignment = .center
        var views: [NSView] = [icon, title, detail]
        if showsSpinner {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views.insert(spinner, at: 1)
        }
        if !actions.isEmpty {
            let buttons = NSStackView(views: actions.map { a in FluentButton(a.title, primary: a.primary, action: a.perform) })
            buttons.spacing = 8
            views.append(buttons)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -40),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        root.setAccessibilityLabel("\(titleText). \(messageText)")
        view = root
        observer = NotificationCenter.default.addObserver(forName: NetworkCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.onNetworkChange?()
        }
    }
}

extension NSView {
    /// Depth-first search for a button by title (scripted checks).
    func findButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title, !button.isHidden { return button }
        for sub in subviews { if let hit = sub.findButton(titled: title) { return hit } }
        return nil
    }

    /// Visible text of labels, for scripted checks.
    func collectLabels() -> [String] {
        var out: [String] = []
        if let field = self as? NSTextField, !field.isHidden, !field.stringValue.isEmpty { out.append(field.stringValue) }
        for sub in subviews where !sub.isHidden { out += sub.collectLabels() }
        return out
    }
}
