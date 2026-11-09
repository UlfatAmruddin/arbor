import AppKit
import ArborCore

/// "› Filtered" in the address bar (FE-039, DEC-grouping-18): removes filters; never a location or history entry.
enum FilterAddressAnnotation {
    static func annotation(for tab: TabState) -> AddressAnnotation? {
        guard !tab.showsPage, let options = ViewOptions.existingOptions(for: tab), !options.filters.isEmpty else { return nil }
        let columns = options.filters.orderedColumns(options.columns.ids)
        let title = columns.count == 1 ? L10n.tr("Filtered") : L10n.format("Filtered (%d)", columns.count)
        return AddressAnnotation(title: title, tooltip: tooltip(columns), menu: { [weak tab] in menu(for: tab) })
    }

    private static func tooltip(_ columns: [ColumnID]) -> String {
        let titles = columns.map(ColumnCatalog.title)
        let names = ListFormatter.localizedString(byJoining: titles)
        return titles.count == 1 ? L10n.format("Filtered by %@.", names)
            : L10n.format("Filtered by %@. Items must match all of them.", names)
    }

    private static func menu(for tab: TabState?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let tab, let options = ViewOptions.existingOptions(for: tab) else { return menu }
        let summaries = options.filters.summaries(order: options.columns.ids, items: tab.items ?? [], lookup: DetailsDepth.lookup)
        menu.addItem(.sectionHeader(title: summaries.count == 1 ? L10n.tr("Choose to remove this filter.")
                                        : L10n.tr("Items must match all of these. Choose one to remove it.")))
        let remove = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.tr("Remove filter"))
        for summary in summaries {
            menu.addItem(ClosureMenuItem(summary.line, image: remove) { [weak tab] in
                DetailsDepth.clearFilters(tab, column: summary.column)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.tr("Clear Filters")) { [weak tab] in DetailsDepth.clearFilters(tab) })
        return menu
    }
}
