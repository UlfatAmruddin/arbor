import AppKit
import ObjectiveC
import ArborCore

/// An extra Details column contributed by a feature (Trash: Original Location, Date Deleted; cloud: Status).
struct DetailsColumnSpec {
    let id: String
    let title: String
    var width: CGFloat = 150
    var minWidth: CGFloat = 60
    var alignment: NSTextAlignment = .left
    /// Builds (or reuses through `makeView(withIdentifier:owner:)`) the cell for one row.
    let cell: (NSTableView, FileItem) -> NSView
}

/// The Details columns for a kind of location, like Explorer's per-folder-type column sets
/// (windows11-reference.md §5.1). Core column ids: `name`, `dateModified`, `type`, `size`.
struct DetailsLayout {
    /// Identifies the layout; the table is only rearranged when it changes.
    let id: String
    /// Column ids in display order. Columns not listed keep their relative order after these.
    var order: [String]
    /// Header text overrides ("type" → "Item type").
    var titles: [String: String] = [:]
    /// Width overrides for core columns while the layout is shown.
    var widths: [String: CGFloat] = [:]
    var extras: [DetailsColumnSpec] = []
}

/// Registry of per-location Details layouts. The Details view calls `apply(to:location:)` when it
/// displays items and asks `cell(for:columnID:item:)` for columns it doesn't know. Leaving a location
/// restores the standard columns (order, titles, widths) exactly as they were.
///
///     DetailsColumns.register { $0 == .trash ? trashLayout : nil }
enum DetailsColumns {
    private static var providers: [(Location) -> DetailsLayout?] = []

    /// The most recently registered provider that returns a layout wins.
    static func register(_ provider: @escaping (Location) -> DetailsLayout?) { providers.append(provider) }

    static func layout(for location: Location?) -> DetailsLayout? {
        guard let location else { return nil }
        for provider in providers.reversed() { if let layout = provider(location) { return layout } }
        return nil
    }

    static func apply(to table: NSTableView, location: Location?) {
        let state = TableState.of(table)
        let wanted = layout(for: location)
        guard wanted?.id != state.active?.id else { return }
        state.restore(table)
        if let wanted { state.apply(wanted, to: table) }
    }

    /// The cell for an extra column of the active layout, or nil for core columns.
    static func cell(for table: NSTableView, columnID: String, item: FileItem) -> NSView? {
        guard let spec = TableState.of(table).active?.extras.first(where: { $0.id == columnID }) else { return nil }
        return spec.cell(table, item)
    }

    /// Id of the layout currently applied to a table (scripted checks).
    static func activeLayoutID(of table: NSTableView) -> String? { TableState.of(table).active?.id }

    /// Header styling identical to the core columns.
    static func headerTitle(_ title: String, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [
            .font: Theme.headerFont, .foregroundColor: Theme.secondaryText, .paragraphStyle: paragraph,
        ])
    }

    // MARK: Per-table state

    private final class TableState {
        private static var key: UInt8 = 0
        var active: DetailsLayout?
        private var savedOrder: [String] = []
        private var savedTitles: [String: (String, NSAttributedString)] = [:]
        private var savedWidths: [String: CGFloat] = [:]
        private var savedAutosave = false

        static func of(_ table: NSTableView) -> TableState {
            if let state = objc_getAssociatedObject(table, &key) as? TableState { return state }
            let state = TableState()
            objc_setAssociatedObject(table, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return state
        }

        private func column(_ id: String, in table: NSTableView) -> NSTableColumn? {
            table.tableColumns.first { $0.identifier.rawValue == id }
        }

        func apply(_ layout: DetailsLayout, to table: NSTableView) {
            // Active before columns move, so column-move/resize observers can tell the layout's changes
            // from the user's (otherwise the layout's extras leak into the folder's saved column set).
            active = layout
            savedOrder = table.tableColumns.map(\.identifier.rawValue)
            // Don't let the layout overwrite the user's saved standard columns.
            savedAutosave = table.autosaveTableColumns
            table.autosaveTableColumns = false
            for spec in layout.extras where column(spec.id, in: table) == nil {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                c.title = spec.title
                c.headerCell.alignment = spec.alignment
                c.headerCell.attributedStringValue = DetailsColumns.headerTitle(spec.title, alignment: spec.alignment)
                c.width = spec.width
                c.minWidth = spec.minWidth
                c.maxWidth = 2000
                c.resizingMask = [.autoresizingMask, .userResizingMask]
                table.addTableColumn(c)
            }
            for (id, title) in layout.titles {
                guard let c = column(id, in: table) else { continue }
                savedTitles[id] = (c.title, c.headerCell.attributedStringValue)
                c.title = title
                c.headerCell.attributedStringValue = DetailsColumns.headerTitle(title, alignment: c.headerCell.alignment)
            }
            for (id, width) in layout.widths {
                guard let c = column(id, in: table) else { continue }
                savedWidths[id] = c.width
                c.width = width
            }
            reorder(table, to: layout.order)
            active = layout
        }

        func restore(_ table: NSTableView) {
            guard let layout = active else { return }
            for spec in layout.extras { if let c = column(spec.id, in: table) { table.removeTableColumn(c) } }
            for (id, saved) in savedTitles {
                guard let c = column(id, in: table) else { continue }
                c.title = saved.0
                c.headerCell.attributedStringValue = saved.1
            }
            for (id, width) in savedWidths { column(id, in: table)?.width = width }
            reorder(table, to: savedOrder)
            table.autosaveTableColumns = savedAutosave
            savedTitles = [:]
            savedWidths = [:]
            active = nil
        }

        private func reorder(_ table: NSTableView, to order: [String]) {
            let present = table.tableColumns.map(\.identifier.rawValue)
            let wanted = order.filter(present.contains) + present.filter { !order.contains($0) }
            for (index, id) in wanted.enumerated() {
                let from = table.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
                if from >= 0, from != index { table.moveColumn(from, toColumn: index) }
            }
        }
    }
}

/// A plain text cell for extra columns, styled like the core Date/Type/Size cells.
final class DetailsTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    /// Paths truncate in the middle (keeping the last folder visible); other text at the tail.
    static func make(_ table: NSTableView, id: String, alignment: NSTextAlignment = .left,
                     truncation: NSLineBreakMode = .byTruncatingTail) -> DetailsTextCell {
        let identifier = NSUserInterfaceItemIdentifier("ExtraText-\(id)")
        if let reused = table.makeView(withIdentifier: identifier, owner: nil) as? DetailsTextCell { return reused }
        let cell = DetailsTextCell()
        cell.identifier = identifier
        cell.label.alignment = alignment
        cell.label.lineBreakMode = truncation
        return cell
    }

    init() {
        super.init(frame: .zero)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
