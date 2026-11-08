import AppKit
import ArborCore

extension BrowserWindowController {
    // MARK: - Display

    func showBlank() {
        shownPage?.view.removeFromSuperview()
        shownPage = nil
        itemView?.view.isHidden = true
    }

    /// Puts the tab's content on screen: its items in the item view for its mode, or its page.
    func display(_ tab: TabState, select: [String]?, top: String?, locationChanged: Bool) {
        if tab.showsPage, let page = tab.page {
            var restore: (selection: [String], scroll: String?)?
            if shownPage !== page {
                shownPage?.view.removeFromSuperview()
                embed(page.view)
                shownPage = page
                // A new page for the place (Back, Forward, Refresh, tab switch): put its selection back.
                if page is LocationPageViewState { restore = (select ?? tab.selectedNames, top ?? (select == nil ? tab.topVisibleName : nil)) }
            }
            itemView?.view.isHidden = true
            if let restore, let stateful = page as? LocationPageViewState, !restore.selection.isEmpty || restore.scroll != nil {
                DispatchQueue.main.async { stateful.restoreViewState(selection: restore.selection, scroll: restore.scroll) }
            }
            return
        }
        shownPage?.view.removeFromSuperview()
        shownPage = nil
        let view = ensureItemView(for: tab.viewMode)
        view.view.isHidden = false
        view.sortOrder = tab.sortOrder
        let location = tab.displayedLocation ?? tab.location
        let provider = LocationRegistry.provider(for: location)
        let visible = tab.visibleItems
        let empty = tab.items?.isEmpty == false && visible.isEmpty
            ? "No items match “\(tab.searchText)”." : provider.emptyText(for: location)
        // Restoring the tab's own selection: names can repeat in search results, so selecting by
        // name could add items the user never picked (and Delete would then take them too).
        let savedURLs = select != nil && select == tab.selectedNames
            && Set(tab.selectedURLs.map(\.lastPathComponent)) == Set(tab.selectedNames) ? tab.selectedURLs : []
        view.display(ItemViewUpdate(items: visible, folder: provider.targetFolder(for: location), select: select,
                                    scrollTo: top, locationChanged: locationChanged, emptyText: empty,
                                    allowsEditing: provider.allowsItemEditing(in: location), location: location))
        if !savedURLs.isEmpty, view.selectedItems.count > savedURLs.count {
            view.select(urls: savedURLs)
        }
        WindowHooks.didDisplay.send((self, tab))
    }

    func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
    }

    /// Changes the active tab's view mode (unregistered modes show Details).
    func setViewMode(_ mode: ViewMode) {
        let tab = activeTab
        captureViewState(tab)
        tab.viewMode = mode
        Prefs.defaultViewMode = mode
        if !tab.showsPage, tab.items != nil {
            display(tab, select: tab.selectedNames, top: tab.topVisibleName, locationChanged: false)
        }
        updateChrome()
        WindowHooks.viewStateChanged.send((self, tab))
    }

    func setSortOrder(_ order: FileSortOrder) {
        activeTab.sortOrder = order
        Prefs.sortOrder = order
        if !activeTab.showsPage {
            // Large listings sort in the background; the rows (and the selection) update when they're ready.
            let tab = activeTab
            let deferred = tab.sortInBackground { [weak self] in
                guard let self, tab === self.activeTab, !tab.showsPage else { return }
                self.display(tab, select: nil, top: nil, locationChanged: false)
                self.updateChrome()
            }
            if !deferred { display(activeTab, select: nil, top: nil, locationChanged: false) }
        }
        updateChrome()
        WindowHooks.viewStateChanged.send((self, activeTab))
    }

    /// Default search: filter the visible folder (DEC-014).
    func applyFilter(_ text: String) {
        if activeTab.showsPage, let page = activeTab.page as? LocationPageFiltering { page.applyFilter(text) }
        activeTab.searchText = text
        if !activeTab.showsPage { display(activeTab, select: nil, top: nil, locationChanged: false) }
        updateChrome()
    }

    var selectedItems: [FileItem] {
        if !tabs.isEmpty, activeTab.showsPage, let page = activeTab.page as? LocationPageSelection { return page.selectedItems }
        guard !tabs.isEmpty, !activeTab.showsPage, let view = itemView else { return [] }
        return view.selectedItems
    }

    var visibleItems: [FileItem] { tabs.isEmpty || activeTab.showsPage ? [] : activeTab.visibleItems }

    /// Text field editing (address, search, rename) is in progress.
    var isEditingText: Bool { window?.firstResponder is NSTextView }
}
