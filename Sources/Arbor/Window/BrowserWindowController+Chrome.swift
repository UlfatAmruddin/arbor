import AppKit
import ArborCore

extension BrowserWindowController {
    // MARK: - Chrome

    /// Redraws tab titles and chrome after a setting that affects them changed.
    func refreshChrome() {
        reloadTabStrip()
        updateChrome()
    }

    func updateChrome() {
        guard !tabs.isEmpty else { return }
        let tab = activeTab
        let shown = tab.displayedLocation ?? tab.location
        addressBar.location = shown
        searchBox.placeholder = search.placeholder(for: shown)
        navPane.reveal(shown)
        navBar.back.isEnabled = tab.history.canGoBack
        navBar.forward.isEnabled = tab.history.canGoForward
        navBar.up.isEnabled = shown.parent() != nil
        updateNavigationTooltips(tab: tab, shown: shown)
        let ctx = context(surface: .commandBar, sender: nil)
        commandBar.update(ctx)
        statusBar.update(ctx)
        if tab.showsPage {
            statusBar.setSummary((tab.page as? LocationPageStatus)?.statusSummary ?? "")
        } else if tab.items != nil {
            let summary = StatusText.explorerSummary(visible: tab.visibleItems.count, total: tab.items?.count ?? 0,
                                                     query: tab.searchText, selected: selectedItems)
            let detail = LocationRegistry.provider(for: shown).statusDetail(for: shown)
            statusBar.setSummary(detail.map { summary + "  " + $0 } ?? summary)
        } else {
            statusBar.setSummary("")
        }
        statusBar.setJob(OperationCenter.shared.statusLine)
        if !sidePane.isHidden { sidePane.update(selection: selectedItems, location: shown) }
    }
}
