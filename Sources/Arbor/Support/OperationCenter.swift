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
        /// False for jobs that are themselves an undo or redo (they register their own inverse).
        var registersUndo = true
        /// Set once the job was allowed to run (a queued job waits until then).
        var hasLaunched = false
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
    static let prepareJob = Observers<Job>(
        "OperationCenter.prepareJob", "A job exists and hasn't run yet (set resolvers).", signature: "(job)")
    /// Decides when a job starts: calls `launch` now or later (queue controls). No provider = at once.
    static let admission = Provided<((Job, _ launch: @escaping () -> Void) -> Void)?>(
        "OperationCenter.admission", "Decides when a job starts (transfer queue).", signature: "(job, launch)", default: nil)
    /// Runs on the job's task after the transfer and before it is reported (verification). Not on the main thread.
    static let afterRun = Provided<(@Sendable (Job, TransferReport) async -> Void)?>(
        "OperationCenter.afterRun", "Runs on the job's task after the transfer, before it is reported (verification).",
        signature: "async (job, report)", default: nil)
    /// The job ended; called first in `finish` (history, queue bookkeeping).
    static let jobFinished = Observers<(job: Job, report: TransferReport)>(
        "OperationCenter.jobFinished", "A job ended (history, queue bookkeeping).", signature: "(job, report)")
    /// Cancel was pressed for one job (a job that is still waiting is started so it ends at once).
    static let jobCancelled = Observers<Job>(
        "OperationCenter.jobCancelled", "Cancel was pressed for a job.", signature: "(job)")

    func cancel(_ job: Job) {
        job.monitor.isCancelling = true
        job.transfer.cancel()
        Self.jobCancelled.send(job)
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
        // Jobs still waiting in the queue never started: keep their journals as they are, so the next
        // launch offers to start them again (JobRecovery), and don't wait for them.
        for job in jobs where !job.hasLaunched {
            job.transfer.journal?.abandon()
            jobs.removeAll { $0 === job }
        }
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
    func start(_ kind: TransferKind, sources: [URL], destination: URL, window: NSWindow?, registersUndo: Bool = true,
               completion: @escaping (TransferReport) -> Void) {
        let transfer = FileTransfer(kind: kind, sources: sources, destination: destination,
                                    journal: FileOpsEnvironment.makeJournal(kind, sources: sources, destination: destination),
                                    options: FileOpsEnvironment.transferOptions)
        let job = Job(transfer: transfer, window: window)
        job.registersUndo = registersUndo
        jobs.append(job)
        Self.prepareJob.send(job)
        post()
        OperationsWindow.shared.jobStarted(job)
        // While quitting, a queued job is never started (its journal is kept for the next launch instead).
        let launch = { if !OperationCenter.shared.isQuitting { Self.run(job, completion: completion) } }
        if let admission = Self.admission.value { admission(job, launch) } else { launch() }
    }

    private static func run(_ job: Job, completion: @escaping (TransferReport) -> Void) {
        let transfer = job.transfer
        job.hasLaunched = true
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
            await OperationCenter.afterRun.value?(job, report)
            DispatchQueue.main.async {
                OperationCenter.shared.finish(job, report, completion)
            }
        }
    }

    private func finish(_ job: Job, _ report: TransferReport, _ completion: (TransferReport) -> Void) {
        Self.jobFinished.send((job, report))
        jobs.removeAll { $0 === job }
        post()
        if !job.registersUndo {
            // An undo or redo running as a job: its caller registers the inverse.
        } else if report.kind == .move {
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

    /// `actionName` is what Edit ▸ Undo/Redo say for this step and every later round of it ("New Folder",
    /// "Restore", "Create Shortcut"…), not just the first.
    func registerUndoTrash(_ pairs: [(original: URL, trashed: URL)], actionName: String = "Move to Trash") {
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
            center.undoManager.registerUndo(withTarget: center) { c in c.trashAgain(restored, actionName: actionName) }
            center.undoManager.setActionName(actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func trashAgain(_ urls: [URL], actionName: String) {
        var pairs: [(original: URL, trashed: URL)] = []
        for url in urls {
            if let trashed = try? SystemTrash.trash(url) { pairs.append((url, trashed)) }
        }
        registerUndoTrash(pairs, actionName: actionName)
    }

    /// Undo puts moved items back (another volume: as a normal move job with progress and cancel, see
    /// `UndoMoveBack.swift`); Redo moves them again. Each step registers its inverse at once.
    func registerUndoMove(_ pairs: [(source: URL, destination: URL)]) {
        registerMoveStep { pairs.map { MoveBack.Item(from: $0.destination, to: $0.source) } }
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
                center.registerUndoTrash([(url, trashed)], actionName: "New Folder")
            }
        }
        undoManager.setActionName("New Folder")
    }

    func report(_ message: String, _ info: String) {
        NSAlert.show(message, info, in: NSApp.keyWindow)
    }
}
