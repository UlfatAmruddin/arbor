import AppKit
import ArborCore

/// After a crash or quit mid-job, lists finished, unfinished and uncertain items (FE-125, FE-128).
/// "Retry remaining" runs a normal job, so a same-named destination item is never assumed finished.
/// Jobs still queued are offered again ("Start"). Nothing is replayed automatically.
enum JobRecovery {
    private static var queue: [InterruptedJob] = []
    private static var showing = false

    static func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { check() }
    }

    static func check() {
        let directory = FileOpsEnvironment.journalDirectory
        DispatchQueue.global(qos: .utility).async {
            let found = JobJournal.interrupted(in: directory)
            DispatchQueue.main.async {
                let known = Set(queue.map(\.file))
                queue.append(contentsOf: found.filter { !known.contains($0.file) })
                showNext()
            }
        }
    }

    private static func showNext() {
        guard !showing, !queue.isEmpty, let browser = BrowserWindowController.active, let window = browser.window else { return }
        let job = queue.removeFirst()
        showing = true
        RecoverySheet(job, browser: browser) {
            showing = false
            showNext()
        }.begin(on: window)
    }
}

final class RecoverySheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let job: InterruptedJob
    private weak var browser: BrowserWindowController?
    private let done: () -> Void
    private let sheet: NSWindow
    private static var current: RecoverySheet?

    init(_ job: InterruptedJob, browser: BrowserWindowController, done: @escaping () -> Void) {
        self.job = job
        self.browser = browser
        self.done = done
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let root = FillView(FileOpsStyle.background)
        let waiting = job.wasWaiting
        let title = FileOpsStyle.label(waiting ? L10n.tr("A file operation was waiting to start") : L10n.tr("A file operation didn't finish"),
                                       font: FileOpsStyle.instructionFont)
        let started = DateFormatter.localizedString(from: job.header.started, dateStyle: .medium, timeStyle: .short)
        let items = StatusText.items(job.items.count), place = displayName(of: job.destination)
        let introText: String
        switch (waiting, job.kind == .copy) {
        case (true, true): introText = L10n.format("When Arbor quit, copying %@ to “%@” was waiting in the queue (added %@). Nothing of it was done yet.", items, place, started)
        case (true, false): introText = L10n.format("When Arbor quit, moving %@ to “%@” was waiting in the queue (added %@). Nothing of it was done yet.", items, place, started)
        case (false, true): introText = L10n.format("Arbor stopped while copying %@ to “%@” (started %@).", items, place, started)
        case (false, false): introText = L10n.format("Arbor stopped while moving %@ to “%@” (started %@).", items, place, started)
        }
        let intro = FileOpsStyle.label(introText, wraps: true)
        intro.preferredMaxLayoutWidth = 516
        let counts = FileOpsStyle.label(
            L10n.format("Completed: %@    Not done: %@    Uncertain: %@", StatusText.number(job.completed.count), StatusText.number(job.notDone.count), StatusText.number(job.uncertain.count)),
            font: .systemFont(ofSize: 13, weight: .semibold))

        let table = NSTableView()
        for (id, title, width) in [("name", L10n.tr("Name"), 190.0), ("status", L10n.tr("Status"), 150.0), ("where", L10n.tr("Location"), 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let explain = FileOpsStyle.label(
            waiting
                ? L10n.tr("Start puts the operation back in the queue with the items that still exist. Arbor checks each destination again and asks before replacing anything.")
                : job.kind == .copy
                    ? L10n.tr("“Uncertain” items were being written when Arbor stopped, so the destination may hold a partial copy. Retry remaining copies the items that aren't completed. Arbor checks each destination again and asks before replacing anything.")
                    : L10n.tr("“Uncertain” items were being written when Arbor stopped, so the destination may hold a partial copy. Retry remaining moves the items that aren't completed. Arbor checks each destination again and asks before replacing anything."),
            font: FileOpsStyle.captionFont, color: Theme.secondaryText, wraps: true)
        explain.preferredMaxLayoutWidth = 516

        let retryable = job.retryableSources
        let retry = WinButton(waiting ? L10n.tr("Start") : L10n.tr("Retry remaining"), accent: true) { [weak self] in self?.retry() }
        retry.isEnabled = !retryable.isEmpty && FileOps.isPlainFolder(job.destination)
        let dismiss = WinButton(L10n.tr("Dismiss")) { [weak self] in self?.finish() }
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, retry, dismiss])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, intro, counts, scroll, explain, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 560),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(max(job.items.count, 3), 8)) * 22 + 28),
            scroll.widthAnchor.constraint(equalToConstant: 516),
            buttons.widthAnchor.constraint(equalToConstant: 516),
        ])
        sheet.contentView = root
        root.layoutSubtreeIfNeeded()
        sheet.setContentSize(root.fittingSize)
    }

    func begin(on window: NSWindow) {
        Self.current = self
        window.beginSheet(sheet)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { job.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = job.items[row]
        let text: String
        var color = Theme.primaryText
        switch tableColumn?.identifier.rawValue {
        case "name": text = item.source.lastPathComponent
        case "status":
            switch item.status {
            case .completed: text = item.state == .skipped ? L10n.tr("Skipped") : (item.state == .sourceRemains ? L10n.tr("Copied; original kept") : L10n.tr("Completed"))
            case .notDone:
                text = job.wasWaiting ? L10n.tr("Waiting to start") : item.state == .failed ? L10n.tr("Not done (failed)") : L10n.tr("Not done")
                color = Theme.secondaryText
            case .uncertain:
                text = L10n.tr("Uncertain")
                color = .systemOrange
            }
        default:
            let place = item.destination ?? (item.status == .completed ? nil : item.source)
            text = place.map { $0.deletingLastPathComponent().path } ?? ""
        }
        let label = FileOpsStyle.label(text, font: FileOpsStyle.captionFont, color: color)
        label.toolTip = item.note ?? text
        return label
    }

    private func retry() {
        let sources = job.retryableSources
        let destination = job.destination
        let kind = job.kind
        finish()
        guard !sources.isEmpty, let browser else { return }
        browser.startTransfer(kind, sources, to: destination)
    }

    private func finish() {
        job.discard()
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        Self.current = nil
        done()
    }
}
