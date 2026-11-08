import AppKit
import ArborCore

/// Keyboard additions for the Details view (FE-060, FE-068): type-to-select through the input method, and
/// moving the keyboard focus without changing the selection (DEC-accessibility-3, the icon layouts' ⌥⌘ arrows
/// and ⌥Space, Explorer's Ctrl+arrows and Ctrl+Space).
extension DetailsViewController {
    /// Item rows in display order (group headers left out), for type-to-select.
    private var itemRowOrder: [Int] { (0..<table.numberOfRows).filter { item(atRow: $0) != nil } }

    func makeTypeSelect() -> ListTypeSelect {
        ListTypeSelect(view: table, names: { [weak self] in
            guard let self else { return [] }
            return self.itemRowOrder.compactMap { self.item(atRow: $0)?.name }
        }, current: { [weak self] in
            guard let self else { return nil }
            let focus = self.table.focusRow ?? self.table.selectedRow
            return self.itemRowOrder.firstIndex(of: focus)
        }, select: { [weak self] index in
            guard let self else { return }
            let rows = self.itemRowOrder
            guard rows.indices.contains(index) else { return }
            self.table.focusRow = nil
            self.table.selectRowIndexes([rows[index]], byExtendingSelection: false)
            self.table.scrollRowToVisible(rows[index])
        })
    }
}

/// Details: Explorer's Ctrl+arrows (move the focus, keep the selection) and Ctrl+Space (select or deselect the
/// focused item), as ⌥⌘↑/↓/Home/End and ⌥Space like the icon layouts (DEC-accessibility-3); the Control
/// versions work too when macOS passes them through. After a focus move, plain arrows continue from the focused
/// row, and ⇧arrows extend the selection to it.
enum DetailsFocusKeys {
    static func handle(_ event: NSEvent, table: FileTableView, mods: NSEvent.ModifierFlags) -> Bool {
        let code = Int(event.keyCode)
        let vertical = [125: 1, 126: -1, 115: Int.min, 119: Int.max][code]
        let focusModifier = mods == [.option, .command] || mods == .control
        if let step = vertical, focusModifier {
            moveFocus(table, by: step)
            return true
        }
        if code == 49, mods == .option || mods == .control {
            guard let focus = table.focusRow ?? (table.selectedRow >= 0 ? table.selectedRow : nil) else { return true }
            var rows = table.selectedRowIndexes
            if rows.contains(focus) { rows.remove(focus) } else { rows.insert(focus) }
            table.selectRowIndexes(rows, byExtendingSelection: false)
            table.focusRow = focus
            announce(table, row: focus)
            return true
        }
        // Plain / ⇧ arrows continue from a parted focus instead of the table's own anchor.
        if let focus = table.focusRow, let step = vertical, abs(step) == 1, mods.subtracting(.shift).isEmpty {
            guard let target = itemRow(table, from: focus, step: step) else { return true }
            table.focusRow = nil
            if mods.contains(.shift) {
                let range = min(focus, target)...max(focus, target)
                table.selectRowIndexes(IndexSet(range.filter { isItemRow(table, $0) }), byExtendingSelection: true)
            } else {
                table.selectRowIndexes([target], byExtendingSelection: false)
            }
            table.scrollRowToVisible(target)
            return true
        }
        return false
    }

    private static func moveFocus(_ table: FileTableView, by step: Int) {
        let rows = (0..<table.numberOfRows).filter { isItemRow(table, $0) }
        guard let first = rows.first, let last = rows.last else { return }
        let start = table.focusRow ?? (table.selectedRow >= 0 ? table.selectedRow : nil)
        let target: Int
        switch step {
        case Int.min: target = first
        case Int.max: target = last
        default: target = start.flatMap { itemRow(table, from: $0, step: step) } ?? (start ?? (step > 0 ? first : last))
        }
        table.focusRow = target
        table.scrollRowToVisible(target)
        announce(table, row: target)
    }

    private static func isItemRow(_ table: FileTableView, _ row: Int) -> Bool {
        (table.delegate as? DetailsViewController)?.item(atRow: row) != nil
    }

    /// The next item row (group headers skipped) in the direction of `step`, or nil at the end.
    private static func itemRow(_ table: FileTableView, from row: Int, step: Int) -> Int? {
        var r = row + step
        while r >= 0, r < table.numberOfRows {
            if isItemRow(table, r) { return r }
            r += step
        }
        return nil
    }

    /// VoiceOver hears the focused item and whether it's selected (the table's own focus follows the selection).
    private static func announce(_ table: FileTableView, row: Int) {
        guard let item = (table.delegate as? DetailsViewController)?.item(atRow: row) else { return }
        let state = table.selectedRowIndexes.contains(row) ? L10n.tr("selected") : L10n.tr("not selected")
        Announcer.announce(L10n.format("%@, %@", item.name, state), in: table.window, priority: .high)
    }
}
