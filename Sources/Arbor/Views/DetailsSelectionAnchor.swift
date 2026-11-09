import AppKit
import ArborCore

/// Keeps Shift-arrow range selection working across a reload (T08). NSTableView tracks range ends by row,
/// which point at other items after a reload; so the ends are kept by item and re-applied.
struct SelectionEnds {
    let anchor: URL
    let lead: URL
}

extension DetailsViewController {
    /// The ends of the contiguous run that holds the most recently selected row.
    func currentSelectionEnds() -> SelectionEnds? {
        let selected = table.selectedRowIndexes
        let lead = table.selectedRow
        guard selected.count > 1, lead >= 0, selected.contains(lead), let leadItem = item(atRow: lead) else { return nil }
        var low = lead, high = lead
        while low > 0, selected.contains(low - 1) { low -= 1 }
        while selected.contains(high + 1) { high += 1 }
        let anchorRow = lead == low ? high : low
        guard let anchorItem = item(atRow: anchorRow) else { return nil }
        return SelectionEnds(anchor: anchorItem.url, lead: leadItem.url)
    }

    /// Reselects anchor first, lead last, so ⇧↑/⇧↓ continue from the same items.
    func restoreSelectionEnds(_ ends: SelectionEnds?) {
        guard let ends else { return }
        let selected = table.selectedRowIndexes
        guard selected.count > 1,
              let anchorIndex = items.firstIndex(where: { $0.url == ends.anchor }), let anchorRow = itemRows[anchorIndex],
              let leadIndex = items.firstIndex(where: { $0.url == ends.lead }), let leadRow = itemRows[leadIndex],
              selected.contains(anchorRow), selected.contains(leadRow), anchorRow != leadRow else { return }
        isRestoringSelectionEnds = true
        defer { isRestoringSelectionEnds = false }
        var middle = selected
        middle.remove(anchorRow)
        middle.remove(leadRow)
        table.selectRowIndexes([anchorRow], byExtendingSelection: false)
        if !middle.isEmpty { table.selectRowIndexes(middle, byExtendingSelection: true) }
        table.selectRowIndexes([leadRow], byExtendingSelection: true)
    }
}
