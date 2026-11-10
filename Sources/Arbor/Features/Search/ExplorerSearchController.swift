import AppKit
import ArborCore

/// Explorer search box (FE-131, FE-135): a pause or Return opens recursive "Search Results in <folder>".
/// Refining replaces that entry, so Back returns to the folder; clearing or "Close search" goes back.
/// Places without files (Trash, Network…) keep the in-folder filter.
final class ExplorerSearchController: SearchController {
    static let typingDelay: TimeInterval = 0.6

    private weak var window: BrowserWindowController?
    private var pending: DispatchWorkItem?
    private var lastTyped = ""
    private let progress = SearchProgressFill()
    private lazy var dropdown = SearchHistoryDropdown(
        onPick: { [weak self] query in self?.pick(query) },
        onRemove: { query in SearchHistoryStore.update { $0.remove(query) } },
        onClear: { SearchHistoryStore.update { $0.clear() } })
    private var responderObservation: NSKeyValueObservation?
    private var trackedSession: SearchSession?
    private var sessionToken: SearchSession.Token?

    private static let controllers = NSMapTable<BrowserWindowController, ExplorerSearchController>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    static func controller(for window: BrowserWindowController?) -> ExplorerSearchController? {
        window.flatMap { controllers.object(forKey: $0) }
    }

    init(window: BrowserWindowController) {
        self.window = window
        Self.controllers.setObject(self, forKey: window)
        progress.install(in: window.addressBar)
        // Refresh reruns a search (F5 goes through nav.refresh).
        let originalRefresh = window.addressBar.onRefresh
        window.addressBar.onRefresh = { [weak window] in
            if let window, !window.tabs.isEmpty, case .search(let r) = window.activeTab.displayedLocation ?? window.location {
                SearchSessions.restart(r, showHidden: Prefs.showHidden)
            }
            originalRefresh?()
        }
        responderObservation = window.window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.focusChanged() }
        }
    }

    // MARK: SearchController

    func placeholder(for location: Location) -> String {
        syncProgress(location)
        if case .search(let r) = location {
            if let origin = r.origin { return L10n.format("Search %@", Self.title(of: origin)) }
            return L10n.format("Search %@", r.scope.map { Self.title(of: .folder($0)) } ?? L10n.tr("This Mac"))
        }
        return L10n.format("Search %@", "\(Self.title(of: location))")
    }

    /// Display name for tab and breadcrumb ("iCloud Drive"), not the on-disk name.
    private static func title(of location: Location) -> String {
        LocationRegistry.provider(for: location).title(for: location)
    }

    func boxText(for location: Location, filterText: String) -> String {
        if case .search(let r) = location { return r.query }
        return filterText
    }

    func queryChanged(_ text: String) {
        guard let window else { return }
        lastTyped = text
        pending?.cancel()
        if isEditingBox { dropdown.show(SearchHistoryStore.history.suggestions(for: text), below: window.searchBox) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = self.shown
        if trimmed.isEmpty {
            if case .search = shown { closeSearch() } else { window.applyFilter("") }
            return
        }
        guard Self.isSearchable(shown) else { window.applyFilter(text); return }
        // Results shown are for an older query: stop it now (spec §10.4).
        if case .search(let r) = shown, r.query != trimmed { SearchSessions.cancel(r, superseded: true) }
        let work = DispatchWorkItem { [weak self] in self?.run(trimmed, refining: true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingDelay, execute: work)
    }

    func submit(_ text: String) {
        guard let window else { return }
        pending?.cancel()
        dropdown.hide()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = self.shown
        guard Self.isSearchable(shown) else {
            // In-place filter places: Return focuses the first match (DEC-014).
            guard let view = window.itemView else { return }
            view.focus()
            if view.selectedItems.isEmpty, let first = view.items.first { view.select(urls: [first.url]) }
            return
        }
        if trimmed.isEmpty {
            if case .search = shown { closeSearch() }
            return
        }
        if case .search(let r) = shown, r.query == trimmed, SearchProvider.session(for: shown) != nil {
            // Already showing these results: Return / Down moves into them.
            SearchHistoryStore.update { $0.record(trimmed) }
            if let view = window.itemView {
                view.focus()
                if view.selectedItems.isEmpty, let first = view.items.first { view.select(urls: [first.url]) }
            }
            return
        }
        run(trimmed, refining: false)
    }

    func locationDidChange(_ location: Location) {
        guard let window else { return }
        if case .search(let r) = location {
            window.searchBox.text = isEditingBox && !lastTyped.isEmpty ? lastTyped : r.query
        } else {
            if !isEditingBox { lastTyped = "" }
            dropdown.hide()
        }
        SearchSessions.cancelUnreferenced()
        syncProgress(location)
    }

    // MARK: Running

    private var shown: Location {
        guard let window, !window.tabs.isEmpty else { return .home }
        return window.activeTab.displayedLocation ?? window.location
    }

    private var isEditingBox: Bool {
        guard let window, let editor = window.window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === window.searchBox.field
    }

    /// Places the box searches recursively; elsewhere it filters the visible items.
    static func isSearchable(_ location: Location) -> Bool {
        switch location {
        case .folder, .search, .home, .thisMac: return true
        default: return scopedRequest.first((location, nil)) != nil
        }
    }

    /// Search for a place that isn't a plain folder (Home, a library, This Mac). nil = default.
    static let scopedRequest = Handlers<(Location, BrowserWindowController?), SearchRequest>(
        "ExplorerSearchController.scopedRequest", "The search a place that isn't a plain folder runs (Home, libraries, This Mac).",
        signature: "(location, window?) -> SearchRequest?")

    /// The folder a search from `location` covers (nil = everywhere / This Mac).
    static func scope(for location: Location) -> URL? {
        switch location {
        case .folder(let url): return url
        case .search(let r): return r.scope
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        default: return nil
        }
    }

    /// Runs `query` from what's shown: a folder starts a search; a search is refined in place.
    func run(_ query: String, refining: Bool) {
        guard window != nil else { return }
        let shown = self.shown
        var request: SearchRequest
        if case .search(let r) = shown {
            request = r
            request.query = query
        } else {
            request = Self.scopedRequest.first((shown, window)) ?? SearchRequest(query: query, scope: Self.scope(for: shown), recursive: true)
            request.query = query
        }
        if case .success = AQSParser.parse(query) {   // only runnable queries go into history
            SearchHistoryStore.update { $0.record(query, refining: refining) }
        }
        open(request)
    }

    /// Shows `request` in the active tab, replacing the current search entry if one is shown.
    func open(_ request: SearchRequest, rerun: Bool = false) {
        guard let window else { return }
        let target = Location.search(request)
        if rerun || shown == target { SearchSessions.restart(request, showHidden: Prefs.showHidden) }
        if case .search = shown { window.activeTab.history.replaceCurrent(with: target) }
        window.navigate(to: target)
    }

    /// "Close search": back to the place before the searches, with its selection; tag rows stack search entries.
    func closeSearch() {
        guard let window, case .search(let r) = shown else { return }
        pending?.cancel()
        lastTyped = ""
        dropdown.hide()
        if let steps = window.activeTab.history.stepsBack(toNearest: { !Self.isSearchLocation($0.location) }) {
            window.goBack(steps: steps)
        } else {
            window.navigate(to: r.origin ?? r.scope.map { .folder($0) } ?? .home)
        }
        window.searchBox.text = ""
    }

    static func isSearchLocation(_ location: Location) -> Bool {
        if case .search = location { return true }
        return false
    }

    /// Inserts text into the box (e.g. "type:") with the cursor after it.
    func insertIntoBox(_ text: String) {
        guard let window else { return }
        let current = window.searchBox.text.trimmingCharacters(in: .whitespaces)
        let new = current.isEmpty ? text : current + " " + text
        window.searchBox.focus()
        window.searchBox.text = new
        lastTyped = new
        if let editor = window.window?.firstResponder as? NSTextView {
            editor.string = new
            editor.setSelectedRange(NSRange(location: (new as NSString).length, length: 0))
        }
    }

    private func pick(_ query: String) {
        guard let window else { return }
        dropdown.hide()
        window.searchBox.text = query
        lastTyped = query
        submit(query)
    }

    private func focusChanged() {
        guard let window else { return }
        if isEditingBox {
            dropdown.show(SearchHistoryStore.history.suggestions(for: window.searchBox.text), below: window.searchBox)
        } else {
            dropdown.hide()
        }
    }

    // MARK: Progress

    private func syncProgress(_ location: Location) {
        let session = SearchProvider.session(for: location)
        if session !== trackedSession {
            trackedSession = session
            sessionToken = session?.observe { [weak self] in self?.updateProgress() }
        }
        updateProgress()
    }

    private func updateProgress() {
        guard let session = trackedSession else { progress.state = .idle; return }
        progress.state = session.isRunning ? .searching(since: session.startedAt) : .done
    }

    // MARK: Debug

    var debugDropdown: String { dropdown.debugDescription }
    var dropdownPanel: DropdownPanel { dropdown.panel }
    var debugProgress: String { progress.debugDescription }
}

/// Recent searches, stored with the other preferences (throwaway in headless runs).
enum SearchHistoryStore {
    private static let key = "searchHistory"

    static var history: SearchHistory {
        guard let data = Prefs.store.data(forKey: key),
              let h = try? JSONDecoder().decode(SearchHistory.self, from: data) else { return SearchHistory() }
        return h
    }

    static func update(_ change: (inout SearchHistory) -> Void) {
        var h = history
        change(&h)
        if let data = try? JSONEncoder().encode(h) { Prefs.store.set(data, forKey: key) }
    }
}

// MARK: - Address bar progress (Explorer's green fill while searching)

final class SearchProgressFill: NSView {
    enum State: Equatable {
        case idle
        case searching(since: Date)
        case done
    }

    var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            switch state {
            case .searching:
                isHidden = false
                alphaValue = 1
                startTimer()
            case .done:
                stopTimer()
                fraction = 1
                needsDisplay = true
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = Theme.reduceMotion ? 0 : 0.6
                    self.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    if self?.state == .done { self?.isHidden = true; self?.fraction = 0 }
                })
            case .idle:
                stopTimer()
                isHidden = true
                fraction = 0
            }
        }
    }

    private var fraction: CGFloat = 0
    private var timer: Timer?

    static let fill = Theme.dynamic(light: 0xC9EBC9, dark: 0x2E5B33)

    func install(in addressBar: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        addressBar.addSubview(self, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: addressBar.leadingAnchor, constant: 1),
            trailingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: -1),
            topAnchor.constraint(equalTo: addressBar.topAnchor, constant: 1),
            bottomAnchor.constraint(equalTo: addressBar.bottomAnchor, constant: -1),
        ])
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard case .searching(let since) = state else { return }
        // No known total: fast at first, then slower, never full until done.
        let t = Date().timeIntervalSince(since)
        fraction = CGFloat(0.92 * (1 - exp(-t / 3)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard fraction > 0 else { return }
        let rect = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        Self.fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius - 1, yRadius: Theme.cornerRadius - 1).fill()
    }

    override var debugDescription: String {
        switch state {
        case .idle: return "idle"
        case .searching: return String(format: "searching %.2f", fraction)
        case .done: return "done"
        }
    }
}

// MARK: - Recent searches dropdown (FE-135)

/// Recent-searches panel under the box, with "Clear search history". Never takes keyboard focus.
final class SearchHistoryDropdown {
    let panel: DropdownPanel
    private let list = NSStackView()
    private let onPick: (String) -> Void
    private let onRemove: (String) -> Void
    private let onClear: () -> Void
    private(set) var entries: [String] = []

    init(onPick: @escaping (String) -> Void, onRemove: @escaping (String) -> Void, onClear: @escaping () -> Void) {
        self.onPick = onPick
        self.onRemove = onRemove
        self.onClear = onClear
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        panel = DropdownPanel(content: list, accessibilityLabel: L10n.tr("Recent searches"))
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ entries: [String], below anchor: NSView) {
        guard !entries.isEmpty, anchor.window != nil else { hide(); return }
        self.entries = entries
        rebuild(width: anchor.bounds.width)
        panel.show(below: anchor)
    }

    func hide() { panel.hide() }

    private func rebuild(width: CGFloat) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = NSTextField(labelWithString: L10n.tr("Recent searches"))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = Theme.secondaryText
        let headerRow = NSStackView(views: [header])
        headerRow.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 4, right: 10)
        list.addArrangedSubview(headerRow)
        for entry in entries {
            let row = ChromeButton(symbol: "clock.arrow.circlepath", title: entry, tooltip: L10n.format("Search for “%@”", entry))
            row.symbolSize = 12
            row.symbolTint = Theme.secondaryText
            row.fixedHeight = 30
            row.horizontalPadding = 10
            row.onClick = { [weak self] _ in self?.onPick(entry) }
            row.setAccessibilityLabel(entry)
            row.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width - 8).isActive = true
            row.menu = {
                let m = NSMenu()
                m.allowsContextMenuPlugIns = false
                m.addItem(ClosureMenuItem(L10n.tr("Remove from history")) { [weak self] in
                    self?.onRemove(entry)
                    self?.entries.removeAll { $0 == entry }
                    if self?.entries.isEmpty == true { self?.hide() } else { self?.rebuild(width: width) }
                })
                return m
            }()
        }
        let separator = SeparatorLine()
        separator.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: width - 8).isActive = true
        let clear = ChromeButton(symbol: "trash", title: L10n.tr("Clear search history"), tooltip: "Remove all recent searches")
        clear.symbolSize = 12
        clear.fixedHeight = 30
        clear.horizontalPadding = 10
        clear.textColor = Theme.secondaryText
        clear.onClick = { [weak self] _ in
            self?.onClear()
            self?.hide()
        }
        clear.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(clear)
        clear.widthAnchor.constraint(equalToConstant: width - 8).isActive = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    var debugDescription: String {
        "dropdown: \(isVisible ? "shown" : "hidden") [\(entries.joined(separator: " | "))]"
    }

    private final class SeparatorLine: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 9) }
        override func draw(_ dirtyRect: NSRect) {
            Theme.separator.setFill()
            NSRect(x: 6, y: floor(bounds.midY), width: bounds.width - 12, height: 1).fill()
        }
    }
}
