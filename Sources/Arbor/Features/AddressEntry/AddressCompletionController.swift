import AppKit
import ArborCore

/// Path suggestions while typing (FE-006); one per window, main thread only, and only an explicit pick touches the field.
final class AddressCompletionController: AddressEditingSession {
    // Separate lanes, app-wide: a hung share can't starve local completion, and hung work stays capped across windows.
    private static let localQueue = PathListingQueue(lane: .local, label: "arbor.address-completion.local", lister: lister)
    private static let networkQueue = PathListingQueue(lane: .network, label: "arbor.address-completion.network", lister: lister)

    private static let lister: PathListingQueue.Lister = {
        let delay = scriptedDelay
        guard delay > 0 else { return PathListingQueue.liveLister }
        return { folder, lane, cancellation in
            Thread.sleep(forTimeInterval: delay)
            return PathListingQueue.liveLister(folder, lane, cancellation)
        }
    }()

    /// Stands in for a slow volume in scripted checks; distribution builds never see it.
    private static var scriptedDelay: TimeInterval {
        guard let seconds = Automation.environment["ARBOR_COMPLETION_DELAY"].flatMap(Double.init), seconds.isFinite else { return 0 }
        return min(max(seconds, 0), 10)
    }

    private struct Running {
        let folder: URL
        let queue: PathListingQueue
        let job: PathListingQueue.Job
    }

    private struct ShownRows {
        let query: PathCompletionQuery
        let rows: [PathCompletionCandidate]
    }

    private weak var window: BrowserWindowController?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let list = AddressSuggestionList()

    private var debounce: (folder: URL, item: DispatchWorkItem)?
    private var running: Running?
    private var cache: (folder: URL, listing: BoundedListing)?
    private var shown: ShownRows?
    private var highlighted: Int?
    /// After Escape or a pick, no list until the user edits again.
    private var isSuppressed = false
    private var isApplyingPick = false
    private var selectionObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var listingsStarted = 0

    init(window: BrowserWindowController) {
        self.window = window
        list.onPick = { [weak self] index in self?.pickRow(index) }
    }

    deinit {
        stopWork()
        hideList()
    }

    // MARK: AddressEditingSession

    func textDidChange() {
        guard !isApplyingPick else { return }
        isSuppressed = false
        refresh()
    }

    func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)) where list.isVisible:
            moveHighlight(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)) where list.isVisible:
            moveHighlight(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            return returnPressed()
        case #selector(NSResponder.cancelOperation(_:)) where list.isVisible:
            dismiss()
            return true
        default:
            setHighlight(nil)
            return false
        }
    }

    func reset() {
        stopWork()
        hideList()
        cache = nil
        isSuppressed = false
    }

    func locationDidChange() { dismiss() }

    // MARK: Keeping up with the text

    /// The query for what is in the field now, or nil when no list should show. Every path re-derives it, so stale work can't apply to newer text.
    private func currentQuery() -> PathCompletionQuery? {
        guard !isSuppressed, let window, let editor = window.addressBar.activeEditor, isReady(editor),
              let query = PathCompletionQuery.parse(editor.string, base: window.addressBase, homeDirectory: home),
              MountPoints.shared.volumeClass(containing: query.folder.path) != .automount else { return nil }
        return query
    }

    /// An input method owns marked text, and text before the caret isn't what the rows would complete.
    private func isReady(_ editor: NSTextView) -> Bool {
        !editor.hasMarkedText() && editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0)
    }

    private func refresh() {
        guard let query = currentQuery() else {
            stopWork()
            hideList()
            return
        }
        if let cache, cache.folder == query.folder {
            stopWork()
            render(cache.listing, for: query)
            return
        }
        if running?.folder == query.folder || debounce?.folder == query.folder { return }
        stopWork()
        hideList()
        scheduleListing(of: query.folder)
    }

    private func scheduleListing(of folder: URL) {
        let queue = MountPoints.shared.volumeClass(containing: folder.path) == .network ? Self.networkQueue : Self.localQueue
        let item = DispatchWorkItem { [weak self] in self?.startListing(of: folder, queue: queue) }
        debounce = (folder, item)
        DispatchQueue.main.asyncAfter(deadline: .now() + queue.lane.debounce, execute: item)
    }

    private func startListing(of folder: URL, queue: PathListingQueue) {
        debounce = nil
        // The window is part of the key so cancelling here can't cut off another window's scan.
        let key = "\(UInt(bitPattern: ObjectIdentifier(self)))|\(folder.path)"
        let job = queue.start(key: key, folder: folder,
                              finished: { [weak self] listing in self?.listingFinished(listing, folder: folder) },
                              late: { [weak self] listing in self?.listingArrivedLate(listing, folder: folder) })
        guard let job else { return }
        listingsStarted += 1
        running = Running(folder: folder, queue: queue, job: job)
    }

    private func listingFinished(_ listing: BoundedListing, folder: URL) {
        guard remember(listing, folder: folder), let query = currentQuery(), query.folder == folder else { return }
        render(listing, for: query)
    }

    /// Only fills the cache: a list must never pop up long after the user stopped expecting one.
    private func listingArrivedLate(_ listing: BoundedListing, folder: URL) {
        _ = remember(listing, folder: folder)
    }

    /// A late result for an abandoned folder would otherwise evict the live single-slot cache.
    private func remember(_ listing: BoundedListing, folder: URL) -> Bool {
        if running?.folder == folder { running = nil }
        guard !listing.wasCancelled, currentQuery()?.folder == folder else { return false }
        cache = (folder, listing)
        return true
    }

    private func stopWork() {
        debounce?.item.cancel()
        debounce = nil
        if let running { running.queue.cancel(running.job) }
        running = nil
    }

    // MARK: The list

    private func render(_ listing: BoundedListing, for query: PathCompletionQuery) {
        let listed = PathCompletion.candidates(in: listing.entries, for: query, includeHidden: Prefs.showHidden)
        let result = PathCompletion.addingHistory(AddressHistoryFeature.store.folderPaths, to: listed, for: query, includeHidden: Prefs.showHidden)
        guard !result.rows.isEmpty, let window else {
            hideList()
            return
        }
        let isOpening = !list.isVisible
        shown = ShownRows(query: query, rows: result.rows)
        highlighted = nil
        list.show(result.rows, notice: PathCompletion.notice(hasMore: result.hasMore, listingIsComplete: listing.isComplete), below: window.addressBar)
        watchCaret()
        watchClicks()
        if isOpening { announce(Self.countText(result.rows.count)) }
    }

    private func hideList() {
        shown = nil
        highlighted = nil
        list.hide()
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Closes the list and keeps the text; no list until the user edits again.
    private func dismiss() {
        isSuppressed = true
        stopWork()
        hideList()
    }

    /// Arrow keys and clicks move the caret without a text change, so the list would stay open mid-text.
    private func watchCaret() {
        guard selectionObserver == nil, let editor = window?.addressBar.activeEditor else { return }
        let center = NotificationCenter.default
        selectionObserver = center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in
            guard let self, self.list.isVisible, self.window?.addressBar.activeEditor.map(self.isReady) != true else { return }
            self.stopWork()
            self.hideList()
        }
    }

    /// Toolbar buttons never take focus, so pressing one would otherwise leave the list open.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, self.isOutsideList(event) { self.dismiss() }
            return event
        }
    }

    /// A press in the visible text only moves the caret, which `watchCaret` already handles.
    private func isOutsideList(_ event: NSEvent) -> Bool {
        if event.window === list.dropdown.window { return false }
        guard event.window === window?.window, let editor = window?.addressBar.activeEditor else { return true }
        return !editor.visibleRect.contains(editor.convert(event.locationInWindow, from: nil))
    }

    private func moveHighlight(by step: Int) {
        guard let count = shown?.rows.count, count > 0 else { return }
        // One extra slot for "no highlight", so the arrows can return to exactly what was typed.
        let slots = count + 1
        let slot = ((highlighted.map { $0 + 1 } ?? 0) + step + slots) % slots
        setHighlight(slot == 0 ? nil : slot - 1)
    }

    private func setHighlight(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        list.highlight(index)
        if let index, let row = shown?.rows[index] { announce(row.name) }
    }

    private func announce(_ text: String) {
        Announcer.announce(text, in: window?.window, priority: .low)
    }

    private static func countText(_ count: Int) -> String {
        L10n.plural(one: "%lld suggestion", other: "%lld suggestions", count)
    }

    // MARK: Picking

    /// Every Return closes the list first, so nothing stays over an error. Without a highlight the bar submits exactly what was typed.
    private func returnPressed() -> Bool {
        guard let index = highlighted else {
            stopWork()
            hideList()
            return false
        }
        pickRow(index)
        return true
    }

    private func pickRow(_ index: Int) {
        guard let shown, shown.rows.indices.contains(index), let window, let editor = window.addressBar.activeEditor else { return }
        let stillValid = currentQuery() == shown.query
        dismiss()
        if stillValid {
            isApplyingPick = true
            editor.insertText(shown.rows[index].text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            isApplyingPick = false
        }
        window.submitAddress(editor.string)
    }

    // MARK: Scripted checks

    var isSettled: Bool { debounce == nil && running == nil }
    var dropdown: DropdownPanel { list.dropdown }

    var debugText: String {
        let rows = shown?.rows.map { $0.isFolder ? $0.name + "/" : $0.name }.joined(separator: "|") ?? ""
        let state = list.isVisible ? "shown" : "hidden"
        let text = window?.addressBar.activeEditor?.string ?? "-"
        return "completions: \(state) rows=[\(rows)] highlight=\(highlighted.map(String.init) ?? "-") footer=\(list.notice.map { "\($0)" } ?? "no") "
            + "listings=\(listingsStarted) text=\(text)"
    }
}
