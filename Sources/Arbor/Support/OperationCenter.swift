import AppKit
import ArborCore

/// Owns running transfers and the shared undo stack. Closing a tab doesn't cancel its transfer.
final class OperationCenter {
    static let shared = OperationCenter()
    static let changed = Notification.Name("ArborOperationsChanged")

    /// Shared across tabs so ⌘Z undoes the last file action anywhere, like Explorer.
    let undoManager = UndoManager()

    /// Mutable state is touched only on the main queue; the background task just holds the reference.
    final class Job: @unchecked Sendable {
        let transfer: FileTransfer
        var progress: TransferProgress
        weak var window: NSWindow?
        /// Speed, time remaining and graph samples (main thread).
        let monitor = JobMonitor()
        /// Identity for the operation history and the queue.
        let id = UUID()
        let created = Date()
        /// What dialogs show when the real source is a hidden staging folder (archive extraction).
        var presentedAs: PresentedJob?
        /// False for undo/redo jobs (they register their own inverse).
        var registersUndo = true
        /// Set once the job may run (queued jobs wait).
        var hasLaunched = false
        init(transfer: FileTransfer, window: NSWindow?) {
            self.transfer = transfer
            self.window = window
            progress = TransferProgress(completed: 0, total: transfer.sources.count, currentName: nil, phase: .discovering)
        }
    }

    private(set) var jobs: [Job] = []
    var hasActiveJobs: Bool { !jobs.isEmpty || !activities.isEmpty }
    /// While quitting, results go to the journal instead of alerts.
    private(set) var isQuitting = false

    /// Status bar line, e.g. "Copying 3 items · 37% complete".
    var statusLine: (text: String, fraction: Double)? {
        guard let job = jobs.first else { return activities.first.map { ($0.text, $0.fraction) } }
        let p = job.progress
        var parts = [job.transfer.kind == .copy ? L10n.format("Copying %@", StatusText.items(p.total)) : L10n.format("Moving %@", StatusText.items(p.total))]
        if p.phase == .discovering {
            parts.append(L10n.tr("Discovering items…"))
        } else {
            parts.append(L10n.format("%@%% complete", StatusText.number(Int(((p.fraction ?? 0) * 100).rounded(.down)))))
            if job.transfer.isPaused { parts.append(L10n.tr("Paused")) }
        }
        let text = parts.joined(separator: " · ")
        return (jobs.count > 1 ? L10n.format("%@ (+%@ more)", text, StatusText.number(jobs.count - 1)) : text, p.fraction ?? 0)
    }

    // MARK: - Hooks (Features/FileOperations: queue, verification, history)

    /// Called before a job runs (e.g. to set its "copy without properties?" resolver).
    static let prepareJob = Observers<Job>(
        "OperationCenter.prepareJob", "A job exists and hasn't run yet (set resolvers).", signature: "(job)")
    /// Calls `launch` now or later (queue controls). No provider: start at once.
    static let admission = Provided<((Job, _ launch: @escaping () -> Void) -> Void)?>(
        "OperationCenter.admission", "Decides when a job starts (transfer queue).", signature: "(job, launch)", default: nil)
    /// Runs after the transfer, before it is reported (verification). Off the main thread.
    static let afterRun = Provided<(@Sendable (Job, TransferReport) async -> Void)?>(
        "OperationCenter.afterRun", "Runs on the job's task after the transfer, before it is reported (verification).",
        signature: "async (job, report)", default: nil)
    /// Called first in `finish` (history, queue bookkeeping).
    static let jobFinished = Observers<(job: Job, report: TransferReport)>(
        "OperationCenter.jobFinished", "A job ended (history, queue bookkeeping).", signature: "(job, report)")
    /// Cancel pressed for one job (a waiting job is started so it ends at once).
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

    /// Non-transfer work shown in the status bar; stops on Cancel or quit. Touched only on the main queue, like `Job`.
    final class Activity: @unchecked Sendable {
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

    /// Cancels every job, keeping journals for next launch; calls `done` once they stop or after 5 s.
    func cancelAllForQuit(then done: @escaping () -> Void) {
        isQuitting = true
        // Never-started queued jobs: keep their journals so next launch offers them (JobRecovery); don't wait.
        for job in jobs where !job.hasLaunched {
            job.transfer.journal?.abandon()
            jobs.removeAll { $0 === job }
        }
        jobs.forEach {
            $0.transfer.retainsJournalWhenCancelled = true
            $0.transfer.cancel()
        }
        activities.forEach { $0.cancel() }   // what they staged is removed, not left for the next launch
        let deadline = Date().addingTimeInterval(5)
        func wait() {
            if (jobs.isEmpty && activities.isEmpty) || Date() > deadline { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait)
        }
        wait()
    }

    /// Starts a journaled copy/move job (FE-125) with Explorer's dialogs and the progress window.
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
        // Never start a queued job while quitting; its journal is kept for next launch.
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
                case .failed(let why), .copiedButSourceRemains(_, let why), .partial(_, let why): return "• " + L10n.format("%@: %@", result.source.lastPathComponent, why)
                default: return "• \(result.source.lastPathComponent)"
                }
            }
            let more = problems.count > 8 ? "\n" + L10n.format("…and %d more.", problems.count - 8) : ""
            let done = report.committed.count
            NSAlert.show(
                TransferWords.failedTitle(report.kind, count: problems.count),
                (done > 0 ? TransferWords.succeededLine(report.kind, count: done) + "\n\n" : "") + lines.joined(separator: "\n") + more,
                in: job.window)
        }
        completion(report)
    }

    func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    // MARK: - Undo
    // Undo never overwrites: a taken original place or a gone item is skipped and reported (FE-129).

    func registerUndoRename(from current: URL, back oldName: String) {
        let newName = current.lastPathComponent
        undoManager.registerUndo(withTarget: self) { center in
            do {
                let restored = try Renamer.rename(current, to: oldName)
                center.registerUndoRename(from: restored, back: newName)
            } catch {
                center.report(L10n.tr("Couldn't undo the rename."), error.localizedDescription)
            }
        }
        undoManager.setActionName(L10n.tr("Rename"))
    }

    /// `actionName` labels Edit ▸ Undo/Redo for this step and every later round of it, not just the first.
    func registerUndoTrash(_ pairs: [(original: URL, trashed: URL)], actionName: String = L10n.tr("Move to Trash")) {
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
                center.report(L10n.tr("Some items couldn't be put back."),
                              L10n.tr("Their original location is taken or they're no longer in the Trash:\n") + skipped.joined(separator: ", "))
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

    /// Undo moves items back (cross-volume via a move job, see `UndoMoveBack.swift`); Redo moves them again.
    func registerUndoMove(_ pairs: [(source: URL, destination: URL)]) {
        registerMoveStep { pairs.map { MoveBack.Item(from: $0.destination, to: $0.source) } }
        undoManager.setActionName(L10n.tr("Move"))
    }

    func registerUndoNewFolder(_ url: URL) {
        undoManager.registerUndo(withTarget: self) { center in
            guard FileOps.exists(url) else { return }
            guard FileOps.isEffectivelyEmpty(url) else {
                center.report(L10n.format("“%@” isn't empty anymore, so it wasn't removed.", url.lastPathComponent), "")
                return
            }
            if let trashed = try? SystemTrash.trash(url) {
                center.registerUndoTrash([(url, trashed)], actionName: L10n.tr("New Folder"))
            }
        }
        undoManager.setActionName(L10n.tr("New Folder"))
    }

    func report(_ message: String, _ info: String) {
        NSAlert.show(message, info, in: NSApp.keyWindow)
    }
}
