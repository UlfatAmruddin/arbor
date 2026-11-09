import AppKit
import ArborCore

/// Headless checks: named steps through the store and opener, without the sheets (TESTING.md).
enum WorkspaceScriptSteps {
    private static var store: WorkspaceStore { WorkspacesFeature.store }
    private static var lastError: WorkspaceEditError?

    static func register() {
        // workspace:save|replace|open|delete|deletesheet|renamesheet:<name>, workspace:rename:<old>=<new>, workspace:typename:<text>
        DebugScript.registerStep("workspace") { argument, window in
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return 0.2 }
            perform(parts[0], parts[1], window: window)
            return 0.2
        }
        DebugScript.registerWaitStep("workspacesready") { _, _, _ in store.isLoaded && !WorkspaceOpener.shared.check.isRunning }
        DebugScript.registerLogger("workspaces.log") { _ in
            let entries = store.list.workspaces.map { "\($0.name)[\($0.activeTab)/\($0.tabs.map(\.location).joined(separator: "|"))]" }
            let notice = store.issue.map(WorkspaceMenu.notice(for:)) ?? "-"
            return "workspaces: loaded=\(store.isLoaded) readonly=\(store.isReadOnly) error=\(lastError.map { "\($0)" } ?? "-") notice=\(notice) list=\(entries.joined(separator: " , "))"
        }
    }

    private static func perform(_ verb: String, _ argument: String, window: BrowserWindowController?) {
        let named = store.list.workspace(named: argument)
        switch verb {
        case "save":
            guard let window else { return }
            record(store.save(name: argument, tabs: window.tabs.map(\.sessionTab), activeTab: window.activeIndex))
        case "replace":
            if let named, let window { WorkspaceOpener.shared.open(named.id, replacing: window) }
        case "open":
            if let named { WorkspaceOpener.shared.open(named.id) }
        case "delete":
            if let named { record(store.delete(id: named.id)) }
        case "deletesheet":
            if let named { WorkspacePrompts.delete(named.id, in: window?.window) }
        case "renamesheet":
            if let named { WorkspacePrompts.rename(named.id, in: window?.window) }
        case "typename":
            // Sets the field directly: headless runs may leave the sheet without a key window, so `type:` can't reach it.
            nameField(in: window?.window?.attachedSheet?.contentView)?.stringValue = argument
        case "rename":
            let names = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if names.count == 2, let target = store.list.workspace(named: names[0]) { record(store.rename(id: target.id, to: names[1])) }
        default:
            NSLog("DebugScript: unknown workspace action \(verb)")
        }
    }

    private static func nameField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(nameField(in:)).first
    }

    private static func record(_ result: Result<Workspace, WorkspaceEditError>) {
        if case .failure(let error) = result { lastError = error } else { lastError = nil }
    }
}
