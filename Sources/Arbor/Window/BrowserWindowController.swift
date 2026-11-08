import AppKit
import ArborCore

/// One Explorer window. Views exist once per window; each tab is a `TabState`.
final class BrowserWindowController: NSWindowController, TabStripDelegate {
    var onClose: (() -> Void)?

    private(set) var tabs: [TabState] = []
    private(set) var activeIndex = 0
    var activeTab: TabState { tabs[activeIndex] }
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
    // Internals shared with the +*.swift extensions (no cross-file private); features use docs/ARCHITECTURE.md.
    let contentHost = ThemeBackgroundView(Theme.contentBackground)
    let split = ExplorerSplitView()
    /// Nil while a custom page is shown.
    private(set) var itemView: ItemViewController?
    var shownPage: NSViewController?
    var watchToken: AnyObject?
    var observers: [NSObjectProtocol] = []
    lazy var search: SearchController = SearchRegistry.make(for: self)
    var quickLookActive = false
    var navPaneRebuild: DispatchWorkItem?

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
        WindowHooks.didCreate.send(self)
    }

    convenience init(location: Location, initialSelection: [String] = []) {
        self.init(tabs: [TabState(location: location)], initialSelection: initialSelection)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Tabs

    func tab(at index: Int?) -> TabState? {
        guard !tabs.isEmpty else { return nil }
        guard let index else { return activeTab }
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    func reloadTabStrip() {
        tabStrip.reload(items: tabs.map { TabStripItem(title: $0.title, icon: $0.icon, tooltip: $0.location.folderURL?.path ?? $0.title) },
                        selected: activeIndex)
        window?.title = activeTab.title
    }

    /// Opens a tab at the end, like Explorer.
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

    private func switchTo(_ index: Int, initialSelection: [String] = [], initialURLs: [URL] = []) {
        if tabs.indices.contains(activeIndex) { deactivate(tabs[activeIndex]) }
        activeIndex = index
        activate(activeTab, initialSelection: initialSelection, initialURLs: initialURLs)
    }

    private func deactivate(_ tab: TabState) {
        captureViewState(tab)
        tab.isActive = false
        tab.page = nil
        watchToken = nil
        if addressBar.isEditingPath { addressBar.endEditing() }
    }

    private func activate(_ tab: TabState, initialSelection: [String] = [], initialURLs: [URL] = []) {
        tab.isActive = true
        searchBox.text = search.boxText(for: tab.displayedLocation ?? tab.location, filterText: tab.searchText)
        if tab.displayedLocation == nil {
            showBlank()
            request(.visit(tab.location, select: initialSelection, selectURLs: initialURLs), tab: tab)
        } else if tab.items != nil, !tab.showsPage {
            display(tab, select: tab.selectedNames, top: tab.topVisibleName, locationChanged: true)
            startWatching(tab)
            tab.quietReload = true
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
        switchTo(index + 1, initialSelection: copy.selectedNames, initialURLs: copy.selectedURLs)
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

    /// Detaches a tab with its history and view state for another window to adopt (FE-020); last tab closes the window.
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
        switchTo(slot, initialSelection: tab.selectedNames, initialURLs: tab.selectedURLs)
        reloadTabStrip()
    }

    func selectNextTab(_ step: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex + step + tabs.count) % tabs.count)
    }

    // TabStripDelegate
    func tabStripSelect(_ index: Int) { selectTab(at: index) }
    func tabStripClose(_ index: Int) { closeTab(at: index) }
    func tabStripNewTab() { openTab(WindowHooks.startLocation.value()) }
    func tabStripMove(from: Int, to: Int) { moveTab(from: from, to: to) }
    func tabStripDetach(_ index: Int) { moveTabToNewWindow(at: index) }
    func tabStripMenu(for index: Int) -> NSMenu? {
        var ctx = context(surface: .tabContextMenu, sender: nil)
        ctx.tabIndex = index
        ctx.location = tabs[index].location
        return CommandDispatcher.shared.menu(for: .tabContextMenu, context: ctx)
    }

    // MARK: - Item view

    /// Reuses the current item view if it can show `mode`, else builds the registered one (B4).
    func ensureItemView(for mode: ViewMode) -> ItemViewController {
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
}
