import AppKit
import ArborCore

/// Copy/move/delete dialogs, the progress window, the job journal review and Undo Copy
/// (FE-114–FE-130, FE-241, FE-250, FE-255, FE-257). See docs/features/file-operations.md.
enum FileOperationsFeature: ExplorerFeature {
    static let id = "file-operations"
    static let operationsSection = MenuSection(rank: 950, name: "fileOperations")

    static func register() {
        DeleteCommands.register()
        CommandRegistry.shared.register(ExplorerCommand(
            id: "window.fileOperations", title: "Show File Operations",
            placements: [.mainMenu("Window", operationsSection, 10)],
            isEnabled: { _ in OperationCenter.shared.hasActiveJobs },
            perform: { _ in OperationsWindow.shared.show() }))
        registerScriptSteps()
        JobRecovery.checkSoon()
    }

    // MARK: - Scripted checks (headless)

    private static func registerScriptSteps() {
        /// opsnap:progress|dialog|sheet:/path.png — draws that window into a PNG.
        DebugScript.registerStep("opsnap") { argument, browser in
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return 0.3 }
            let window: NSWindow?
            switch parts[0] {
            case "progress": window = OperationsWindow.shared.snapshotWindow
            case "dialog": window = FileOpsDialog.open.last?.panel
            case "sheet": window = browser?.window?.attachedSheet
            default: window = nil
            }
            snapshot(window, to: parts[1])
            return 0.3
        }
        DebugScript.registerStep("opdetails") { argument, _ in
            OperationsWindow.shared.expanded = argument != "off"
            return 0.5
        }
        DebugScript.registerStep("opshow") { _, _ in
            OperationsWindow.shared.show()
            return 0.5
        }
        DebugScript.registerStep("oppause") { _, _ in
            OperationCenter.shared.jobs.forEach { $0.transfer.pause() }
            return 0.5
        }
        DebugScript.registerStep("opresume") { _, _ in
            OperationCenter.shared.jobs.forEach { $0.transfer.resume() }
            return 0.5
        }
        DebugScript.registerStep("opcancel") { _, _ in
            OperationCenter.shared.jobs.forEach { OperationCenter.shared.cancel($0) }
            return 0.5
        }
        /// opbutton:Title — clicks a button or check box in the newest file-operation dialog.
        DebugScript.registerStep("opbutton") { argument, _ in
            if !FileOpsDialog.scriptClick(argument) { NSLog("DebugScript: no file-operation dialog button \(argument)") }
            return 0.6
        }
        /// opcompare:source|existing|both|skipsame — ticks boxes in the compare dialog.
        DebugScript.registerStep("opcompare") { argument, _ in
            (FileOpsDialog.open.last as? CompareDialog)?.scriptChoose(argument)
            return 0.4
        }
        /// opprefs:deleteconfirm=on|off, mergeprompt=on|off
        DebugScript.registerStep("opprefs") { argument, _ in
            let parts = argument.split(separator: "=").map(String.init)
            guard parts.count == 2 else { return 0.2 }
            let on = parts[1] == "on"
            switch parts[0] {
            case "deleteconfirm": Prefs.displayDeleteConfirmation = on
            case "mergeprompt": Prefs.hideFolderMergeConflicts = !on
            default: break
            }
            return 0.2
        }
        /// opstart:copy|move:/src/a|/src/b:/dest — starts a job without the clipboard.
        DebugScript.registerStep("opstart") { argument, browser in
            let parts = argument.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let kind = TransferKind(rawValue: parts[0]) else { return 0.3 }
            let sources = parts[1].split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            browser?.startTransfer(kind, sources, to: URL(fileURLWithPath: parts[2]))
            return 0.5
        }
        DebugScript.registerStep("recovery") { _, _ in
            JobRecovery.check()
            return 1.0
        }
        DebugScript.registerLogger("file-operations.log") { _ in
            let jobs = OperationCenter.shared.jobs.map { job -> String in
                let p = job.progress
                return "\(job.transfer.kind.rawValue) phase=\(p.phase.rawValue) paused=\(job.transfer.isPaused) " +
                    "items=\(p.itemsDone)/\(p.itemsTotal.map(String.init) ?? "?") bytes=\(p.bytesDone)/\(p.bytesTotal.map(String.init) ?? "?")"
            }
            let dialogs = FileOpsDialog.open.map(\.panel.title)
            return "operations: \(jobs.isEmpty ? "none" : jobs.joined(separator: "; "))\n" +
                "operations window: \(OperationsWindow.shared.scriptDescription)\n" +
                "file-op dialogs: \(dialogs.isEmpty ? "none" : dialogs.joined(separator: " | "))\n" +
                "undo action: \(OperationCenter.shared.undoManager.canUndo ? OperationCenter.shared.undoManager.undoActionName : "-")"
        }
    }

    static func snapshot(_ window: NSWindow?, to path: String) {
        guard let frameView = window?.contentView?.superview else {
            NSLog("DebugScript: no window to snapshot for \(path)")
            return
        }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
