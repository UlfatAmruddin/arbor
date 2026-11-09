import AppKit
import ArborCore

/// The confirmation before an import: every line is catalog text, so a file can't word its own preview.
enum SettingsImportPreview {
    private static let columnWidths: [CGFloat] = [250, 150, 150]
    private static let columnSpacing: CGFloat = 12
    private static let rowSpacing: CGFloat = 6
    private static let maxHeight: CGFloat = 300

    static func alert(for plan: PortableImportPlan) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = plan.changes.count == 1 ? L10n.tr("Import 1 setting?") : L10n.format("Import %d settings?", plan.changes.count)
        let scope = L10n.tr("Folders, pins, network drives, privacy and confirmation settings stay as they are.")
        alert.informativeText = [plan.note, scope].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let list = table(for: plan)
        alert.accessoryView = list
        let confirm = alert.addButton(withTitle: L10n.tr("Import"))
        let cancel = alert.addButton(withTitle: L10n.tr("Cancel"))
        confirm.keyEquivalent = ""                  // Return can't confirm what the keyboard hasn't reached yet
        cancel.keyEquivalent = "\u{1b}"             // explicit: AppKit's automatic Escape depends on the title
        alert.layout()
        alert.window.initialFirstResponder = list
        alert.window.makeFirstResponder(list)       // the initial responder alone applies only once the sheet is key
        return alert
    }

    private static func table(for plan: PortableImportPlan) -> KeyboardScrollView {
        let header = [L10n.tr("Setting"), L10n.tr("Now"), L10n.tr("After import")].enumerated().map { column, text in
            label(text, column: column, font: Theme.headerFont, color: Theme.secondaryText)
        }
        let rows = plan.changes.map { change in
            [change.setting.title, change.currentTitle, change.newTitle].enumerated().map { column, text in
                label(text, column: column, font: Theme.bodyFont, color: Theme.primaryText)
            }
        }
        let grid = NSGridView(views: [header] + rows)
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = columnSpacing
        grid.yPlacement = .top
        for (column, width) in columnWidths.enumerated() { grid.column(at: column).width = width }
        let size = grid.fittingSize
        grid.frame = NSRect(origin: .zero, size: size)

        // Flipped, so a list taller than the view opens at its first row.
        let document = FlippedView(frame: grid.frame)
        document.addSubview(grid)
        let scroll = KeyboardScrollView(frame: NSRect(x: 0, y: 0, width: size.width + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy),
                                                height: min(size.height, maxHeight)))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.verticalLineScroll = NSLayoutManager().defaultLineHeight(for: Theme.bodyFont) + rowSpacing
        scroll.focusRingType = .exterior
        scroll.setAccessibilityLabel(L10n.tr("Settings that will change"))
        return scroll
    }

    /// Wraps within its fixed column, because NSAlert sizes itself from the accessory.
    private static func label(_ text: String, column: Int, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = columnWidths[column]
        return field
    }
}
