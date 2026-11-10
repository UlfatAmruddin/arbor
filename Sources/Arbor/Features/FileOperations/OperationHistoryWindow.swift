import AppKit
import ArborCore

/// Operation history store (FE-126): I/O on a private serial queue; `records` is the main-thread copy.
final class OperationHistory {
    static let shared = OperationHistory()
    static let changed = Notification.Name("ArborOperationHistoryChanged")

    private let queue = DispatchQueue(label: "Arbor operation history")
    private var store: OperationHistoryStore?
    private(set) var records: [OperationRecord] = []
    private(set) var loaded = false

    /// `ARBOR_HISTORY_FILE`, else a private file in headless runs, else ~/Library/Application Support/Arbor/History/operations.json.
    static let fileURL: URL = {
        let env = Automation.environment
        if let path = env["ARBOR_HISTORY_FILE"] { return URL(fileURLWithPath: path) }
        if AppDelegate.isHeadless {
            return TemporaryFiles.headlessFolder("history").appendingPathComponent("operations.json")
        }
        return FileOpsEnvironment.journalDirectory.deletingLastPathComponent().appendingPathComponent("History/operations.json")
    }()

    func load() {
        queue.async {
            let store = OperationHistoryStore(fileURL: Self.fileURL)
            self.store = store
            let records = store.records
            DispatchQueue.main.async {
                // Anything added before loading finished is kept in front.
                let added = self.records.filter { r in !records.contains { $0.id == r.id } }
                self.records = (added + records).sorted { $0.finished > $1.finished }
                self.loaded = true
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    func add(_ record: OperationRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > OperationHistoryStore.defaultLimit { records.removeLast(records.count - OperationHistoryStore.defaultLimit) }
        queue.async {
            let store = self.store ?? OperationHistoryStore(fileURL: Self.fileURL)
            self.store = store
            store.add(record)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func clear() {
        records = []
        queue.async {
            let store = self.store ?? OperationHistoryStore(fileURL: Self.fileURL)
            self.store = store
            store.clear()
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Waits for pending writes (tests and quit).
    func flush() { queue.sync {} }
}

/// "Operation history" window (FE-126), beyond Explorer. Retry failed items runs a normal job,
/// so sources, destinations and conflicts are checked again (FE-128).
final class OperationHistoryWindow: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let shared = OperationHistoryWindow()

    private final class JobNode {
        let record: OperationRecord
        var children: [ItemNode] = []
        init(_ record: OperationRecord) { self.record = record }
    }

    private final class ItemNode {
        let name: String
        let place: String
        let result: String
        let detail: String
        let isProblem: Bool
        unowned let job: JobNode
        let destination: String?
        init(name: String, place: String, result: String, detail: String, isProblem: Bool, job: JobNode, destination: String?) {
            self.name = name
            self.place = place
            self.result = result
            self.detail = detail
            self.isProblem = isProblem
            self.job = job
            self.destination = destination
        }
    }

    private var window: NSWindow?
    private let outline = NSOutlineView()
    private let empty = FileOpsStyle.label(L10n.tr("No copy or move operations yet."), color: Theme.secondaryText)
    private let status = FileOpsStyle.label("", font: FileOpsStyle.captionFont, color: Theme.secondaryText)
    private lazy var openButton = WinButton(L10n.tr("Open destination")) { [weak self] in self?.openDestination() }
    private lazy var retryButton = WinButton(L10n.tr("Retry failed items")) { [weak self] in self?.retry() }
    private lazy var clearButton = WinButton(L10n.tr("Clear history")) { [weak self] in self?.confirmClear() }
    private var nodes: [JobNode] = []
    private var observer: NSObjectProtocol?
    private var retryToken = 0
    private var retryPlan: [(folder: String, sources: [String])] = []

    private static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var isVisible: Bool { window?.isVisible ?? false }
    var snapshotWindow: NSWindow? { window }

    func show() {
        let window = self.window ?? makeWindow()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: OperationHistory.changed, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }
        }
        if !OperationHistory.shared.loaded { OperationHistory.shared.load() }
        reload()
        if !window.isVisible {
            if let parent = BrowserWindowController.active?.window {
                window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
            } else {
                window.center()
            }
        }
        if AppDelegate.isHeadless {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L10n.tr("Operation history")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 320)
        let root = FillView(FileOpsStyle.background)
        let intro = FileOpsStyle.label(L10n.format("Recent copy and move operations, newest first. Arbor keeps the last %@. Expand one to see what happened to each item.", "\(OperationHistoryStore.defaultLimit)"),
                                       font: FileOpsStyle.captionFont, color: Theme.secondaryText, wraps: true)
        let heading = FileOpsStyle.label(L10n.tr("Operation history"), font: FileOpsStyle.instructionFont)

        for (id, title, width) in [("what", L10n.tr("Operation"), 200.0), ("where", L10n.tr("From → To"), 150.0), ("when", L10n.tr("Finished"), 130.0), ("result", L10n.tr("Result"), 270.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            outline.addTableColumn(column)
            if id == "what" { outline.outlineTableColumn = column }
        }
        outline.rowHeight = 24
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = FileOpsStyle.background
        outline.dataSource = self
        outline.delegate = self
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.setAccessibilityLabel(L10n.tr("Operation history"))
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let frame = FillView(FileOpsStyle.background)
        frame.topLine = FileOpsStyle.separator
        frame.addSubview(scroll)
        frame.addSubview(empty)

        let footer = FillView(FileOpsStyle.footer)
        footer.topLine = FileOpsStyle.footerLine
        let close = WinButton(L10n.tr("Close")) { [weak self] in self?.window?.orderOut(nil) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [clearButton, status, spacer, openButton, retryButton, close])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)

        for v in [heading, intro, frame, footer] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            intro.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            frame.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            frame.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: frame.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            footer.topAnchor.constraint(equalTo: frame.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            row.topAnchor.constraint(equalTo: footer.topAnchor),
            row.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        window.contentView = root
        self.window = window
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: Model

    private func reload() {
        guard window != nil else { return }
        let expanded = Set(nodes.filter { outline.isItemExpanded($0) }.map(\.record.id))
        let selectedID = selectedJob?.record.id
        nodes = OperationHistory.shared.records.map(makeNode)
        outline.reloadData()
        for node in nodes where expanded.contains(node.record.id) { outline.expandItem(node) }
        if let selectedID, let node = nodes.first(where: { $0.record.id == selectedID }) {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
        }
        empty.isHidden = !nodes.isEmpty
        clearButton.isEnabled = !nodes.isEmpty
        updateButtons()
    }

    private func makeNode(_ record: OperationRecord) -> JobNode {
        let node = JobNode(record)
        for item in record.items {
            let source = URL(fileURLWithPath: item.source)
            let to = item.destination.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? item.retryFolder
            node.children.append(ItemNode(
                name: (item.nested ? "  " : "") + source.lastPathComponent,
                place: "\(Self.name(source.deletingLastPathComponent().path)) → \(Self.name(to))",
                result: item.outcome.label, detail: item.message ?? "",
                isProblem: item.outcome.isRetryable && item.outcome != .cancelled && item.outcome != .notDone,
                job: node, destination: item.destination))
        }
        if record.omittedItems > 0 {
            node.children.append(ItemNode(name: "…", place: "", result: L10n.format("%@ more items not listed", StatusText.number(record.omittedItems)), detail: "",
                                          isProblem: false, job: node, destination: nil))
        }
        for failure in record.verification?.failures ?? [] {
            let url = URL(fileURLWithPath: failure.path)
            node.children.append(ItemNode(name: url.lastPathComponent, place: Self.name(url.deletingLastPathComponent().path),
                                          result: L10n.tr("Didn't verify"), detail: failure.reason, isProblem: true, job: node, destination: nil))
        }
        return node
    }

    /// "~/Documents/Reports".
    private static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder's display name ("Downloads"), like the progress dialog's "from X to Y".
    private static func name(_ path: String) -> String { displayName(of: URL(fileURLWithPath: path)) }

    static func title(_ record: OperationRecord) -> String {
        let n = record.sources.count
        let what = n == 1 ? L10n.format("“%@”", URL(fileURLWithPath: record.sources[0]).lastPathComponent) : StatusText.items(n)
        switch (record.kind == .copy, record.wasInterrupted) {
        case (true, true): return L10n.format("Copy %@ (interrupted)", what)
        case (true, false): return L10n.format("Copied %@", what)
        case (false, true): return L10n.format("Move %@ (interrupted)", what)
        case (false, false): return L10n.format("Moved %@", what)
        }
    }

    static func result(_ record: OperationRecord) -> String {
        var text = record.countsText
        if record.wasCancelled, !record.wasInterrupted { text = L10n.format("Cancelled · %@", text) }
        switch record.verification?.state {
        case .verified?: text = L10n.format("%@ · Verified", text)
        case .failed?: text = L10n.format("%@ · Verification failed (%d)", text, record.verification?.failures.count ?? 0)
        case .cancelled?: text = L10n.format("%@ · Verification cancelled", text)
        case nil: break
        }
        return text
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return nodes.count }
        return (item as? JobNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return nodes[index] }
        return (item as! JobNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? JobNode).map { !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        var text = ""
        var color = Theme.primaryText
        var font = FileOpsStyle.captionFont
        var tip: String?
        if let job = item as? JobNode {
            let r = job.record
            switch id {
            case "what":
                text = Self.title(r)
                font = .systemFont(ofSize: 12, weight: .semibold)
            case "where":
                let from = r.sources.first.map { Self.name(URL(fileURLWithPath: $0).deletingLastPathComponent().path) } ?? ""
                text = "\(from) → \(Self.name(r.destination))"
                tip = (r.sources.map(Self.short) + ["→ " + Self.short(r.destination)]).joined(separator: "\n")
            case "when": text = Self.dates.string(from: r.finished)
            default:
                text = Self.result(r)
                if r.hasProblems { color = SheetColors.failure } else if r.verification?.state == .verified { color = SheetColors.success }
            }
        } else if let node = item as? ItemNode {
            switch id {
            case "what": text = node.name
            case "where": text = node.place
            case "when": text = ""
            default:
                text = node.detail.isEmpty ? node.result : "\(node.result): \(node.detail)"
                if node.isProblem { color = SheetColors.failure } else if node.result != L10n.tr("Done") && node.result != L10n.tr("Merged") { color = Theme.secondaryText }
                tip = text
            }
        }
        let label = FileOpsStyle.label(text, font: font, color: color)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tip ?? text
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var selectedJob: JobNode? {
        let item = outline.item(atRow: outline.selectedRow)
        return (item as? JobNode) ?? (item as? ItemNode)?.job
    }

    private func updateButtons() {
        let job = selectedJob
        openButton.isEnabled = job != nil
        retryButton.isEnabled = false
        retryPlan = []
        guard let record = job?.record else { return }
        retryToken += 1
        let token = retryToken
        // Checking that sources still exist touches the disk: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = record.retryPlan().filter { FileOps.isPlainFolder(URL(fileURLWithPath: $0.folder)) }
            DispatchQueue.main.async {
                guard let self, token == self.retryToken else { return }
                self.retryPlan = plan
                self.retryButton.isEnabled = !plan.isEmpty
            }
        }
    }

    // MARK: Actions

    private func openDestination() {
        guard let job = selectedJob else { return }
        var folder = URL(fileURLWithPath: job.record.destination)
        var select: [String] = []
        if let node = outline.item(atRow: outline.selectedRow) as? ItemNode, let destination = node.destination {
            folder = URL(fileURLWithPath: destination).deletingLastPathComponent()
            select = [URL(fileURLWithPath: destination).lastPathComponent]
        }
        guard FileOps.isPlainFolder(folder) else {
            status.stringValue = L10n.format("“%@” isn't available anymore.", "\(folder.lastPathComponent)")
            return
        }
        guard let browser = BrowserWindowController.active else { return }
        browser.openTab(.folder(folder))
        if !select.isEmpty { browser.navigate(to: .folder(folder), select: select) }
        browser.window?.makeKeyAndOrderFront(nil)
        status.stringValue = L10n.format("Opened “%@”.", "\(displayName(of: folder))")
    }

    /// Starts one normal job per destination folder for the items that didn't finish.
    private func retry() {
        guard let record = selectedJob?.record, !retryPlan.isEmpty, let browser = BrowserWindowController.active else { return }
        for group in retryPlan {
            browser.startTransfer(record.kind, group.sources.map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: group.folder))
        }
        let count = retryPlan.reduce(0) { $0 + $1.sources.count }
        status.stringValue = L10n.format("Retrying %@. Arbor asks before replacing anything.", "\(StatusText.items(count))")
        retryButton.isEnabled = false
    }

    private func confirmClear() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Clear the operation history?")
        alert.informativeText = L10n.tr("The list of past copy and move operations is removed. Your files aren't changed.")
        alert.addButton(withTitle: L10n.tr("Clear history"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        if AppDelegate.isHeadless { alert.window.alphaValue = 0 }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            OperationHistory.shared.clear()
            self?.status.stringValue = L10n.tr("History cleared.")
        }
    }

    // MARK: Scripting

    func expandAll() { nodes.forEach { outline.expandItem($0) } }

    func select(row: Int) {
        guard row >= 0, row < outline.numberOfRows else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Clicks a button in the window or its sheet.
    func scriptClick(_ title: String) -> Bool {
        func find(_ view: NSView?) -> NSButton? {
            guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let b = view as? NSButton, b.title == title, b.isEnabled { return b }
            for sub in view.subviews { if let f = find(sub) { return f } }
            return nil
        }
        guard let button = find(window?.attachedSheet?.contentView) ?? find(window?.contentView) else { return false }
        button.performClick(nil)
        return true
    }

    var scriptDescription: String {
        var lines = ["history window: \(isVisible ? "visible" : "hidden") jobs=\(nodes.count) open=\(openButton.isEnabled) retry=\(retryButton.isEnabled) clear=\(clearButton.isEnabled) status=\(status.stringValue)"]
        for row in 0..<min(outline.numberOfRows, 40) {
            if let job = outline.item(atRow: row) as? JobNode {
                lines.append("  [\(row)] \(Self.title(job.record)) | \(job.record.destination) | \(Self.result(job.record))")
            } else if let node = outline.item(atRow: row) as? ItemNode {
                lines.append("    [\(row)] \(node.name.trimmingCharacters(in: .whitespaces)) | \(node.result)\(node.detail.isEmpty ? "" : ": \(node.detail)")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
