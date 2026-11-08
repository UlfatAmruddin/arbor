import AppKit
import ArborCore

/// After a crash or a quit in the middle of a copy or move, lists what finished, what didn't and
/// what is uncertain (FE-125, FE-128). "Retry remaining" starts a normal job for the unfinished
/// items, so every destination is checked again and conflicts are asked: a same-named item at the
/// destination is never assumed to be the finished copy. Nothing is replayed automatically.
/// A job that was still waiting in the queue when Arbor quit is offered again as it was ("Start").
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
        let verb = job.kind == .copy ? "copying" : "moving"
        let waiting = job.wasWaiting
        let title = FileOpsStyle.label(waiting ? "A file operation was waiting to start" : "A file operation didn't finish",
                                       font: FileOpsStyle.instructionFont)
        let started = DateFormatter.localizedString(from: job.header.started, dateStyle: .medium, timeStyle: .short)
        let intro = FileOpsStyle.label(
            waiting
                ? "When Arbor quit, \(verb) \(StatusText.items(job.items.count)) to “\(displayName(of: job.destination))” was waiting in the queue (added \(started)). Nothing of it was done yet."
                : "Arbor stopped while \(verb) \(StatusText.items(job.items.count)) to “\(displayName(of: job.destination))” (started \(started)).",
            wraps: true)
        intro.preferredMaxLayoutWidth = 516
        let counts = FileOpsStyle.label(
            "Completed: \(job.completed.count)    Not done: \(job.notDone.count)    Uncertain: \(job.uncertain.count)",
            font: .systemFont(ofSize: 13, weight: .semibold))

        let table = NSTableView()
        for (id, title, width) in [("name", "Name", 190.0), ("status", "Status", 150.0), ("where", "Location", 170.0)] {
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
                ? "Start puts the operation back in the queue with the items that still exist. Arbor checks each destination again and asks before replacing anything."
                : "“Uncertain” items were being written when Arbor stopped, so the destination may hold a partial copy. Retry remaining \(job.kind == .copy ? "copies" : "moves") the items that aren't completed. Arbor checks each destination again and asks before replacing anything.",
            font: FileOpsStyle.captionFont, color: Theme.secondaryText, wraps: true)
        explain.preferredMaxLayoutWidth = 516

        let retryable = job.retryableSources
        let retry = WinButton(waiting ? "Start" : "Retry remaining", accent: true) { [weak self] in self?.retry() }
        retry.isEnabled = !retryable.isEmpty && FileOps.isPlainFolder(job.destination)
        let dismiss = WinButton("Dismiss") { [weak self] in self?.finish() }
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
            case .completed: text = item.state == .skipped ? "Skipped" : (item.state == .sourceRemains ? "Copied; original kept" : "Completed")
            case .notDone:
                text = job.wasWaiting ? "Waiting to start" : item.state == .failed ? "Not done (failed)" : "Not done"
                color = Theme.secondaryText
            case .uncertain:
                text = "Uncertain"
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
