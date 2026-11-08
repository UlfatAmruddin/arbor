import AppKit
import ArborCore

/// Keeps Shift-arrow range selection working across a reload.
///
/// NSTableView remembers the anchor and the moving end of a range by row number. When a folder changes
/// while a range is selected (a file appears inside the range), the selection is restored by item, but
/// the remembered rows now point at other items, so the next ⇧↑ grew the range instead of shrinking it
/// (docs/ACCEPTANCE.md, T08). The ends are remembered by item and re-applied after the reload.
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

    /// Selects the same rows again, anchor first and lead last, so ⇧↑/⇧↓ continue from the same items.
    func restoreSelectionEnds(_ ends: SelectionEnds?) {
        guard let ends else { return }
        let selected = table.selectedRowIndexes
        guard selected.count > 1,
              let anchorIndex = items.firstIndex(where: { $0.url == ends.anchor }), let anchorRow = itemRows[anchorIndex],
              let leadIndex = items.firstIndex(where: { $0.url == ends.lead }), let leadRow = itemRows[leadIndex],
              selected.contains(anchorRow), selected.contains(leadRow), anchorRow != leadRow else { return }
        var middle = selected
        middle.remove(anchorRow)
        middle.remove(leadRow)
        table.selectRowIndexes([anchorRow], byExtendingSelection: false)
        if !middle.isEmpty { table.selectRowIndexes(middle, byExtendingSelection: true) }
        table.selectRowIndexes([leadRow], byExtendingSelection: true)
    }
}
