import AppKit
import ArborCore

extension BrowserWindowController: NSSplitViewDelegate {
    // MARK: - Layout

    func buildLayout() {
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
}

/// Split view with a theme-colored hairline divider.
final class ExplorerSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.separator }
}
