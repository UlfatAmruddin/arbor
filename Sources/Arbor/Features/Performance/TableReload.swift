import AppKit

extension NSTableView {
    /// Reloads every row like `reloadData()` but recycles the existing cell and row views.
    ///
    /// Measured on macOS 26: `reloadData()` throws away every visible cell view, so each folder change
    /// rebuilt a screenful of cells (about half of a 1,000-entry folder's navigation time), while
    /// `reloadData(forRowIndexes:columnIndexes:)` hands them back through `makeView(withIdentifier:)`.
    /// Only for tables whose row kinds don't change (no group rows appearing or disappearing).
    func reloadKeepingViews() {
        noteNumberOfRowsChanged()
        let rows = numberOfRows
        guard rows > 0, numberOfColumns > 0 else { return }
        reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows), columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
    }
}
