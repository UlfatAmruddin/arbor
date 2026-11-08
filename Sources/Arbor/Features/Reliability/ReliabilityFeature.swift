import AppKit
import ArborCore

/// Script support for the behavior and safety checks in `scripts/behavior-checks.sh`
/// (docs/features/qa-core.md): undo/redo names, requests that headless runs only log, the alert queue,
/// and quitting with queued jobs.
enum ReliabilityFeature: ExplorerFeature {
    static let id = "reliability"
    static func register() {
        DebugScript.registerLogger("reliability.log") { window in
            let undo = OperationCenter.shared.undoManager
            let requests = SystemOpen.requests
            return "redo action: \(undo.canRedo ? undo.redoActionName : "-")\n"
                + "system open: \(requests.isEmpty ? "none" : requests.joined(separator: " | "))\n"
                + "alerts waiting: \(AlertSheets.waitingCount(in: window.window))"
        }
        // terminate — quits the way "Quit Anyway" does while jobs run (journals kept for the next launch), then exits.
        DebugScript.registerStep("terminate") { _, _ in
            OperationCenter.shared.cancelAllForQuit {
                Prefs.discardHeadlessStore()
                exit(0)
            }
            return 30
        }
    }
}
