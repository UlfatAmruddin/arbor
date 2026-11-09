import AppKit
import ArborCore

/// Wrapped names in Details (FE-055). `nameWrap` is nil while the option is off, so the plain path only tests for nil.
extension DetailsViewController {
    private static let wrappedCellID = NSUserInterfaceItemIdentifier("NameCellWrapped")

    private func wrapText(_ item: FileItem) -> NameWrapText {
        NameWrapText(shownName(item), keepsExtension: Prefs.showExtensions && !item.isFolder)
    }

    /// The row height of a wrapped item; nil for a group header or while wrapping is off.
    func wrappedRowHeight(_ row: Int) -> CGFloat? {
        guard let nameWrap, let item = item(atRow: row) else { return nil }
        return nameWrap.rowHeight(for: wrapText(item))
    }

    /// The name's text field content.
    func cellText(_ item: FileItem) -> String {
        guard let nameWrap else { return shownName(item) }
        return nameWrap.shownText(for: wrapText(item))
    }

    func wrappedTextHeight(_ item: FileItem) -> CGFloat {
        nameWrap?.textHeight(for: wrapText(item)) ?? 0
    }

    func wrappedOneLineWidth(row: Int) -> CGFloat? {
        guard nameWrap != nil, let item = item(atRow: row) else { return nil }
        return TextWidthCache.width(shownName(item), font: Theme.listFont)
    }

    /// Pooled apart from single-line cells, so turning the option off leaves nothing to undo.
    func wrappedNameCell(in table: NSTableView) -> NameCellView {
        if let cell = table.makeView(withIdentifier: Self.wrappedCellID, owner: nil) as? NameCellView { return cell }
        let cell = NameCellView()
        cell.identifier = Self.wrappedCellID
        NameWrapRows.styleForWrapping(cell.nameField)
        let height = cell.nameField.heightAnchor.constraint(equalToConstant: 16)
        height.isActive = true
        cell.wrapHeight = height
        return cell
    }

    /// Starts, stops or refits wrapping; true when the table must ask for row heights again.
    @discardableResult
    func syncNameWrap() -> Bool {
        guard Prefs.wrapLongNames, let shape = nameShape else {
            defer { nameWrap = nil }
            return nameWrap != nil
        }
        if nameWrap == nil {
            nameWrap = NameWrapRows { [weak self] in self?.askAgainForRowsOnScreen() }
        }
        return nameWrap?.refit(fieldWidth: shape.field.upperBound - shape.field.lowerBound,
                               baseRowHeight: Theme.rowHeight(compact: Prefs.compactView),
                               showsExtensions: Prefs.showExtensions) ?? false
    }

    /// Before new rows are shown; names measured in this folder stay known across refreshes.
    func prepareNameWrap(locationChanged: Bool) {
        syncNameWrap()
        if locationChanged { nameWrap?.forgetHeights() }
    }

    func noteAllRowHeights() {
        guard nameWrap != nil, !rows.isEmpty else { return }
        noteRowHeightsWithoutAnimation(IndexSet(integersIn: 0..<rows.count))
    }

    /// The Name column changed width: coalesced, because this arrives during the table's own layout.
    func scheduleNameWrapRefit() {
        guard let nameWrap, !nameWrap.refitScheduled else { return }
        nameWrap.refitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.nameWrap?.refitScheduled = false
            self?.refitNameWrap()
        }
    }

    /// A rename or a band keeps rows still; it is applied when that ends (`applyDeferredUpdate`).
    func refitNameWrap() {
        guard nameWrap != nil, !isEditingName, !isTrackingMarquee, syncNameWrap() else { return }
        noteAllRowHeights()
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, !rows.isEmpty else { return }
        // Only prepared rows are touched; the shortened text depends on the width.
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: column))
    }

    private func askAgainForRowsOnScreen() {
        guard let range = Range(table.rows(in: table.visibleRect)), !range.isEmpty else { return }
        noteRowHeightsWithoutAnimation(IndexSet(integersIn: range))
    }

    private func noteRowHeightsWithoutAnimation(_ indexes: IndexSet) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: indexes)
        NSAnimationContext.endGrouping()
    }

    /// The `namewrap:` log: what each row on screen is, against what its cell really laid out.
    func nameWrapReport() -> String {
        var lines = ["namewrap: on=\(nameWrap != nil) measured=\(nameWrap?.measuredCount ?? 0) rows=\(rows.count) lineHeight=\(nameWrap?.metrics.lineHeight ?? 0)"]
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, let range = Range(table.rows(in: table.visibleRect)) else { return lines.joined(separator: "\n") }
        for row in range {
            guard let item = item(atRow: row) else { continue }
            let height = table.rect(ofRow: row).height
            let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView
            let field = cell?.nameField
            let wrapped = cell?.wrapHeight != nil
            let tip = field?.toolTip?.contains(item.name) == true
            let shown = (field?.stringValue ?? "").filter { !$0.isNewline }.replacingOccurrences(of: NameWrapText.extensionBreak, with: "|")
            lines.append("namewrap row: \(item.name.replacingOccurrences(of: "\n", with: "\\n")) height=\(Int(height.rounded())) field=\(Int(field?.frame.width ?? 0))x\(Int(field?.frame.height ?? 0)) wrapped=\(wrapped) tip=\(tip) shown=\(shown)")
        }
        return lines.joined(separator: "\n")
    }
}
