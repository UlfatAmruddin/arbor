import AppKit
import ArborCore

/// App-wide owner of running transfers and the shared undo stack.
/// Jobs belong to the app, not to a tab: closing a tab doesn't cancel its transfer.
final class OperationCenter {
    static let shared = OperationCenter()
    static let changed = Notification.Name("ArborOperationsChanged")

    /// Shared across tabs so ⌘Z undoes the last file action anywhere, like Explorer.
    let undoManager = UndoManager()

    /// Mutable state is only read and written on the main queue (every access below
    /// hops through `DispatchQueue.main`); the background task only holds the reference.
    final class Job: @unchecked Sendable {
        let transfer: FileTransfer
        var progress: TransferProgress
        weak var window: NSWindow?
        /// Speed, time remaining and graph samples (main thread).
        let monitor = JobMonitor()
        /// Identity for the operation history and the queue.
        let id = UUID()
        let created = Date()
        /// How dialogs describe the job when its real source is a hidden staging folder (extracting an archive).
        var presentedAs: PresentedJob?
        init(transfer: FileTransfer, window: NSWindow?) {
            self.transfer = transfer
            self.window = window
            progress = TransferProgress(completed: 0, total: transfer.sources.count, currentName: nil, phase: .discovering)
        }
    }

    private(set) var jobs: [Job] = []
    var hasActiveJobs: Bool { !jobs.isEmpty || !activities.isEmpty }
    /// Set while the app quits: results are kept in the journal for review, not shown in alerts.
    private(set) var isQuitting = false

    /// The status bar's compact line: "Copying 3 items · 37% complete" (the progress window has the details).
    var statusLine: (text: String, fraction: Double)? {
        guard let job = jobs.first else { return activities.first.map { ($0.text, $0.fraction) } }
        let p = job.progress
        var text = "\(job.transfer.kind.progressVerb) \(StatusText.items(p.total))"
        if p.phase == .discovering {
            text += " · Discovering items…"
        } else {
            text += " · \(Int(((p.fraction ?? 0) * 100).rounded(.down)))% complete"
            if job.transfer.isPaused { text += " · Paused" }
        }
        if jobs.count > 1 { text += " (+\(jobs.count - 1) more)" }
        return (text, p.fraction ?? 0)
    }

    // MARK: - Hooks (Features/FileOperations: queue, verification, history)

    /// Called once a job exists, before it runs (e.g. to set its "copy without properties?" resolver).
    static var prepareJob: ((Job) -> Void)?
    /// Decides when a job starts: calls `launch` now or later (queue controls). Nil = at once.
    static var admission: ((Job, _ launch: @escaping () -> Void) -> Void)?
    /// Runs on the job's task after the transfer and before it is reported (verification).
    static var afterRun: (@Sendable (Job, TransferReport) async -> Void)?
    /// The job ended; called first in `finish` (history, queue bookkeeping).
    static var jobFinished: ((Job, TransferReport) -> Void)?
    /// Cancel was pressed for one job (a job that is still waiting is started so it ends at once).
    static var jobCancelled: ((Job) -> Void)?

    func cancel(_ job: Job) {
        job.monitor.isCancelling = true
        job.transfer.cancel()
        Self.jobCancelled?(job)
        post()
    }

    func cancelAll() {
        jobs.forEach { $0.transfer.cancel() }
        activities.forEach { $0.cancel() }
    }

    // MARK: - Other long-running work (extracting, compressing, mounting…)

    /// Work that isn't a FileTransfer but shows in the status bar like one and stops on Cancel or quit.
    final class Activity {
        var text: String
        var fraction: Double = 0
        let cancel: () -> Void
        init(text: String, cancel: @escaping () -> Void) {
            self.text = text
            self.cancel = cancel
        }
    }

    private(set) var activities: [Activity] = []

    func begin(_ activity: Activity) {
        activities.append(activity)
        post()
    }

    func update(_ activity: Activity, text: String? = nil, fraction: Double) {
        if let text { activity.text = text }
        activity.fraction = min(max(fraction, 0), 1)
        post()
    }

    func end(_ activity: Activity) {
        activities.removeAll { $0 === activity }
        post()
    }

    /// Quit: cancel every job, keep their journals for review at next launch, and call `done`
    /// once they have stopped (the file being copied is removed first) or after 5 seconds.
    func cancelAllForQuit(then done: @escaping () -> Void) {
        isQuitting = true
        jobs.forEach {
            $0.transfer.retainsJournalWhenCancelled = true
            $0.transfer.cancel()
        }
        let deadline = Date().addingTimeInterval(5)
        func wait() {
            if jobs.isEmpty || Date() > deadline { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait)
        }
        wait()
    }

    /// Starts a copy/move job: journaled (FE-125), with Explorer's conflict and error dialogs and
    /// the progress window (Features/FileOperations).
    func start(_ kind: TransferKind, sources: [URL], destination: URL, window: NSWindow?,
               completion: @escaping (TransferReport) -> Void) {
        let transfer = FileTransfer(kind: kind, sources: sources, destination: destination,
                                    journal: FileOpsEnvironment.makeJournal(kind, sources: sources, destination: destination),
                                    options: FileOpsEnvironment.transferOptions)
        let job = Job(transfer: transfer, window: window)
        jobs.append(job)
        Self.prepareJob?(job)
        post()
        OperationsWindow.shared.jobStarted(job)
        let launch = { Self.run(job, completion: completion) }
        if let admission = Self.admission { admission(job, launch) } else { launch() }
    }

    private static func run(_ job: Job, completion: @escaping (TransferReport) -> Void) {
        let transfer = job.transfer
        Task.detached(priority: .userInitiated) {
            let report = await transfer.run(
                progress: { progress in
                    DispatchQueue.main.async {
                        job.progress = progress
                        job.monitor.absorb(progress)
                        OperationCenter.shared.post()
                    }
                },
                resolveConflicts: { conflicts in await ConflictFlow.resolve(conflicts, job: job) },
                resolveFailure: { failure in await FailureDialog.resolve(failure, job: job) })
            await OperationCenter.afterRun?(job, report)
            DispatchQueue.main.async {
                OperationCenter.shared.finish(job, report, completion)
            }
        }
    }

    private func finish(_ job: Job, _ report: TransferReport, _ completion: (TransferReport) -> Void) {
        Self.jobFinished?(job, report)
        jobs.removeAll { $0 === job }
        post()
        if report.kind == .move {
            let pairs = report.committed.filter { $0.source != $0.destination }
            if !pairs.isEmpty { registerUndoMove(pairs) }
        } else {
            let copies = report.committed.compactMap { pair in report.fingerprints[pair.destination].map { (pair.destination, $0) } }
            registerUndoCopy(copies)
        }
        let problems = report.problems
        if !problems.isEmpty, !isQuitting {
            let lines = problems.prefix(8).map { result -> String in
                switch result.outcome {
                case .failed(let why), .copiedButSourceRemains(_, let why), .partial(_, let why): return "• \(result.source.lastPathComponent): \(why)"
                default: return "• \(result.source.lastPathComponent)"
                }
            }
            let more = problems.count > 8 ? "\n…and \(problems.count - 8) more." : ""
            let done = report.committed.count
            NSAlert.show(
                problems.count == 1 ? "1 item couldn't be \(report.kind.pastVerb)." : "\(problems.count) items couldn't be \(report.kind.pastVerb).",
                (done > 0 ? "\(StatusText.items(done)) \(done == 1 ? "was" : "were") \(report.kind.pastVerb) successfully.\n\n" : "")
                    + lines.joined(separator: "\n") + more,
                in: job.window)
        }
        completion(report)
    }

    func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    // MARK: - Undo
    //
    // Undo never overwrites anything: if the original location is occupied again,
    // or the item has gone, that item is left alone and reported (FE-129).

    func registerUndoRename(from current: URL, back oldName: String) {
        let newName = current.lastPathComponent
        undoManager.registerUndo(withTarget: self) { center in
            do {
                let restored = try Renamer.rename(current, to: oldName)
                center.registerUndoRename(from: restored, back: newName)
            } catch {
                center.report("Couldn't undo the rename.", error.localizedDescription)
            }
        }
        undoManager.setActionName("Rename")
    }

    func registerUndoTrash(_ pairs: [(original: URL, trashed: URL)]) {
        undoManager.registerUndo(withTarget: self) { center in
            var restored: [URL] = []
            var skipped: [String] = []
            for pair in pairs {
                guard FileOps.exists(pair.trashed), !FileOps.exists(pair.original) else {
                    skipped.append(pair.original.lastPathComponent); continue
                }
                do {
                    try FileManager.default.moveItem(at: pair.trashed, to: pair.original)
                    restored.append(pair.original)
                } catch { skipped.append(pair.original.lastPathComponent) }
            }
            if !skipped.isEmpty {
                center.report("Some items couldn't be put back.",
                              "Their original location is taken or they're no longer in the Trash:\n" + skipped.joined(separator: ", "))
            }
            center.undoManager.registerUndo(withTarget: center) { c in c.trashAgain(restored) }
            center.undoManager.setActionName("Move to Trash")
        }
        undoManager.setActionName("Move to Trash")
    }

    private func trashAgain(_ urls: [URL]) {
        var pairs: [(original: URL, trashed: URL)] = []
        for url in urls {
            if let trashed = try? SystemTrash.trash(url) { pairs.append((url, trashed)) }
        }
        registerUndoTrash(pairs)
    }

    func registerUndoMove(_ pairs: [(source: URL, destination: URL)]) {
        undoManager.registerUndo(withTarget: self) { center in
            var undone: [(source: URL, destination: URL)] = []
            var skipped: [String] = []
            for pair in pairs {
                guard FileOps.exists(pair.destination), !FileOps.exists(pair.source) else {
                    skipped.append(pair.destination.lastPathComponent); continue
                }
                do {
                    try FileManager.default.moveItem(at: pair.destination, to: pair.source)
                    undone.append((pair.destination, pair.source))
                } catch { skipped.append(pair.destination.lastPathComponent) }
            }
            if !skipped.isEmpty {
                center.report("Some items couldn't be moved back.",
                              "They were changed or their original location is taken:\n" + skipped.joined(separator: ", "))
            }
            if !undone.isEmpty { center.registerUndoMove(undone) }
        }
        undoManager.setActionName("Move")
    }

    func registerUndoNewFolder(_ url: URL) {
        undoManager.registerUndo(withTarget: self) { center in
            guard FileOps.exists(url) else { return }
            guard FileOps.isEffectivelyEmpty(url) else {
                center.report("“\(url.lastPathComponent)” isn't empty anymore, so it wasn't removed.", "")
                return
            }
            if let trashed = try? SystemTrash.trash(url) {
                center.registerUndoTrash([(url, trashed)])
                center.undoManager.setActionName("New Folder")
            }
        }
        undoManager.setActionName("New Folder")
    }

    private func report(_ message: String, _ info: String) {
        NSAlert.show(message, info, in: NSApp.keyWindow)
    }
}
