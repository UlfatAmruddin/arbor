import AppKit
import ArborCore

extension Prefs {
    private static func setQueue(_ value: Any, _ key: String) {
        store.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["key": key])
    }

    /// Beyond Explorer (FE-127): jobs that use a drive another running job uses wait their turn.
    /// Off by default: Windows runs every transfer at once.
    static var fileOpsQueueSameDrive: Bool {
        get { store.bool(forKey: "fileOpsQueueSameDrive") }
        set { setQueue(newValue, "fileOpsQueueSameDrive") }
    }

    /// Beyond Explorer (FE-127): at most this many copy/move jobs at once; 0 = no limit (default).
    static var fileOpsConcurrencyLimit: Int {
        get { max(0, store.integer(forKey: "fileOpsConcurrencyLimit")) }
        set { setQueue(max(0, newValue), "fileOpsConcurrencyLimit") }
    }

    /// Beyond Explorer (FE-130): whether new copy jobs start with "Verify after copying" ticked. Off.
    static var fileOpsVerifyByDefault: Bool {
        get { store.bool(forKey: "fileOpsVerifyByDefault") }
        set { setQueue(newValue, "fileOpsVerifyByDefault") }
    }
}

/// Holds jobs back according to the queue settings and the user's reordering (FE-127), using
/// `TransferScheduler`. With the default settings every job starts at once, as in Explorer.
/// Main thread only.
final class TransferQueueController {
    static let shared = TransferQueueController()

    private var scheduler = TransferScheduler()
    /// Launch closures of jobs that haven't started.
    private var pending: [UUID: () -> Void] = [:]
    /// Cancelled before their drives were known.
    private var cancelledEarly: Set<UUID> = []
    private var observer: NSObjectProtocol?

    func install() {
        scheduler = TransferScheduler(queueSameDrive: Prefs.fileOpsQueueSameDrive, concurrencyLimit: Prefs.fileOpsConcurrencyLimit)
        OperationCenter.admission.provide("file-operations-extras.transfer-queue") { job, launch in TransferQueueController.shared.admit(job, launch) }
        observer = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] note in
            guard let key = note.userInfo?["key"] as? String, key.hasPrefix("fileOpsQueue") || key == "fileOpsConcurrencyLimit" else { return }
            self?.reconfigure()
        }
    }

    private func admit(_ job: OperationCenter.Job, _ launch: @escaping () -> Void) {
        pending[job.id] = launch
        let urls = job.transfer.sources + [job.transfer.destination]
        // Volume identities can be slow on network paths: look them up off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let drives = Set(urls.compactMap(FileOps.driveIdentity))
            DispatchQueue.main.async {
                let shared = TransferQueueController.shared
                var start = shared.scheduler.add(job.id, drives: drives)
                if shared.cancelledEarly.remove(job.id) != nil { start += shared.scheduler.startNow(job.id) }
                shared.launch(start)
            }
        }
    }

    private func launch(_ ids: [UUID]) {
        for id in ids { pending.removeValue(forKey: id)?() }
        OperationCenter.shared.post()
    }

    func jobFinished(_ job: OperationCenter.Job) {
        pending[job.id] = nil
        launch(scheduler.remove(job.id))
    }

    /// A waiting job that is cancelled starts at once and ends immediately as "cancelled", so it
    /// goes through the normal report and history like any other job.
    func jobCancelled(_ job: OperationCenter.Job) {
        guard pending[job.id] != nil else { return }
        if scheduler.entry(job.id) == nil { cancelledEarly.insert(job.id); return }
        launch(scheduler.startNow(job.id))
    }

    private func reconfigure() {
        launch(scheduler.reconfigure(queueSameDrive: Prefs.fileOpsQueueSameDrive, concurrencyLimit: Prefs.fileOpsConcurrencyLimit))
    }

    // MARK: Per-job controls

    func isWaiting(_ job: OperationCenter.Job) -> Bool { pending[job.id] != nil }
    func reason(_ job: OperationCenter.Job) -> String { scheduler.reason(for: job.id) ?? "Waiting to start" }
    func position(_ job: OperationCenter.Job) -> Int? { scheduler.position(of: job.id) }
    func isDeferred(_ job: OperationCenter.Job) -> Bool { scheduler.entry(job.id)?.deferred ?? false }
    func canMove(_ job: OperationCenter.Job, by offset: Int) -> Bool { scheduler.canMove(job.id, by: offset) }

    func startNow(_ job: OperationCenter.Job) { launch(scheduler.startNow(job.id)) }
    func move(_ job: OperationCenter.Job, by offset: Int) {
        launch(scheduler.move(job.id, by: offset))
        OperationsWindow.shared.reorder(by: waitingOrder)
    }
    func setDeferred(_ job: OperationCenter.Job, _ deferred: Bool) {
        launch(scheduler.setDeferred(job.id, deferred))
        OperationsWindow.shared.reorder(by: waitingOrder)
    }

    /// Running jobs first, then waiting ones in the order they will start.
    var waitingOrder: [UUID] { scheduler.running + scheduler.waiting }

    var scriptDescription: String {
        let waiting = scheduler.waiting.compactMap { id in OperationCenter.shared.jobs.first { $0.id == id } }
            .map { "\($0.transfer.sources.first?.lastPathComponent ?? "?")\(isDeferred($0) ? "(deferred)" : "")" }
        return "queue: sameDrive=\(scheduler.queueSameDrive) limit=\(scheduler.concurrencyLimit) running=\(scheduler.running.count) waiting=[\(waiting.joined(separator: ", "))]"
    }
}

// MARK: - Queue options menu (progress window footer and Window menu)

enum QueueOptionsMenu {
    static func items() -> [NSMenuItem] {
        let header = NSMenuItem(title: L10n.tr("Arbor extras (File Explorer runs every transfer at once)"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        let same = ClosureMenuItem(L10n.tr("Queue transfers to the same drive")) { Prefs.fileOpsQueueSameDrive.toggle() }
        same.state = Prefs.fileOpsQueueSameDrive ? .on : .off
        var list: [NSMenuItem] = [header, same, .separator()]
        let limitTitle = NSMenuItem(title: L10n.tr("Run at most"), action: nil, keyEquivalent: "")
        limitTitle.isEnabled = false
        list.append(limitTitle)
        for value in [0, 1, 2, 3, 4] {
            let item = ClosureMenuItem(value == 0 ? "No limit" : (value == 1 ? "1 operation at a time" : "\(value) operations at a time")) {
                Prefs.fileOpsConcurrencyLimit = value
            }
            item.state = Prefs.fileOpsConcurrencyLimit == value ? .on : .off
            item.indentationLevel = 1
            list.append(item)
        }
        list.append(.separator())
        let verify = ClosureMenuItem(L10n.tr("Verify new copies by default")) { Prefs.fileOpsVerifyByDefault.toggle() }
        verify.state = Prefs.fileOpsVerifyByDefault ? .on : .off
        list.append(verify)
        return list
    }

    static func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items().forEach(menu.addItem)
        return menu
    }
}

// MARK: - Extra rows in a job's progress panel

/// Under a job's percentage: the queue controls while it waits ("Start now", "Move up", "Move down",
/// "Defer") and, for copies, "Verify after copying".
final class JobPanelExtras: NSStackView {
    let job: OperationCenter.Job
    private let waitingLabel = FileOpsStyle.label("", font: FileOpsStyle.captionFont, color: Theme.secondaryText)
    private lazy var startNow = FileOpsLinkButton(L10n.tr("Start now")) { [weak self] in self.map { TransferQueueController.shared.startNow($0.job) } }
    private lazy var moveUp = FileOpsLinkButton(L10n.tr("Move up")) { [weak self] in self.map { TransferQueueController.shared.move($0.job, by: -1) } }
    private lazy var moveDown = FileOpsLinkButton(L10n.tr("Move down")) { [weak self] in self.map { TransferQueueController.shared.move($0.job, by: 1) } }
    private lazy var deferButton = FileOpsLinkButton(L10n.tr("Defer")) { [weak self] in
        guard let self else { return }
        TransferQueueController.shared.setDeferred(self.job, !TransferQueueController.shared.isDeferred(self.job))
    }
    private let queueRow = NSStackView()
    let verify = NSButton(checkboxWithTitle: L10n.tr("Verify after copying"), target: nil, action: nil)

    init(job: OperationCenter.Job) {
        self.job = job
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        for b in [startNow, moveUp, moveDown, deferButton] { b.setContentHuggingPriority(.required, for: .horizontal) }
        queueRow.setViews([startNow, moveUp, moveDown, deferButton], in: .leading)
        queueRow.spacing = 14
        addArrangedSubview(waitingLabel)
        addArrangedSubview(queueRow)
        verify.font = FileOpsStyle.captionFont
        verify.target = self
        verify.action = #selector(verifyChanged)
        verify.toolTip = L10n.tr("After copying, Arbor reads each copy back and compares its size and SHA-256 checksum with the original.")
        verify.state = JobVerification.isRequested(job) ? .on : .off
        verify.isHidden = job.transfer.kind != .copy
        addArrangedSubview(verify)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func verifyChanged() { JobVerification.setRequested(job, verify.state == .on) }

    func refresh() {
        let queue = TransferQueueController.shared
        let waiting = queue.isWaiting(job) && !job.transfer.isCancelled
        waitingLabel.isHidden = !waiting
        queueRow.isHidden = !waiting
        if waiting {
            let place = queue.position(job).map { " · Number \($0) in the queue" } ?? ""
            waitingLabel.stringValue = queue.reason(job) + place
            moveUp.isEnabled = queue.canMove(job, by: -1)
            moveDown.isEnabled = queue.canMove(job, by: 1)
            moveUp.alphaValue = moveUp.isEnabled ? 1 : 0.4
            moveDown.alphaValue = moveDown.isEnabled ? 1 : 0.4
            deferButton.title = queue.isDeferred(job) ? "Don't defer" : "Defer"
            deferButton.attributedTitle = NSAttributedString(string: deferButton.title,
                                                             attributes: [.font: FileOpsStyle.captionFont, .foregroundColor: FileOpsStyle.link])
        }
        verify.isEnabled = JobVerification.canChange(job)
        verify.state = JobVerification.isRequested(job) ? .on : .off
        isHidden = !waiting && verify.isHidden
    }

    /// Replaces the percentage line while a job waits or verifies.
    static func statusText(for job: OperationCenter.Job) -> String? {
        if let v = JobVerification.progress(job) {
            let pct = v.total > 0 ? Int((Double(v.done) / Double(v.total) * 100).rounded(.down)) : 0
            return "Verifying copies… \(min(pct, 100))%"
        }
        if TransferQueueController.shared.isWaiting(job), !job.transfer.isCancelled {
            return TransferQueueController.shared.isDeferred(job) ? "Deferred" : "Waiting to start"
        }
        return nil
    }

    /// The bar's fraction while verifying.
    static func fraction(for job: OperationCenter.Job) -> Double? {
        guard let v = JobVerification.progress(job) else { return nil }
        return v.total > 0 ? min(1, Double(v.done) / Double(v.total)) : 0
    }

    var debugText: String {
        var parts: [String] = []
        if !queueRow.isHidden { parts.append("waiting: \(waitingLabel.stringValue)") }
        if !verify.isHidden { parts.append("verify=\(verify.state == .on ? "on" : "off")\(verify.isEnabled ? "" : "(locked)")") }
        return parts.joined(separator: " | ")
    }
}

/// "Operation history" and "Queue options" at the right of the progress window's footer.
final class OperationsFooterExtras: NSStackView {
    private lazy var history = FileOpsLinkButton(L10n.tr("Operation history"), font: FileOpsStyle.bodyFont) { OperationHistoryWindow.shared.show() }
    private lazy var options: FileOpsLinkButton = FileOpsLinkButton(L10n.tr("Queue options"), font: FileOpsStyle.bodyFont) { [weak self] in
        guard let self else { return }
        QueueOptionsMenu.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: self.options.bounds.height + 4), in: self.options)
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 16
        translatesAutoresizingMaskIntoConstraints = false
        setViews([options, history], in: .trailing)
        options.toolTip = L10n.tr("Beyond File Explorer: queue transfers to the same drive, limit how many run at once.")
    }
    required init?(coder: NSCoder) { fatalError() }
}
