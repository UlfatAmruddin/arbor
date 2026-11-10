import AppKit
import ArborCore

/// Speed, time remaining and the speed-graph samples for one job. Main thread only.
final class JobMonitor {
    struct Sample { let fraction: Double; let speed: Double }

    private var rate = TransferRateEstimator()
    private var wasHeld = false
    private var lastSampleTime: TimeInterval = 0
    private(set) var samples: [Sample] = []
    private(set) var speed: Double?
    private(set) var secondsRemaining: TimeInterval?
    /// Set when the user pressed Cancel and the worker is winding down.
    var isCancelling = false

    func absorb(_ progress: TransferProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        // Paused or waiting for an answer: that time isn't transfer time.
        let held = progress.phase == .paused || progress.phase == .waiting
        if held != wasHeld {
            if held { rate.pause() } else { rate.resume() }
            wasHeld = held
        }
        if progress.phase == .running, progress.bytesTotal != nil {
            rate.record(bytes: progress.bytesDone, at: now)
        }
        speed = rate.bytesPerSecond(at: now)
        secondsRemaining = progress.bytesRemaining.flatMap { rate.secondsRemaining($0, at: now) }
        if progress.phase == .running, let fraction = progress.fraction, let speed, now - lastSampleTime >= 0.2 {
            lastSampleTime = now
            samples.append(Sample(fraction: fraction, speed: speed))
            if samples.count > 600 {   // bounded: keep every other point
                samples = samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            }
        }
    }
}

/// Progress window (FE-114, FE-115, FE-116): one panel per job taking over ~0.8 s.
/// Closing only hides it; jobs keep running and the status bar keeps its line.
final class OperationsWindow: NSObject, NSWindowDelegate {
    static let shared = OperationsWindow()
    static let showDelay: TimeInterval = 0.8

    private var window: NSWindow?
    private let header = FileOpsStyle.label("", font: FileOpsStyle.bodyFont)
    private lazy var headerBox: NSStackView = {
        let box = NSStackView(views: [header])
        box.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 0, right: 20)
        return box
    }()
    private let stack = NSStackView()
    private let toggle = DetailsToggle()
    private var panels: [ObjectIdentifier: JobPanelView] = [:]
    private var observer: NSObjectProtocol?
    private var userHidden = false

    var isVisible: Bool { window?.isVisible ?? false }
    var expanded: Bool {
        get { Prefs.fileOpsMoreDetails }
        set {
            Prefs.fileOpsMoreDetails = newValue
            toggle.expanded = newValue
            panels.values.forEach { $0.setExpanded(newValue) }
            fit()
        }
    }

    func jobStarted(_ job: OperationCenter.Job) {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: OperationCenter.changed, object: nil, queue: .main) { [weak self] _ in
                self?.sync()
            }
        }
        if isVisible { sync(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self, weak job] in
            guard let self, let job, OperationCenter.shared.jobs.contains(where: { $0 === job }), !self.userHidden else { return }
            self.show()
        }
    }

    /// Shows the window (also from Window ▸ Show File Operations).
    func show() {
        userHidden = false
        guard !OperationCenter.shared.jobs.isEmpty else { return }
        let window = self.window ?? makeWindow()
        sync(force: true)
        if !window.isVisible {
            if let parent = BrowserWindowController.active?.window {
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2))
            } else {
                window.center()
            }
        }
        if AppDelegate.isHeadless {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary]
        let root = FillView(FileOpsStyle.background)
        root.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let footer = FillView(FileOpsStyle.footer)
        footer.topLine = FileOpsStyle.footerLine
        toggle.expanded = Prefs.fileOpsMoreDetails
        toggle.onToggle = { [weak self] in self?.expanded = $0 }
        footer.addSubview(toggle)
        let extras = OperationsFooterExtras()
        footer.addSubview(extras)
        let top = NSStackView(views: [headerBox, stack])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 0
        top.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        top.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(top)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            root.widthAnchor.constraint(equalToConstant: 460).withPriority(.defaultLow),
            extras.leadingAnchor.constraint(greaterThanOrEqualTo: toggle.trailingAnchor, constant: 16),
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: top.widthAnchor),
            footer.topAnchor.constraint(equalTo: top.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 44),
            toggle.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            toggle.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            extras.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18),
            extras.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        window.contentView = root
        self.window = window
        return window
    }

    /// Syncs panels with the running jobs; hides the window when the last one ends.
    func sync(force: Bool = false) {
        let jobs = OperationCenter.shared.jobs
        guard let window else { return }
        if jobs.isEmpty {
            window.orderOut(nil)
            panels.values.forEach { $0.removeFromSuperview() }
            panels.removeAll()
            return
        }
        guard window.isVisible || force else { return }
        let ids = Set(jobs.map(ObjectIdentifier.init))
        for (id, panel) in panels where !ids.contains(id) {
            panel.removeFromSuperview()
            panels[id] = nil
        }
        var changedLayout = false
        for (index, job) in jobs.enumerated() {
            let id = ObjectIdentifier(job)
            let panel: JobPanelView
            if let existing = panels[id] {
                panel = existing
            } else {
                panel = JobPanelView(job: job)
                panel.setExpanded(expanded)
                panels[id] = panel
                stack.addArrangedSubview(panel)
                panel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                changedLayout = true
            }
            panel.showsSeparator = index > 0
            panel.refresh()
        }
        let many = jobs.count > 1
        if headerBox.isHidden == many { changedLayout = true }
        headerBox.isHidden = !many
        let waiting = jobs.filter { TransferQueueController.shared.isWaiting($0) }.count
        let summary = waiting == 0 ? L10n.plural(one: "%lld operation running", other: "%lld operations running", jobs.count)
            : L10n.format("%@ running, %@ waiting", StatusText.number(jobs.count - waiting), StatusText.number(waiting))   // queue controls (FE-127)
        header.stringValue = many ? summary : ""
        window.title = many ? summary : panels[ObjectIdentifier(jobs[0])]?.windowTitle ?? ""
        if changedLayout || force { fit() }
    }

    /// Queue order: running first, then waiting jobs in start order.
    func reorder(by ids: [UUID]) {
        let ordered = ids.compactMap { id in OperationCenter.shared.jobs.first { $0.id == id } }.compactMap { panels[ObjectIdentifier($0)] }
        guard ordered.count == stack.arrangedSubviews.count else { return }
        for panel in ordered {
            stack.removeArrangedSubview(panel)
            stack.addArrangedSubview(panel)
        }
        for (index, panel) in ordered.enumerated() { panel.showsSeparator = index > 0 }
        fit()
    }

    private func fit() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userHidden = true
        sender.orderOut(nil)
        return false
    }

    // MARK: Scripting

    var scriptDescription: String {
        let jobs = OperationCenter.shared.jobs
        return "window=\(isVisible ? "visible" : "hidden") title=\(window?.title ?? "-") panels=" + jobs.compactMap { panels[ObjectIdentifier($0)]?.debugText }.joined(separator: " || ")
    }

    var snapshotWindow: NSWindow? { window }
}

/// One job inside the progress window.
final class JobPanelView: NSView {
    let job: OperationCenter.Job
    private let fromTo: NSStackView
    private let percent = FileOpsStyle.label("", font: FileOpsStyle.percentFont)
    private let pause = ChromeButton(symbol: "pause.fill", tooltip: "Pause")
    private let cancel = ChromeButton(symbol: "xmark", tooltip: "Cancel")
    private let bar = TransferBarView()
    private let graph = SpeedGraphView()
    private let nameValue = FileOpsStyle.label("")
    private let timeValue = FileOpsStyle.label("")
    private let itemsValue = FileOpsStyle.label("")
    private let grid: NSGridView
    private let separator = FillView(FileOpsStyle.separator)
    private var expanded = false
    private lazy var extras = JobPanelExtras(job: job)

    var showsSeparator = false { didSet { separator.isHidden = !showsSeparator } }

    init(job: OperationCenter.Job) {
        self.job = job
        let transfer = job.transfer
        let sourceFolder = transfer.sources.first?.deletingLastPathComponent()
        fromTo = fromToLine(verb: transfer.kind.progressVerb, count: transfer.sources.count, source: sourceFolder,
                            destination: transfer.destination) { url in
            if let browser = BrowserWindowController.active { browser.openTab(.folder(url)) }
        }
        let caption = { (text: String) -> NSTextField in FileOpsStyle.label(text, color: Theme.secondaryText) }
        grid = NSGridView(views: [[caption(L10n.tr("Name:")), nameValue], [caption(L10n.tr("Time remaining:")), timeValue], [caption(L10n.tr("Items remaining:")), itemsValue]])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        for button in [pause, cancel] {
            button.fixedWidth = 30
            button.fixedHeight = 28
            button.symbolSize = 13
        }
        pause.onClick = { [weak self] _ in self?.togglePause() }
        cancel.onClick = { [weak self] _ in self?.cancelJob() }
        pause.setAccessibilityLabel(L10n.tr("Pause"))
        cancel.setAccessibilityLabel(L10n.tr("Cancel"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let percentRow = NSStackView(views: [percent, spacer, pause, cancel])
        percentRow.orientation = .horizontal
        percentRow.spacing = 2
        percentRow.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [fromTo, percentRow, extras, bar, graph, grid])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(4, after: fromTo)
        column.setCustomSpacing(12, after: graph)
        column.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(column)
        separator.isHidden = true
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            separator.heightAnchor.constraint(equalToConstant: 1),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            percentRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            bar.heightAnchor.constraint(equalToConstant: 14),
            graph.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            graph.heightAnchor.constraint(equalToConstant: 92),
            fromTo.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, constant: -40),
            nameValue.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
        ])
        setExpanded(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setExpanded(_ value: Bool) {
        expanded = value
        bar.isHidden = value
        graph.isHidden = !value
        grid.isHidden = !value
        refresh()
    }

    private func togglePause() {
        if job.transfer.isPaused { job.transfer.resume() } else { job.transfer.pause() }
        refresh()
    }

    private func cancelJob() {
        OperationCenter.shared.cancel(job)
        refresh()
    }

    private var percentText: String {
        let p = job.progress
        if job.monitor.isCancelling || job.transfer.isCancelled { return L10n.tr("Cancelling…") }
        if let status = JobPanelExtras.statusText(for: job) { return job.transfer.isPaused ? L10n.format("Paused - %@", "\(status)") : status }
        if p.phase == .discovering { return L10n.tr("Discovering items…") }
        let pct = L10n.format("%@%% complete", StatusText.number(Int(((p.fraction ?? 0) * 100).rounded(.down))))
        if job.transfer.isPaused { return L10n.format("Paused - %@", "\(pct)") }
        return pct
    }

    var windowTitle: String {
        let p = job.progress
        if let status = JobPanelExtras.statusText(for: job) { return status }
        if p.phase == .discovering { return L10n.tr("Discovering items…") }
        return L10n.format("%@%% complete", StatusText.number(Int(((p.fraction ?? 0) * 100).rounded(.down))))
    }

    func refresh() {
        let p = job.progress
        let paused = job.transfer.isPaused
        percent.stringValue = percentText
        pause.symbolName = paused ? "play.fill" : "pause.fill"
        pause.toolTip = paused ? L10n.tr("Resume") : L10n.tr("Pause")
        pause.setAccessibilityLabel(paused ? L10n.tr("Resume") : L10n.tr("Pause"))
        let verifying = JobVerification.progress(job) != nil
        pause.isEnabled = !job.transfer.isCancelled && (p.phase != .finishing || verifying)
        cancel.isEnabled = !job.transfer.isCancelled
        bar.fraction = JobPanelExtras.fraction(for: job) ?? p.fraction
        extras.refresh()
        bar.paused = paused
        graph.samples = job.monitor.samples
        graph.fraction = p.fraction ?? 0
        graph.speed = paused ? nil : job.monitor.speed
        graph.paused = paused
        nameValue.stringValue = p.currentName ?? ""
        if p.phase == .discovering {
            timeValue.stringValue = L10n.tr("Calculating…")
            itemsValue.stringValue = L10n.format("Calculating… (%@ found)", "\(StatusText.items(p.itemsDone))")
        } else {
            timeValue.stringValue = paused ? L10n.tr("Paused") : (job.monitor.secondsRemaining.map(TransferRateEstimator.describeRemaining) ?? L10n.tr("Calculating…"))
            if let items = p.itemsRemaining {
                let bytes = p.bytesRemaining.map { " (\(StatusText.bytes($0)))" } ?? ""
                itemsValue.stringValue = "\(items.formatted())\(bytes)"
            } else {
                itemsValue.stringValue = "\(max(0, p.total - p.completed).formatted())"
            }
        }
        setAccessibilityLabel((job.transfer.kind == .copy ? L10n.format("Copying, %@", percentText) : L10n.format("Moving, %@", percentText)))
    }

    var debugText: String {
        "\(percent.stringValue) | paused=\(job.transfer.isPaused) | name=\(nameValue.stringValue) | time=\(timeValue.stringValue) | items=\(itemsValue.stringValue) | speed=\(graph.speed.map(TransferRateEstimator.describeSpeed) ?? "-") | expanded=\(expanded)\(extras.debugText.isEmpty ? "" : " | " + extras.debugText)"
    }
}

/// The compact green bar (yellow while paused).
final class TransferBarView: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    var paused = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        FileOpsStyle.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        FileOpsStyle.graphBorder.setStroke()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).stroke()
        guard let fraction, fraction > 0 else { return }
        let fill = NSRect(x: 1, y: 1, width: max(4, (bounds.width - 2) * CGFloat(fraction)), height: bounds.height - 2)
        (paused ? FileOpsStyle.paused : FileOpsStyle.progress).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
}

/// "More details" speed graph: X is progress, Y speed, with a labelled current-speed line, like Explorer.
final class SpeedGraphView: NSView {
    var samples: [JobMonitor.Sample] = [] { didSet { needsDisplay = true } }
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var speed: Double? { didSet { needsDisplay = true } }
    var paused = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.tr("Speed graph"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        FileOpsStyle.graphBackground.setFill()
        frame.fill()
        // Light grid like the Explorer graph.
        FileOpsStyle.graphGrid.setStroke()
        let grid = NSBezierPath()
        for i in 1..<10 {
            let x = frame.minX + frame.width * CGFloat(i) / 10
            grid.move(to: NSPoint(x: x, y: frame.minY)); grid.line(to: NSPoint(x: x, y: frame.maxY))
        }
        for i in 1..<4 {
            let y = frame.minY + frame.height * CGFloat(i) / 4
            grid.move(to: NSPoint(x: frame.minX, y: y)); grid.line(to: NSPoint(x: frame.maxX, y: y))
        }
        grid.lineWidth = 1
        grid.stroke()

        let color = paused ? FileOpsStyle.paused : FileOpsStyle.progress
        let top = max(samples.map(\.speed).max() ?? 0, speed ?? 0) * 1.25
        let plot = frame.insetBy(dx: 1, dy: 1)
        // Progress fill up to the current fraction (light), then the speed area over it.
        color.withAlphaComponent(0.12).setFill()
        NSRect(x: plot.minX, y: plot.minY, width: plot.width * CGFloat(min(1, fraction)), height: plot.height).fill()
        if top > 0, !samples.isEmpty {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: plot.minX, y: plot.minY))
            area.line(to: NSPoint(x: plot.minX, y: plot.minY + plot.height * CGFloat(samples[0].speed / top)))
            var last = NSPoint(x: plot.minX, y: plot.minY)
            for sample in samples {
                last = NSPoint(x: plot.minX + plot.width * CGFloat(min(1, sample.fraction)),
                               y: plot.minY + plot.height * CGFloat(sample.speed / top))
                area.line(to: last)
            }
            area.line(to: NSPoint(x: last.x, y: plot.minY))
            area.close()
            color.withAlphaComponent(0.45).setFill()
            area.fill()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: plot.minY + plot.height * CGFloat(samples[0].speed / top)))
            for sample in samples {
                line.line(to: NSPoint(x: plot.minX + plot.width * CGFloat(min(1, sample.fraction)),
                                      y: plot.minY + plot.height * CGFloat(sample.speed / top)))
            }
            color.setStroke()
            line.lineWidth = 1.5
            line.stroke()
        }
        if let speed, top > 0 {
            let y = plot.minY + plot.height * CGFloat(speed / top)
            FileOpsStyle.speedLine.setStroke()
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: plot.minX, y: y)); rule.line(to: NSPoint(x: plot.maxX, y: y))
            rule.lineWidth = 1
            rule.stroke()
            let text = L10n.format("Speed: %@", "\(TransferRateEstimator.describeSpeed(speed))") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: FileOpsStyle.captionFont, .foregroundColor: Theme.primaryText]
            let size = text.size(withAttributes: attrs)
            let textY = min(y + 2, plot.maxY - size.height - 1)
            text.draw(at: NSPoint(x: plot.maxX - size.width - 6, y: textY), withAttributes: attrs)
        }
        FileOpsStyle.graphBorder.setStroke()
        NSBezierPath(rect: frame).stroke()
    }
}
