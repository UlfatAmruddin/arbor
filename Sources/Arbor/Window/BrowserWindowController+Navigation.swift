import AppKit
import ArborCore

extension BrowserWindowController {
    // MARK: - Navigation (spec §5.1)
    //
    // A request asks the location's provider for content. History is only committed once the
    // load succeeds, so a failed navigation keeps the previous location. Results for a request
    // that has since been superseded are dropped.

    enum NavRequest {
        case visit(Location, select: [String], selectURLs: [URL])
        case back, forward, reload
    }

    func navigate(to location: Location, select: [String] = []) {
        request(.visit(location, select: select, selectURLs: []), tab: activeTab)
    }

    func navigate(to url: URL, select: [String] = []) { navigate(to: .folder(url), select: select) }

    func goBack() { request(.back, tab: activeTab) }
    func goForward() { request(.forward, tab: activeTab) }
    func reload() { request(.reload, tab: activeTab) }

    /// Up: parent folder, selecting the folder just left; a volume root goes to This Mac (FE-002).
    func goUp() {
        let current = location
        guard let parent = current.parent() else { NSSound.beep(); return }
        var urls: [URL] = []
        if let url = current.folderURL { urls = [url] }
        if case .archive(let file, _) = current, case .folder = parent { urls = [file] }
        var names: [String] = []
        // Leaving an archive that was opened from inside another one selects it in the outer archive.
        if case .archive(let file, let inner) = current, inner.isEmpty, case .archive = parent { names = [file.lastPathComponent] }
        request(.visit(parent, select: names, selectURLs: urls), tab: activeTab)
    }

    var canGoUp: Bool { location.parent() != nil }

    func captureViewState(_ tab: TabState) {
        if tab === activeTab, tab.showsPage, let page = tab.page as? LocationPageViewState {
            tab.selectedNames = page.savedSelection
            tab.topVisibleName = page.savedScroll
            tab.selectedURLs = []
            return
        }
        guard tab === activeTab, tab.displayedLocation != nil, let view = itemView, !tab.showsPage else { return }
        tab.selectedNames = view.selectedNames
        tab.selectedURLs = view.selectedItems.map(\.url)
        tab.topVisibleName = view.topVisibleName
    }

    func request(_ request: NavRequest, tab: TabState) {
        if tab === activeTab, tab.displayedLocation == tab.location, !tab.restoreOnDisplay {
            captureViewState(tab)
            tab.history.saveState(selectedNames: tab.selectedNames, selectedURLs: tab.selectedURLs, topVisibleName: tab.topVisibleName)
        }
        var target: Location
        var select: [String]? = nil
        var selectURLs: [URL] = []
        var top: String? = nil
        switch request {
        case .visit(let location, let names, let urls):
            target = location; select = names; selectURLs = urls
        case .back:
            guard let entry = tab.history.peekBack() else { return }
            target = entry.location; select = entry.selectedNames; top = entry.topVisibleName
            tab.selectedNames = entry.selectedNames; tab.selectedURLs = entry.selectedURLs   // display() restores by URL
        case .forward:
            guard let entry = tab.history.peekForward() else { return }
            target = entry.location; select = entry.selectedNames; top = entry.topVisibleName
            tab.selectedNames = entry.selectedNames; tab.selectedURLs = entry.selectedURLs
        case .reload:
            target = tab.displayedLocation ?? tab.location
        }
        if case .folder(let url) = target { target = .folder(url.standardizedFileURL) }

        let provider = LocationRegistry.provider(for: target)
        let token = UUID()
        tab.loadToken = token
        tab.quietToken = tab.quietReload ? token : nil
        tab.quietReload = false
        tab.pendingLoad?.cancel()
        let slow = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab.loadToken == token, tab === self.activeTab else { return }
            self.statusBar.setMessage(L10n.format("Loading “%@”…", "\(provider.title(for: target))"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: slow)
        let context = LocationLoadContext(showHidden: Prefs.showHidden, host: self)
        tab.pendingLoad = provider.load(target, context: context) { [weak self, weak tab] result in
            slow.cancel()
            guard let self, let tab, tab.loadToken == token, self.tabs.contains(where: { $0 === tab }) else { return }
            self.finish(request, tab: tab, target: target, result: result, select: select, selectURLs: selectURLs, top: top)
        }
    }

    private func finish(_ request: NavRequest, tab: TabState, target: Location, result: Result<LocationContent, Error>,
                        select: [String]?, selectURLs: [URL], top: String?) {
        tab.pendingLoad = nil
        switch result {
        case .failure(let error):
            loadFailed(request, tab: tab, target: target, error: error)
        case .success(let content):
            if case .reload = request, tab.quietToken == tab.loadToken, case .items(let listed) = content,
               tab.displayedLocation == target, !tab.showsPage,
               !tab.restoreOnDisplay, tab.renameAfterLoad == nil, let shown = tab.items, shown.count <= listed.count,
               shown == WindowHooks.filter(listed, target) {
                return   // Nothing changed (metadata-only event, tab switch): keep rows, selection and scroll as they are.
            }
            switch request {
            case .visit(let location, let names, _): tab.history.visit(location, selectedNames: names)
            case .back: tab.history.goBack()
            case .forward: tab.history.goForward()
            case .reload: break
            }
            if case .visit = request { NotificationCenter.default.post(name: LocationEvents.didVisit, object: self, userInfo: ["location": target]) }
            let changed = tab.displayedLocation != target
            tab.displayedLocation = target
            if changed {
                tab.searchText = ""
                if tab === activeTab {
                    searchBox.text = ""
                    statusBar.setMessage(nil)
                    search.locationDidChange(target)
                }
            }
            var names = select
            switch content {
            case .items(let listed):
                let items = WindowHooks.filter(listed, target)
                tab.showsPage = false
                tab.page = nil
                tab.items = items
                if !selectURLs.isEmpty {
                    let wanted = Set(selectURLs.map { Location.folder($0) })
                    let matched = items.filter { wanted.contains(.folder($0.url)) }
                    names = matched.map(\.name)
                    // Restored by URL in display(): names can repeat (search results, libraries).
                    tab.selectedNames = matched.map(\.name)
                    tab.selectedURLs = matched.map(\.url)
                }
            case .custom(let page):
                tab.showsPage = true
                tab.items = nil
                tab.page = tab === activeTab ? page : nil
            }
            var explicit: [String]? = (names?.isEmpty == false) ? names : (changed ? [] : nil)
            var scrollTo = top
            var reset = changed
            if tab.restoreOnDisplay {
                tab.restoreOnDisplay = false
                explicit = tab.selectedNames
                scrollTo = tab.topVisibleName
                reset = true
            }
            WindowHooks.willDisplay.send((self, tab, target, changed))
            if tab === activeTab {
                display(tab, select: explicit, top: scrollTo, locationChanged: reset)
                if changed || watchToken == nil { startWatching(tab) }
                if let rename = tab.renameAfterLoad, tab.items?.contains(where: { $0.name == rename }) == true {
                    tab.renameAfterLoad = nil
                    itemView?.beginRename(named: rename, text: nil)
                }
            } else if let names = explicit {
                tab.selectedNames = names
                if changed { tab.topVisibleName = nil }
            }
            reloadTabStrip()
            updateChrome()
        }
    }

    private func loadFailed(_ request: NavRequest, tab: TabState, target: Location, error: Error) {
        let isActive = tab === activeTab
        if case .reload = request, let url = target.folderURL {
            // The folder we were showing went away: walk up to the nearest one that still exists.
            var parent = url
            while !FileManager.default.fileExists(atPath: parent.path), let up = NavigationHistory.parent(of: parent) { parent = up }
            if isActive { statusBar.setMessage(L10n.format("“%@” is no longer available.", "\(url.lastPathComponent)"), isError: true) }
            if parent != url { self.request(.visit(.folder(parent), select: [], selectURLs: []), tab: tab) }
            return
        }
        if isActive { statusBar.setMessage(error.localizedDescription, isError: true) }
        if tab.displayedLocation == nil {
            if target != .home { self.request(.visit(.home, select: [], selectURLs: []), tab: tab) }
            return
        }
        if isActive {
            NSAlert.show(L10n.format("Can't open “%@”", "\(LocationRegistry.provider(for: target).title(for: target))"), error.localizedDescription, in: window)
        }
    }

    func startWatching(_ tab: TabState) {
        guard let shown = tab.displayedLocation else { watchToken = nil; return }
        watchToken = LocationRegistry.provider(for: shown).watch(shown) { [weak self, weak tab] in
            guard let self, let tab, tab === self.activeTab else { return }
            tab.quietReload = true
            self.request(.reload, tab: tab)
        }
    }
}
