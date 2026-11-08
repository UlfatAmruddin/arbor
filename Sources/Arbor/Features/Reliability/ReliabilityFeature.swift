import AppKit
import ArborCore

/// Script steps for `scripts/behavior-checks.sh` (docs/features/qa-core.md): undo/redo names,
/// logged-only requests, the alert queue, quitting with queued jobs.
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
        // terminate — quits like "Quit Anyway" (journals kept for next launch), then exits.
        DebugScript.registerStep("terminate") { _, _ in
            OperationCenter.shared.cancelAllForQuit {
                Prefs.discardHeadlessStore()
                exit(0)
            }
            return 30
        }
    }
}
