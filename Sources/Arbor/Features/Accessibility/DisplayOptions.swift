import AppKit
import ArborCore

/// Display accommodations (FE-201) and text size (FE-050, FE-202). Reduce transparency needs nothing
/// (no vibrancy). Scripts force them with `ARBOR_CONTRAST=1`, `ARBOR_REDUCE_MOTION=1`, `ARBOR_TEXT_SIZE=130`.
extension Theme {
    private static let environment = Automation.environment

    /// System setting, or `ARBOR_CONTRAST=1`.
    static var increasedContrast: Bool {
        environment["ARBOR_CONTRAST"] == "1" || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var reduceMotion: Bool {
        environment["ARBOR_REDUCE_MOTION"] == "1" || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// Whether colors resolved for `appearance` should use their high-contrast variants.
    static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        if increasedContrast { return true }
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }

    /// Increase contrast: selected items also get an accent outline (not only a tint).
    static func strokeSelectionIfContrast(_ rect: NSRect, radius: CGFloat) {
        guard increasedContrast || NSApp.effectiveAppearance.name.rawValue.contains("HighContrast") else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        path.lineWidth = 1.5
        accent.setStroke()
        path.stroke()
    }

    // MARK: Text size

    static var textSize: TextSizeLevel { TextSize.level }

    /// Item names in lists, the Details rows and the navigation pane.
    static var listFont: NSFont { .systemFont(ofSize: CGFloat(textSize.fontSize(13))) }
    /// Secondary columns (Date modified, Type, Size) with tabular digits.
    static var listDetailFont: NSFont { .monospacedDigitSystemFont(ofSize: CGFloat(textSize.fontSize(13)), weight: .regular) }
    /// Icon labels and Tiles/Content detail lines.
    static var listSmallFont: NSFont { .systemFont(ofSize: CGFloat(textSize.fontSize(12))) }
    /// A list row height for the current text size.
    static func listRowHeight(_ base: CGFloat) -> CGFloat { CGFloat(textSize.rowHeight(Double(base), fontSize: 13)) }
    /// Scales a layout height that holds `lines` lines of list text.
    static func scaledBlock(_ base: CGFloat, lines: Int) -> CGFloat {
        let extra = listRowHeight(28) - 28
        return base + CGFloat(lines) * extra
    }
}

/// View ▸ Text size: scales the file list and navigation pane, not the fixed-size chrome, so nothing clips.
enum TextSize {
    static let key = "textSize"

    static var level: TextSizeLevel {
        get {
            if let forced = Automation.environment["ARBOR_TEXT_SIZE"].flatMap(Int.init).flatMap(TextSizeLevel.init) { return forced }
            return TextSizeLevel(rawValue: Prefs.store.integer(forKey: key)) ?? .standard
        }
        set {
            Prefs.store.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: Prefs.changed, object: nil, userInfo: ["key": key])
        }
    }

    static func register() {
        let r = CommandRegistry.shared
        // The levels are listed in View ▾ › Text size (and the View menu), not placed on their own.
        let levels = TextSizeLevel.allCases.map { level in
            ExplorerCommand(
                id: "view.textSize.\(level.rawValue)", title: level.title,
                state: { _ in TextSize.level == level ? .on : .off },
                perform: { _ in TextSize.level = level })
        }
        r.register(levels)
        r.register([
            ExplorerCommand(
                id: "menu.textSize", title: "Text Size", symbol: "textformat.size",
                placements: [.viewMenu(.textSize, 10), .mainMenu("View", .textSize, 5)],
                submenu: { ctx in levels.map { CommandDispatcher.shared.menuItem($0, context: ctx) } }),
            ExplorerCommand(
                id: "view.textSize.bigger", title: "Make Text Bigger", shortcut: Shortcut("+"),
                placements: [.mainMenu("View", .textSize, 10)],
                isEnabled: { _ in TextSize.level.bigger != nil },
                perform: { _ in if let next = TextSize.level.bigger { TextSize.level = next } }),
            ExplorerCommand(
                id: "view.textSize.smaller", title: "Make Text Smaller", shortcut: Shortcut("-"),
                placements: [.mainMenu("View", .textSize, 20)],
                isEnabled: { _ in TextSize.level.smaller != nil },
                perform: { _ in if let next = TextSize.level.smaller { TextSize.level = next } }),
            ExplorerCommand(
                id: "view.textSize.default", title: "Default Text Size", shortcut: Shortcut("0"),
                placements: [.mainMenu("View", .textSize, 30)],
                isEnabled: { _ in TextSize.level != .standard },
                perform: { _ in TextSize.level = .standard }),
        ])
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            guard (note.userInfo?["key"] as? String) == key else { return }
            DisplayOptions.relayoutAll()
        }
    }
}

extension MenuSection {
    static let textSize = MenuSection(rank: 820, name: "textSize")
}

enum DisplayOptions {
    static func install() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            redrawAll()
        }
    }

    /// Increase contrast changed: colors resolve at draw time, so a redraw picks them up. Rows are redrawn in
    /// place: a full `reloadData()` drops a table's selection without a selection-change notification, which
    /// left the status bar describing items that were no longer selected and the next command acting on none.
    static func redrawAll() {
        // The file list goes through its controller, which also waits for an open rename.
        for c in (NSApp.delegate as? AppDelegate)?.controllers ?? [] { c.itemView?.reloadRows() }
        for window in NSApp.windows {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            invalidate(root)
        }
    }

    private static func invalidate(_ view: NSView) {
        view.needsDisplay = true
        if let table = view as? NSTableView, !(table is FileTableView), table.numberOfRows > 0, table.numberOfColumns > 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        view.subviews.forEach(invalidate)
    }

    /// Text size changed: re-measure rows and labels in every window, keeping selection and expansion.
    static func relayoutAll() {
        for c in (NSApp.delegate as? AppDelegate)?.controllers ?? [] {
            c.itemView?.reloadRows()
            let outline = c.navPane.outline
            outline.rowHeight = Theme.treeRowHeight
            let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
            outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            outline.noteHeightOfRows(withIndexesChanged: rows)
        }
    }
}
