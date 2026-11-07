import AppKit

/// Colors and metrics approximating Windows 11 File Explorer (DEC-017, DEC-018).
/// Values are our own approximations from public screenshots, not measured reference values
/// (spec §4.3). Every color adapts to light and dark appearance; draw with them inside
/// `draw(_:)` so they resolve against the view's appearance.
enum Theme {
    // MARK: Surfaces

    /// Title/tab row behind the tabs ("mica").
    static let tabStripBackground = dynamic(light: 0xE6E9ED, dark: 0x1C1C1C)
    /// Active tab, navigation row and command bar: one continuous surface.
    static let toolbarBackground = dynamic(light: 0xF9F9F9, dark: 0x2B2B2B)
    /// Navigation pane and status bar.
    static let navPaneBackground = dynamic(light: 0xF3F3F3, dark: 0x202020)
    /// File list and pages.
    static let contentBackground = dynamic(light: 0xFFFFFF, dark: 0x191919)
    /// Address and search boxes.
    static let fieldBackground = dynamic(light: 0xFFFFFF, dark: 0x343434)
    static let fieldBorder = dynamic(light: 0xDCDCDC, dark: 0x404040, contrastLight: 0x6B6B6B, contrastDark: 0xA6A6A6)
    static let separator = dynamic(light: 0xE3E3E3, dark: 0x383838, contrastLight: 0x8A8A8A, contrastDark: 0x8C8C8C)
    /// Thin separators between tabs.
    static let tabSeparator = dynamic(light: 0xC8CBCF, dark: 0x3E3E3E, contrastLight: 0x7A7A7A, contrastDark: 0x9A9A9A)

    // MARK: States

    static let hover = overlay(lightAlpha: 0.045, darkAlpha: 0.065)
    static let pressed = overlay(lightAlpha: 0.08, darkAlpha: 0.10)
    /// Toggled-on command buttons (Details pane, view toggles).
    static let toggled = overlay(lightAlpha: 0.07, darkAlpha: 0.09)
    /// Current location in the navigation pane.
    static let navSelection = overlay(lightAlpha: 0.075, darkAlpha: 0.095)

    /// Selected rows: accent-tinted (≈ #CCE4F7 light, ≈ #2D4A63 dark with a blue accent).
    static let selection = NSColor(name: "ArborSelection") { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let contrast = isHighContrast(appearance)   // Increase contrast: a stronger tint
        if isDark(appearance) {
            return accent.blended(withFraction: contrast ? 0.35 : 0.62, of: NSColor(srgbRed: 0.23, green: 0.23, blue: 0.23, alpha: 1)) ?? accent
        }
        return accent.blended(withFraction: contrast ? 0.6 : 0.80, of: .white) ?? accent
    }
    static let selectionHover = NSColor(name: "ArborSelectionHover") { appearance in
        let base = selection.resolved(for: appearance)
        return (isDark(appearance) ? base.blended(withFraction: 0.08, of: .white)
                                   : base.blended(withFraction: 0.06, of: .black)) ?? base
    }
    /// Selection while the list doesn't have keyboard focus.
    static let selectionInactive = overlay(lightAlpha: 0.09, darkAlpha: 0.12)

    // MARK: Text and glyphs

    static let primaryText = NSColor.labelColor
    static let secondaryText = dynamic(light: 0x5F5F5F, dark: 0xC2C2C2, contrastLight: 0x333333, contrastDark: 0xEBEBEB)
    static let disabledText = NSColor.tertiaryLabelColor
    static let iconTint = dynamic(light: 0x262626, dark: 0xE6E6E6)
    static var accent: NSColor { .controlAccentColor }

    // MARK: Fonts

    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let tabFont = NSFont.systemFont(ofSize: 12)
    static let statusFont = NSFont.systemFont(ofSize: 12)
    static let headerFont = NSFont.systemFont(ofSize: 12)

    // MARK: Metrics (candidate values, spec §4.3)

    static let tabStripHeight: CGFloat = 40
    static let tabHeight: CGFloat = 32
    /// Equal-width tabs between these bounds (WinUI TabView's defaults: 100 and 240 epx); past the
    /// minimum the strip scrolls with arrow buttons.
    static let tabMinWidth: CGFloat = 100
    static let tabMaxWidth: CGFloat = 240
    static let tabScrollButtonWidth: CGFloat = 28
    /// How far outside the tab row a dragged tab may go before it tears off.
    static let tabTearOffSlack: CGFloat = 24
    static let tabCornerRadius: CGFloat = 8
    /// Space left for the window's close/minimize/zoom buttons.
    static let trafficLightInset: CGFloat = 80
    static let navRowHeight: CGFloat = 44
    static let commandBarHeight: CGFloat = 46
    static let statusBarHeight: CGFloat = 26
    static let controlHeight: CGFloat = 32
    static let fieldHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 4
    static var treeRowHeight: CGFloat { listRowHeight(28) }
    static let navPaneWidth: CGFloat = 230
    /// Rows grow with View ▸ Text size so larger text is never clipped (FE-050).
    static func rowHeight(compact: Bool) -> CGFloat { listRowHeight(compact ? 24 : 28) }
    /// Back, Forward, Up and Refresh in the navigation row.
    static let navButtonWidth: CGFloat = 34

    // MARK: Helpers

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { isDark($0) ? rgb(dark) : rgb(light) }
    }

    /// A color with stronger variants for Increase contrast (FE-201).
    static func dynamic(light: UInt32, dark: UInt32, contrastLight: UInt32, contrastDark: UInt32) -> NSColor {
        NSColor(name: nil) { a in
            isHighContrast(a) ? rgb(isDark(a) ? contrastDark : contrastLight) : rgb(isDark(a) ? dark : light)
        }
    }

    /// Hover/pressed/selection overlays are about twice as strong with Increase contrast.
    static func overlay(lightAlpha: CGFloat, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) {
            let k: CGFloat = isHighContrast($0) ? 2.2 : 1
            return isDark($0) ? NSColor(white: 1, alpha: darkAlpha * k) : NSColor(white: 0, alpha: lightAlpha * k)
        }
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// `ARBOR_APPEARANCE=light|dark` forces an appearance (used by scripted snapshots).
    static func applyEnvironmentAppearance() {
        switch ProcessInfo.processInfo.environment["ARBOR_APPEARANCE"]?.lowercased() {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }
}

extension NSColor {
    /// The concrete color for an appearance (dynamic colors resolve lazily otherwise).
    func resolved(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }
}

extension NSView {
    /// Fills a rounded rectangle with a theme color in `draw(_:)`.
    func fillRounded(_ rect: NSRect, radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

/// A view that paints one theme color. Use for chrome backgrounds; it renders in snapshots.
class ThemeBackgroundView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    /// Optional hairline along an edge.
    var bottomLine: NSColor? { didSet { needsDisplay = true } }
    var topLine: NSColor? { didSet { needsDisplay = true } }

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.intersection(dirtyRect).fill(using: .sourceOver)
        if let line = bottomLine {
            line.setFill()
            NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : 0, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
        if let line = topLine {
            line.setFill()
            NSRect(x: 0, y: isFlipped ? 0 : bounds.maxY - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
    }
}
