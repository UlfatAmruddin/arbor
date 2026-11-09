import AppKit
import ArborCore

/// VoiceOver can't hover to find a header's ▾, so the file list offers a "Filter by …" action per column (SPEC 16.2).
extension FileTableView {
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let details = delegate as? DetailsViewController else { return super.accessibilityCustomActions() }
        return details.filterableColumns.map { id in
            NSAccessibilityCustomAction(name: L10n.format("Filter by %@", "\(ColumnCatalog.title(id))")) { [weak details] in
                details?.showFilter(id)
                return details != nil
            }
        }
    }
}
