import AppKit
import ArborCore

/// History (FE-126), queue (FE-127), verify (FE-130), property-loss prompt, Compress options (FE-168),
/// ACL editing and Time Machine versions (FE-153, FE-155). See docs/features/file-operations.md.
enum FileOperationsExtras: ExplorerFeature {
    static let id = "file-operations-extras"
    /// Extends the archives command and the Properties tabs.
    static let requires = ["file-operations", "archives", "properties"]
    static func register() {
        TransferQueueController.shared.install()
        JobVerification.install()
        MetadataLossDialog.install()
        OperationCenter.jobFinished.observe("file-operations-extras.history-and-queue") { job, report in
            TransferQueueController.shared.jobFinished(job)
            if !OperationCenter.shared.isQuitting {
                var record = OperationRecord(report: report, id: job.id, started: job.created)
                record.verification = JobVerification.historyEntry(job)
                OperationHistory.shared.add(record)
            }
            JobVerification.report(job)
        }
        OperationCenter.jobCancelled.observe("file-operations-extras.queue") { TransferQueueController.shared.jobCancelled($0) }
        registerCommands()
        CompressOptionsDialog.register()
        registerScriptSteps()
    }

    private static func registerCommands() {
        let section = FileOperationsFeature.operationsSection
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "fileops.history", title: "Operation history", symbol: "clock.arrow.circlepath",
                placements: [.seeMore(section, 10), .mainMenu("Window", section, 20)],
                dynamicTitle: { $0.surface == .menuBar ? L10n.tr("Operation History") : L10n.tr("Operation history") },
                perform: { _ in OperationHistoryWindow.shared.show() }),
            ExplorerCommand(
                id: "fileops.queueOptions", title: "Transfer Queue",
                placements: [.mainMenu("Window", section, 30)],
                submenu: { _ in QueueOptionsMenu.items() }),
        ])
    }

    // MARK: - Scripted checks (headless)

    private static func job(_ text: String) -> OperationCenter.Job? {
        guard let n = Int(text), n >= 1, n <= OperationCenter.shared.jobs.count else { return nil }
        return OperationCenter.shared.jobs[n - 1]
    }

    private static func registerScriptSteps() {
        /// opqueue:samedrive=on|off, limit=N, verifydefault=on|off
        DebugScript.registerStep("opqueue") { argument, _ in
            for part in argument.split(separator: ",") {
                let kv = part.split(separator: "=").map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "samedrive": Prefs.fileOpsQueueSameDrive = kv[1] == "on"
                case "limit": Prefs.fileOpsConcurrencyLimit = Int(kv[1]) ?? 0
                case "verifydefault": Prefs.fileOpsVerifyByDefault = kv[1] == "on"
                default: break
                }
            }
            return 0.3
        }
        /// opjob:N:startnow|up|down|defer|undefer|verify=on|verify=off|cancel|pause|resume (N is 1-based)
        DebugScript.registerStep("opjob") { argument, _ in
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let job = job(parts[0]) else { NSLog("DebugScript: no job \(argument)"); return 0.3 }
            let queue = TransferQueueController.shared
            switch parts[1] {
            case "startnow": queue.startNow(job)
            case "up": queue.move(job, by: -1)
            case "down": queue.move(job, by: 1)
            case "defer": queue.setDeferred(job, true)
            case "undefer": queue.setDeferred(job, false)
            case "verify=on": JobVerification.setRequested(job, true)
            case "verify=off": JobVerification.setRequested(job, false)
            case "cancel": OperationCenter.shared.cancel(job)
            case "pause": job.transfer.pause()
            case "resume": job.transfer.resume()
            default: NSLog("DebugScript: unknown opjob action \(parts[1])")
            }
            OperationCenter.shared.post()
            return 0.5
        }
        DebugScript.registerStep("ophistory") { _, _ in
            OperationHistoryWindow.shared.show()
            return 0.6
        }
        DebugScript.registerStep("histexpand") { _, _ in
            OperationHistoryWindow.shared.expandAll()
            return 0.3
        }
        DebugScript.registerStep("histselect") { argument, _ in
            OperationHistoryWindow.shared.select(row: Int(argument) ?? 0)
            return 0.5
        }
        DebugScript.registerStep("histbutton") { argument, _ in
            if !OperationHistoryWindow.shared.scriptClick(argument) { NSLog("DebugScript: no history button \(argument)") }
            return 0.8
        }
        DebugScript.registerStep("histsnap") { argument, _ in
            FileOperationsFeature.snapshot(OperationHistoryWindow.shared.snapshotWindow, to: argument)
            return 0.3
        }
        /// aclset:kind=group,name=staff,verdict=deny,level=modify,inherit=on,select=0,group=staff (Permissions editor)
        DebugScript.registerStep("aclset") { argument, _ in
            PermissionsEditorSheet.scriptSet(argument)
            return 0.4
        }
        /// tmselect:N — selects a Previous Versions entry.
        DebugScript.registerStep("tmselect") { argument, _ in
            TimeMachineVersionsView.latest?.scriptSelect(Int(argument) ?? 0)
            return 0.3
        }
        /// tmbutton:open|restore — the Time Machine list's Open / Restore… buttons.
        DebugScript.registerStep("tmbutton") { argument, _ in
            TimeMachineVersionsView.latest?.scriptPress(argument)
            return 0.6
        }
        DebugScript.registerLogger("file-operations-extras.log") { _ in
            let compress: String
            switch CompressOptionsDialog.lastResult {
            case .success(let path)?: compress = "created \(path)"
            case .failure(let error)?: compress = "failed: \(error.localizedDescription)"
            case nil: compress = "-"
            }
            return L10n.format("%@ | last archive: %@\n", "\(CompressOptionsDialog.current?.debugText ?? "compress options: none")", "\(compress)") +
                PermissionsEditorSheet.debugText
        }
        DebugScript.registerLogger("file-operations-extras.log-2") { _ in
            let latest = OperationHistory.shared.records.first.map { "\(OperationHistoryWindow.title($0)) → \($0.destination) | \(OperationHistoryWindow.result($0))" } ?? "-"
            return "\(TransferQueueController.shared.scriptDescription)\n" +
                "history: \(OperationHistory.shared.records.count) records; latest: \(latest)\n" +
                (OperationHistoryWindow.shared.isVisible ? OperationHistoryWindow.shared.scriptDescription + "\n" : "") +
                "verification alert: \(JobVerification.lastAlert?.replacingOccurrences(of: "\n", with: " / ") ?? "-")"
        }
    }
}
