import AppKit
import ArborCore

/// Steps for the promisesinterop checks: a real promise from another process, on the system's drag pasteboard (docs/features/promised-files.md).
enum PromiseInteropScripts {
    static func register() {
        #if DEBUG
        // promisesystemhover: the view's drop validation against what the drag pasteboard holds.
        DebugScript.registerStep("promisesystemhover") { _, window in
            guard let window, let details = window.itemView as? DetailsViewController else { result = "no details view"; return 0.1 }
            let operation = details.tableView(details.table, validateDrop: dragInfo(window), proposedRow: -1, proposedDropOperation: .above)
            result = "hover=\(operation.rawValue)"
            return 0.1
        }
        // promisesystemdrop: the view's real drop, followed by the end of the drop.
        DebugScript.registerStep("promisesystemdrop") { _, window in
            guard let window, let details = window.itemView as? DetailsViewController else { result = "no details view"; return 0.1 }
            let info = dragInfo(window)
            let accepted = details.tableView(details.table, acceptDrop: info, row: -1, dropOperation: .above)
            result = "accepted=\(accepted) end=\(accepted && endDrop(info))"
            return 0.1
        }
        // promisesystemoffer:<name>: what starting to drag that visible item puts on the drag pasteboard.
        DebugScript.registerStep("promisesystemoffer") { name, window in
            guard let item = window?.visibleItems.first(where: { $0.name == name }), let writer = ItemHooks.dragWriter(for: item) else {
                result = "no promise for that item"
                return 0.1
            }
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            result = "offered=\(pasteboard.writeObjects([writer]))"
            return 0.1
        }
        // promiseholduntil:/path: keeps the app serving a promise until the other process leaves that file.
        DebugScript.registerWaitStep("promiseholduntil") { path, _, elapsed in
            FileManager.default.fileExists(atPath: path) || elapsed > 60
        }
        DebugScript.registerLogger("promised-files.interop-log") { _ in "promise interop: \(result)" }
        #endif
    }

    #if DEBUG
    private static var result = "none"

    private static func dragInfo(_ window: BrowserWindowController) -> FakeDraggingInfo {
        FakeDraggingInfo(pasteboard: NSPasteboard(name: .drag), window: window.window)
    }

    /// AppKit's own end-of-drop call: only its drag manager can make it, and that takes a real pressed mouse button. Reads only the pasteboard's name.
    private static func endDrop(_ info: NSDraggingInfo) -> Bool {
        let notify = NSSelectorFromString("_notifyFilePromiseTargetsWithDraggingInfo:")
        guard let manager = NSClassFromString("_NSDragManager") as? NSObject.Type,
              let shared = manager.perform(NSSelectorFromString("sharedDragManager"))?.takeUnretainedValue() as? NSObject,
              shared.responds(to: notify) else { return false }
        shared.perform(notify, with: info)
        return true
    }
    #endif
}
