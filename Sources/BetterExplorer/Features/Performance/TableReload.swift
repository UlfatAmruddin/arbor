import AppKit

extension NSTableView {
    /// Like `reloadData()` but reuses cell views, which it discards (macOS 26: ~half a 1,000-entry folder's nav time).
    /// Only for tables whose row kinds never change (no group rows coming or going).
    func reloadKeepingViews() {
        noteNumberOfRowsChanged()
        let rows = numberOfRows
        guard rows > 0, numberOfColumns > 0 else { return }
        reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows), columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
    }
}
