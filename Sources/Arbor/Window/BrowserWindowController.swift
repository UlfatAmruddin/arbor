import AppKit
import Quartz
import ArborCore

/// One Explorer window: a custom tab strip, navigation row, command bar, navigation pane, item
/// view, side pane and status bar. Views exist once per window; each tab is a `TabState`.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation,
                                     ItemViewDelegate, NavigationPaneDelegate, TabStripDelegate, LocationHost,
                                     QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onClose: (() -> Void)?

    private(set) var tabs: [TabState] = []
    private(set) var activeIndex = 0
    var activeTab: TabState { tabs[activeIndex] }
    /// The active tab's location (the folder or place on screen).
    var location: Location { activeTab.location }
    var history: NavigationHistory { activeTab.history }

    let tabStrip = TabStripView()
    let navBar = NavigationBar()
    var addressBar: AddressBar { navBar.address }
    var searchBox: SearchBox { navBar.search }
    let commandBar = CommandBarView()
    let navPane = NavigationPaneController()
    let sidePane = SidePaneContainer()
    let statusBar = StatusBarView()
    private let contentHost = ThemeBackgroundView(Theme.contentBackground)
    private let split = ExplorerSplitView()
    /// The view for the active tab's items (nil while a custom page is shown).
    private(set) var itemView: ItemViewController?
    private var shownPage: NSViewController?
    private var watchToken: AnyObject?
    private var observers: [NSObjectProtocol] = []
    private lazy var search: SearchController = SearchRegistry.make(for: self)
    private var quickLookActive = false

    /// The frontmost browser window (key, then main, then any).
    static var active: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.delegate as? AppDelegate)?.controllers.last
    }

    init(tabs initial: [TabState], activeIndex: Int = 0, initialSelection: [String] = []) {
        let window = BrowserWindow()
        super.init(window: window)
        window.delegate = self
        buildLayout()
        observe()
        // Headless test runs neither read nor write the user's saved window geometry.
        if AppDelegate.isHeadless || !window.setFrameAutosaveName("ArborBrowser") { window.center() }
        if window.frame.origin == .zero { window.center() }
        tabs = initial.isEmpty ? [TabState(location: .home)] : initial
        self.activeIndex = min(max(activeIndex, 0), tabs.count - 1)
        activeTab.isActive = true
        if activeTab.displayedLocation == nil {
            request(.visit(activeTab.location, select: initialSelection, selectURLs: []), tab: activeTab)
        } else {
            activate(activeTab)
        }
        reloadTabStrip()
        WindowHooks.didCreate.forEach { $0(self) }
    }

    convenience init(location: Location, initialSelection: [String] = []) {
        self.init(tabs: [TabState(location: location)], initialSelection: initialSelection)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        guard let window else { return }
        let content = ThemeBackgroundView(Theme.toolbarBackground)
        content.translatesAutoresizingMaskIntoConstraints = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(navPane.view)
        split.addArrangedSubview(contentHost)
        split.addArrangedSubview(sidePane)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(259), forSubviewAt: 2)
        split.translatesAutoresizingMaskIntoConstraints = false
        navPane.view.isHidden = !Prefs.navigationPaneVisible

        for v in [tabStrip, navBar, commandBar, split, statusBar] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: Theme.tabStripHeight),
            navBar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            commandBar.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: split.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        if !AppDelegate.isHeadless { split.autosaveName = "ArborPanes2" }
        content.layoutSubtreeIfNeeded()
        if AppDelegate.isHeadless || UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ArborPanes2") == nil {
            split.setPosition(Theme.navPaneWidth, ofDividerAt: 0)
        }
        showSidePane(Prefs.sidePane)

        tabStrip.delegate = self
        navPane.delegate = self
        commandBar.contextProvider = { [weak self] surface, sender in
            self?.context(surface: surface, sender: sender) ?? CommandContext(window: nil, location: nil, surface: surface)
        }
        statusBar.contextProvider = commandBar.contextProvider
        statusBar.onCancelJobs = { OperationCenter.shared.cancelAll() }
        navBar.back.onClick = { [weak self] _ in self?.goBack() }
        navBar.forward.onClick = { [weak self] _ in self?.goForward() }
        navBar.up.onClick = { [weak self] _ in self?.goUp() }
        addressBar.onNavigate = { [weak self] location in self?.navigate(to: location) }
        addressBar.onSubmit = { [weak self] text in self?.submitAddress(text) }
        addressBar.onRefresh = { [weak self] in self?.reload() }
        searchBox.onChange = { [weak self] text in self?.search.queryChanged(text) }
        searchBox.onSubmit = { [weak self] text in self?.search.submit(text) }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] note in
            self?.prefsChanged(note.userInfo?["key"] as? String)
        })
        observers.append(nc.addObserver(forName: QuickAccess.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildNavPane()
            self?.updateChrome()
        })
        observers.append(nc.addObserver(forName: FileClipboard.changed, object: nil, queue: .main) { [weak self] _ in
            self?.itemView?.reloadRows()
            self?.updateChrome()
        })
        observers.append(nc.addObserver(forName: OperationCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.statusBar.setJob(OperationCenter.shared.statusLine)
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.volumesChanged(note)
            })
        }
    }

    private func prefsChanged(_ key: String?) {
        switch key {
        case "showHidden":
            rebuildNavPane()
            tabs.filter { $0 !== activeTab }.forEach { $0.items = nil }
            reload()
        case "showExtensions", "compactView", "itemCheckBoxes":
            itemView?.reloadRows()
        case "sidePane":
            showSidePane(Prefs.sidePane)
            updateChrome()
        case "navigationPaneVisible":
            navPane.view.isHidden = !Prefs.navigationPaneVisible
            updateChrome()
        default:
            break
        }
        split.adjustSubviews()
    }

    private func rebuildNavPane() {
        navPane.rebuild()
        navPane.reveal(location)
    }

    private func volumesChanged(_ note: Notification) {
        rebuildNavPane()
        guard note.name == NSWorkspace.didUnmountNotification,
              let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        for tab in tabs {
            guard let url = tab.location.folderURL, FileOps.isSameOrInside(url, volume) else { continue }
            if let handler = Self.volumeUnmountHandler, handler(self, tab, volume) { continue }
            if tab === activeTab { statusBar.setMessage("“\(displayName(of: volume))” was disconnected.", isError: true) }
            request(.visit(.thisMac, select: [], selectURLs: []), tab: tab)
        }
    }

    // MARK: - Side pane (B6)

    func showSidePane(_ id: String) {
        let shown = sidePane.show(id, selection: selectedItems, location: tabs.isEmpty ? nil : location)
        let wasHidden = sidePane.isHidden
        sidePane.isHidden = !shown
        split.adjustSubviews()
        if shown, wasHidden || sidePane.frame.width < 220 {
            split.setPosition(split.bounds.width - 320, ofDividerAt: 1)
        }
    }

    /// Toggles a side pane; Preview and Details are mutually exclusive (Alt+P / Alt+Shift+P).
    func toggleSidePane(_ id: String) {
        Prefs.sidePane = Prefs.sidePane == id ? "" : id
    }

    // MARK: - Tabs

    func tab(at index: Int?) -> TabState? {
        guard !tabs.isEmpty else { return nil }
        guard let index else { return activeTab }
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    private func reloadTabStrip() {
        tabStrip.reload(items: tabs.map { TabStripItem(title: $0.title, icon: $0.icon, tooltip: $0.location.folderURL?.path ?? $0.title) },
                        selected: activeIndex)
        window?.title = activeTab.title
    }

    /// Opens a tab. New tabs go to the end, like Explorer.
    @discardableResult
    func openTab(_ location: Location, select: [String] = [], activate shouldActivate: Bool = true, state: TabState? = nil) -> TabState {
        let tab = state ?? TabState(location: location, viewMode: Prefs.defaultViewMode, sortOrder: Prefs.sortOrder)
        tabs.append(tab)
        if shouldActivate {
            switchTo(tabs.count - 1, initialSelection: select)
        } else {
            request(.visit(tab.location, select: select, selectURLs: []), tab: tab)
        }
        reloadTabStrip()
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        switchTo(index)
        reloadTabStrip()
    }

    private func switchTo(_ index: Int, initialSelection: [String] = []) {
        if tabs.indices.contains(activeIndex) { deactivate(tabs[activeIndex]) }
        activeIndex = index
        activate(activeTab, initialSelection: initialSelection)
    }

    private func deactivate(_ tab: TabState) {
        captureViewState(tab)
        tab.isActive = false
        tab.page = nil
        watchToken = nil
        if addressBar.isEditingPath { addressBar.endEditing() }
    }

    private func activate(_ tab: TabState, initialSelection: [String] = []) {
        tab.isActive = true
        searchBox.text = search.boxText(for: tab.displayedLocation ?? tab.location, filterText: tab.searchText)
        if tab.displayedLocation == nil {
            showBlank()
            request(.visit(tab.location, select: initialSelection, selectURLs: []), tab: tab)
        } else if tab.items != nil, !tab.showsPage {
            display(tab, select: tab.selectedNames, top: tab.topVisibleName, locationChanged: true)
            startWatching(tab)
            request(.reload, tab: tab)
        } else {
            tab.restoreOnDisplay = true
            showBlank()
            request(.reload, tab: tab)
        }
        updateChrome()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        let closing = tabs[index]
        closing.pendingLoad?.cancel()
        if index == activeIndex {
            closing.isActive = false
            tabs.remove(at: index)
            activeIndex = min(index, tabs.count - 1)
            watchToken = nil
            activate(activeTab)
        } else {
            tabs.remove(at: index)
            if index < activeIndex { activeIndex -= 1 }
        }
        reloadTabStrip()
        updateChrome()
    }

    func closeOtherTabs(except index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        if keep !== activeTab { selectTab(at: index) }
        tabs.filter { $0 !== keep }.forEach { $0.pendingLoad?.cancel() }
        tabs = [keep]
        activeIndex = 0
        reloadTabStrip()
        updateChrome()
    }

    func closeTabs(rightOf index: Int) {
        guard tabs.indices.contains(index), index < tabs.count - 1 else { return }
        if activeIndex > index { selectTab(at: index) }
        tabs[(index + 1)...].forEach { $0.pendingLoad?.cancel() }
        tabs.removeSubrange((index + 1)...)
        reloadTabStrip()
        updateChrome()
    }

    func duplicateTab(at index: Int) {
        guard let source = tab(at: index) else { return }
        if source === activeTab { captureViewState(source) }
        let copy = source.duplicate()
        tabs.insert(copy, at: index + 1)
        switchTo(index + 1, initialSelection: copy.selectedNames)
        reloadTabStrip()
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let active = activeTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeIndex = tabs.firstIndex { $0 === active } ?? 0
        reloadTabStrip()
    }

    /// Moves a tab, with its history, into a new window.
    func moveTabToNewWindow(at index: Int) {
        guard tabs.count > 1, let tab = takeTab(at: index) else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(tabs: [tab])
    }

    /// Removes a tab, keeping its history and view state, so another window can adopt it (tear-off and
    /// merge, FE-020). Taking the last tab closes this window.
    func takeTab(at index: Int) -> TabState? {
        guard let tab = tab(at: index), tabs.indices.contains(index) else { return nil }
        if tab === activeTab { captureViewState(tab) }
        tab.isActive = false
        tab.page = nil
        // A load in flight would report back to this window; the adopting window reloads instead.
        tab.pendingLoad?.cancel()
        tab.pendingLoad = nil
        tab.loadToken = UUID()
        let wasActive = index == activeIndex
        tabs.remove(at: index)
        if tabs.isEmpty {
            watchToken = nil
            window?.close()
            return tab
        }
        if wasActive {
            activeIndex = min(index, tabs.count - 1)
            watchToken = nil
            activate(activeTab)
        } else if index < activeIndex {
            activeIndex -= 1
        }
        reloadTabStrip()
        return tab
    }

    /// Inserts a tab taken from another window at `index` and switches to it.
    func adoptTab(_ tab: TabState, at index: Int) {
        let slot = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: slot)
        if slot <= activeIndex, tabs.count > 1 { activeIndex += 1 }
        switchTo(slot, initialSelection: tab.selectedNames)
        reloadTabStrip()
    }

    func selectNextTab(_ step: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex + step + tabs.count) % tabs.count)
    }

    // TabStripDelegate
    func tabStripSelect(_ index: Int) { selectTab(at: index) }
    func tabStripClose(_ index: Int) { closeTab(at: index) }
    func tabStripNewTab() { openTab(WindowHooks.startLocation()) }
    func tabStripMove(from: Int, to: Int) { moveTab(from: from, to: to) }
    func tabStripDetach(_ index: Int) { moveTabToNewWindow(at: index) }
    func tabStripMenu(for index: Int) -> NSMenu? {
        var ctx = context(surface: .tabContextMenu, sender: nil)
        ctx.tabIndex = index
        ctx.location = tabs[index].location
        return CommandDispatcher.shared.menu(for: .tabContextMenu, context: ctx)
    }

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

    private func captureViewState(_ tab: TabState) {
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
        tab.pendingLoad?.cancel()
        let slow = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab.loadToken == token, tab === self.activeTab else { return }
            self.statusBar.setMessage("Loading “\(provider.title(for: target))”…")
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
                    names = items.filter { wanted.contains(.folder($0.url)) }.map(\.name)
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
            WindowHooks.willDisplay.forEach { $0(self, tab, target, changed) }
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
            if isActive { statusBar.setMessage("“\(url.lastPathComponent)” is no longer available.", isError: true) }
            if parent != url { self.request(.visit(.folder(parent), select: [], selectURLs: []), tab: tab) }
            return
        }
        if isActive { statusBar.setMessage(error.localizedDescription, isError: true) }
        if tab.displayedLocation == nil {
            if target != .home { self.request(.visit(.home, select: [], selectURLs: []), tab: tab) }
            return
        }
        if isActive {
            NSAlert.show("Can't open “\(LocationRegistry.provider(for: target).title(for: target))”", error.localizedDescription, in: window)
        }
    }

    private func startWatching(_ tab: TabState) {
        guard let shown = tab.displayedLocation else { watchToken = nil; return }
        watchToken = LocationRegistry.provider(for: shown).watch(shown) { [weak self, weak tab] in
            guard let self, let tab, tab === self.activeTab else { return }
            self.request(.reload, tab: tab)
        }
    }

    // MARK: - Display

    private func showBlank() {
        shownPage?.view.removeFromSuperview()
        shownPage = nil
        itemView?.view.isHidden = true
    }

    /// Puts the tab's content on screen: its items in the item view for its mode, or its page.
    private func display(_ tab: TabState, select: [String]?, top: String?, locationChanged: Bool) {
        if tab.showsPage, let page = tab.page {
            if shownPage !== page {
                shownPage?.view.removeFromSuperview()
                embed(page.view)
                shownPage = page
            }
            itemView?.view.isHidden = true
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
        WindowHooks.didDisplay.forEach { $0(self, tab) }
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
    }

    /// Reuses the current item view if it can show `mode`, else builds the registered one (B4).
    private func ensureItemView(for mode: ViewMode) -> ItemViewController {
        let effective = ViewModeRegistry.effective(mode)
        if let current = itemView, current.canDisplay(effective) {
            if current.viewMode != effective { current.viewMode = effective }
            return current
        }
        let hadFocus = itemView.map { window?.firstResponder === $0.focusView } ?? false
        itemView?.view.removeFromSuperview()
        let view = ViewModeRegistry.make(effective)
        view.itemDelegate = self
        embed(view.view)
        itemView = view
        window?.initialFirstResponder = view.focusView
        if hadFocus { view.focus() }
        return view
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
        WindowHooks.viewStateChanged.forEach { $0(self, tab) }
    }

    func setSortOrder(_ order: FileSortOrder) {
        activeTab.sortOrder = order
        Prefs.sortOrder = order
        if !activeTab.showsPage { display(activeTab, select: nil, top: nil, locationChanged: false) }
        updateChrome()
        WindowHooks.viewStateChanged.forEach { $0(self, activeTab) }
    }

    /// Redraws tab titles and chrome after a setting that affects them changed (full path in title bar…).
    func refreshChrome() {
        reloadTabStrip()
        updateChrome()
    }

    /// Default search: filter the visible folder (DEC-014).
    func applyFilter(_ text: String) {
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

    // MARK: - Commands

    /// A context for the active tab, with a frozen selection snapshot.
    func context(surface: CommandSurface, sender: Any?) -> CommandContext {
        guard !tabs.isEmpty else { return CommandContext(window: self, location: nil, surface: surface, sender: sender) }
        let shown = activeTab.displayedLocation ?? activeTab.location
        return CommandContext(window: self, location: shown, selection: selectedItems,
                              targetFolder: LocationRegistry.provider(for: shown).targetFolder(for: shown),
                              surface: surface, sender: sender)
    }

    @discardableResult
    func perform(_ id: String, surface: CommandSurface = .script, sender: Any? = nil) -> Bool {
        CommandRegistry.shared.perform(id, context: context(surface: surface, sender: sender))
    }

    // Responder-chain actions (Edit menu): text fields get them first, then the window.
    @objc func cut(_ sender: Any?) { performMenuAction(#selector(cut(_:)), sender) }
    @objc func copy(_ sender: Any?) { performMenuAction(#selector(copy(_:)), sender) }
    @objc func paste(_ sender: Any?) { performMenuAction(#selector(paste(_:)), sender) }
    @objc override func selectAll(_ sender: Any?) { performMenuAction(#selector(selectAll(_:)), sender) }

    private func performMenuAction(_ action: Selector, _ sender: Any?) {
        guard let command = CommandRegistry.shared.command(forMenuAction: action) else { return }
        let ctx = context(surface: .menuBar, sender: sender)
        guard command.isAvailable(ctx), command.isEnabled(ctx) else { NSSound.beep(); return }
        command.perform(ctx)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let command = CommandRegistry.shared.command(forMenuAction: action) else { return true }
        return CommandDispatcher.shared.validate(command, item: menuItem, context: context(surface: .menuBar, sender: nil))
    }

    func contextMenu(for surface: CommandSurface) -> NSMenu {
        let ctx = context(surface: surface, sender: nil)
        return CommandDispatcher.shared.menu(for: surface == .itemContextMenu ? .itemContextMenu : .backgroundContextMenu, context: ctx)
    }

    // MARK: - Chrome

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

    // MARK: - Address bar

    private func submitAddress(_ text: String) {
        if let place = Location.keyword(text) {
            addressBar.endEditing()
            navigate(to: place)
            itemView?.focus()
            return
        }
        let base = location.folderURL ?? FileManager.default.homeDirectoryForCurrentUser
        switch PathResolver().resolve(text, relativeTo: base) {
        case .success(.folder(let url)):
            addressBar.endEditing()
            navigate(to: url)
            itemView?.focus()
        case .success(.file(let url)):
            addressBar.endEditing()
            navigate(to: url.deletingLastPathComponent(), select: [url.lastPathComponent])
            itemView?.focus()
        case .success(.network(let url)):
            addressBar.endEditing()
            if let handler = Self.networkAddressHandler, handler(self, url) { itemView?.focus(); return }
            NSWorkspace.shared.open(url)
            statusBar.setMessage("Connecting to \(url.host ?? url.absoluteString)… The share will appear under This Mac once it's mounted.")
            itemView?.focus()
        case .failure(let error):
            statusBar.setMessage(error.localizedDescription, isError: true)
            addressBar.showInvalid()
        }
    }

    /// Hook for `smb://` / `\\server\share` typed in the address bar; return true when handled (network feature).
    static var networkAddressHandler: ((BrowserWindowController, URL) -> Bool)?
    /// Hook for a tab showing a folder on a volume that was just unmounted; return true when handled
    /// (the network feature keeps such tabs on a "disconnected" page instead of going to This Mac).
    static var volumeUnmountHandler: ((BrowserWindowController, TabState, URL) -> Bool)?

    func focusAddressBar(text: String? = nil) { addressBar.beginEditing(text: text) }
    func focusSearch() { searchBox.focus() }

    // MARK: - LocationHost

    func openInNewTab(_ location: Location) { openTab(location) }
    func showStatusMessage(_ text: String?, isError: Bool) { statusBar.setMessage(text, isError: isError) }
    func reloadLocation() { reload() }

    // MARK: - File operations shared by commands

    /// Starts a copy/move job. When items land in the visible folder they are selected.
    func startTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL, preflighted: Bool = false,
                       then: ((TransferReport) -> Void)? = nil) {
        if !preflighted, let prompt = TransferPreflight.prompt(kind, urls, to: folder) {   // e.g. cloud hydration (FE-113)
            prompt.ask(in: window) { [weak self] go in if go { self?.startTransfer(kind, urls, to: folder, preflighted: true, then: then) } }
            return
        }
        OperationCenter.shared.start(kind, sources: urls, destination: folder, window: window) { [weak self] report in
            then?(report)
            guard let self else { return }
            let landedHere = report.committed.map(\.destination).filter {
                Location.folder($0.deletingLastPathComponent()) == self.location
            }
            if !landedHere.isEmpty {
                self.navigate(to: self.location, select: landedHere.map(\.lastPathComponent))
            }
            if report.wasCancelled {
                self.statusBar.setMessage("Transfer cancelled. Items already \(report.kind.pastVerb) were kept.")
            } else if report.problems.isEmpty, !report.committed.isEmpty {
                self.statusBar.setMessage("\(StatusText.items(report.committed.count)) \(report.kind.pastVerb) to “\(displayName(of: report.destination))”.")
            }
        }
    }

    /// Refreshes the active folder, selects `names` and optionally starts renaming one of them.
    func refreshSelecting(_ names: [String], rename: String? = nil) {
        activeTab.renameAfterLoad = rename
        navigate(to: location, select: names)
    }

    /// The item to select after removing `items`: the next remaining row, else the previous one.
    func neighbor(after items: [FileItem]) -> String? {
        let removed = Set(items.map(\.name))
        let rows = visibleItems
        guard let last = rows.lastIndex(where: { removed.contains($0.name) }) else { return nil }
        if let next = rows[(last + 1)...].first(where: { !removed.contains($0.name) }) { return next.name }
        return rows[..<last].last(where: { !removed.contains($0.name) })?.name
    }

    /// Opens items like Explorer: one folder navigates; several (or ⌘) open tabs; files open in their app.
    func open(_ items: [FileItem], inNewTab: Bool) {
        var locations: [Location] = []
        var files: [FileItem] = []
        for item in items {
            if let location = LocationRegistry.locationForOpening(item) { locations.append(location) } else { files.append(item) }
        }
        if locations.count == 1, files.isEmpty, !inNewTab {
            if WindowHooks.openFolder?(self, locations[0]) == true { return }
            navigate(to: locations[0])
            return
        }
        locations.forEach { openTab($0) }
        files.removeAll { InteractionHooks.openFile?(self, $0) == true }
        files.forEach { NSWorkspace.shared.open($0.url) }
        if !files.isEmpty { NotificationCenter.default.post(name: LocationEvents.didOpenFiles, object: self, userInfo: ["urls": files.map(\.url)]) }
    }

    // MARK: - ItemViewDelegate

    func itemViewOpen(_ items: [FileItem], inNewTab: Bool) { open(items, inNewTab: inNewTab) }

    func itemViewSelectionDidChange() {
        if !activeTab.showsPage, let view = itemView {
            activeTab.selectedNames = view.selectedNames
            activeTab.selectedURLs = view.selectedItems.map(\.url)
        }
        updateChrome()
        refreshQuickLook()
        WindowHooks.selectionChanged.forEach { $0(self) }
    }

    func itemViewContextMenu() -> NSMenu? {
        contextMenu(for: selectedItems.isEmpty ? .backgroundContextMenu : .itemContextMenu)
    }

    func itemViewRename(_ item: FileItem, to newName: String) -> Bool {
        if let handled = InteractionHooks.commitRename?(self, item, newName) { return handled }
        if !item.isFolder {
            let oldExt = NameRules.splitExtension(item.name, treatAsFolder: false).ext?.lowercased()
            let newExt = NameRules.splitExtension(newName, treatAsFolder: false).ext?.lowercased()
            if oldExt != newExt {
                let alert = NSAlert()
                alert.messageText = "Change the file name extension?"
                alert.informativeText = "If you change “.\(oldExt ?? "")” to “.\(newExt ?? "")”, the file might open in a different app or stop opening."
                alert.addButton(withTitle: "Use .\(newExt ?? "(none)")")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return false }
            }
        }
        do {
            let newURL = try Renamer.rename(item.url, to: newName)
            OperationCenter.shared.registerUndoRename(from: newURL, back: item.name)
            navigate(to: location, select: [newURL.lastPathComponent])
            return true
        } catch {
            NSAlert.show("Couldn't rename “\(item.name)”.", error.localizedDescription, in: nil)
            return false
        }
    }

    func itemViewTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL) {
        if InteractionHooks.drop?(self, kind, urls, folder) == true { return }
        startTransfer(kind, urls, to: folder)
    }

    func itemViewSortChanged(_ order: FileSortOrder) { setSortOrder(order) }

    func itemViewKey(_ event: NSEvent) -> Bool {
        let registry = CommandRegistry.shared
        guard let command = registry.command(for: event, scope: .itemView) ?? registry.command(for: event, scope: .window) else { return false }
        let ctx = context(surface: .keyboard, sender: nil)
        guard command.isAvailable(ctx) else { return false }
        if command.isEnabled(ctx) { command.perform(ctx) } else { NSSound.beep() }
        return true
    }

    // MARK: - NavigationPaneDelegate

    func navigationPaneNavigate(to location: Location) { navigate(to: location) }
    func navigationPaneOpenInNewTab(_ location: Location) { openTab(location) }
    func navigationPaneTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL) {
        if InteractionHooks.drop?(self, kind, urls, folder) == true { return }
        startTransfer(kind, urls, to: folder)
    }

    func navigationPaneMenu(for node: NavNode) -> NSMenu? {
        var ctx = context(surface: .treeContextMenu, sender: nil)
        ctx.selection = node.asItem.map { [$0] } ?? []
        ctx.targetFolder = node.url
        ctx.treeLocation = node.location
        return CommandDispatcher.shared.menu(for: .treeContextMenu, context: ctx)
    }

    // MARK: - Quick Look (Space)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func refreshQuickLook() {
        guard quickLookActive, let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        quickLookActive = true
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookActive = false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = selectedItems
        return index < items.count ? items[index].url as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let view = itemView?.focusView else { return false }
        view.keyDown(with: event)
        return true
    }

    // MARK: - Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { OperationCenter.shared.undoManager }

    func windowDidBecomeKey(_ notification: Notification) {
        updateChrome()
        (window as? BrowserWindow)?.layoutTrafficLights()
    }

    func windowDidResize(_ notification: Notification) { (window as? BrowserWindow)?.layoutTrafficLights() }

    func windowWillEnterFullScreen(_ notification: Notification) { tabStrip.leadingInset = 10 }

    func windowDidExitFullScreen(_ notification: Notification) {
        tabStrip.leadingInset = Theme.trafficLightInset
        (window as? BrowserWindow)?.layoutTrafficLights()
    }

    func windowWillClose(_ notification: Notification) {
        watchToken = nil
        tabs.forEach { $0.pendingLoad?.cancel() }
        sidePane.releaseAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        onClose?()
    }
}

/// Split view with a theme-colored hairline divider.
final class ExplorerSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.separator }
}
