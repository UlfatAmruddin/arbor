import AppKit
import ArborCore

/// The sheets for saving, renaming and deleting. Names are only ever `%@` arguments.
enum WorkspacePrompts {
    private static var store: WorkspaceStore { WorkspacesFeature.store }

    // MARK: Save

    static func save(from window: BrowserWindowController) {
        guard let host = window.window, host.attachedSheet == nil else { NSSound.beep(); return }
        let prompt = namePrompt(title: L10n.tr("Save current tabs as workspace"),
                                message: L10n.tr("A workspace remembers this window's tabs. Your files and folders aren't changed."),
                                action: L10n.tr("Save"), initial: window.activeTab.title)
        AlertSheets.present(prompt.alert, in: host) { [weak window] response in
            guard response == .alertFirstButtonReturn, let window else { return }
            confirmSave(named: prompt.field.stringValue, from: window)
        }
    }

    /// A same-named workspace asks first: saving over it is how a workspace is updated.
    private static func confirmSave(named typed: String, from window: BrowserWindowController) {
        guard let name = WorkspaceName.clean(typed) else {
            show(.invalidName, name: typed, in: window.window)
            return
        }
        guard let existing = store.list.workspace(named: name) else {
            commitSave(named: name, from: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("Replace the workspace “%@”?", existing.name)
        alert.informativeText = L10n.tr("It will hold this window's tabs instead of the ones saved before.")
        alert.addButton(withTitle: L10n.tr("Replace"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        AlertSheets.present(alert, in: window.window) { [weak window] response in
            guard response == .alertFirstButtonReturn, let window else { return }
            commitSave(named: name, from: window)
        }
    }

    private static func commitSave(named name: String, from window: BrowserWindowController) {
        let tabs = window.tabs.map(\.sessionTab)
        switch store.save(name: name, tabs: tabs, activeTab: window.activeIndex) {
        case .success(let saved):
            window.statusBar.setMessage(savedMessage(saved, leftOut: tabs.count - saved.tabs.count))
        case .failure(let error):
            show(error, name: name, in: window.window)
        }
    }

    private static func savedMessage(_ saved: Workspace, leftOut: Int) -> String {
        if leftOut > 0 {
            return L10n.plural(one: "Saved “%2$@”. %1$lld tab was left out: workspaces hold up to %3$d tabs and can't store very long addresses.",
                               other: "Saved “%2$@”. %1$lld tabs were left out: workspaces hold up to %3$d tabs and can't store very long addresses.",
                               leftOut, saved.name, SessionState.tabLimit)
        }
        return L10n.format("Saved “%@”.", saved.name)
    }

    // MARK: Rename and delete

    static func rename(_ id: String, in host: NSWindow?) {
        guard let workspace = store.list.workspace(id: id) else { NSSound.beep(); return }
        let prompt = namePrompt(title: L10n.tr("Rename workspace"), message: L10n.format("Enter a new name for “%@”.", workspace.name),
                                action: L10n.tr("Rename"), initial: workspace.name)
        AlertSheets.present(prompt.alert, in: host) { [weak host] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = prompt.field.stringValue
            if case .failure(let error) = store.rename(id: id, to: name) { show(error, name: name, in: host) }
        }
    }

    static func delete(_ id: String, in host: NSWindow?) {
        guard let workspace = store.list.workspace(id: id) else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L10n.format("Delete the workspace “%@”?", workspace.name)
        alert.informativeText = L10n.tr("Only the saved list of tabs is removed. No files or folders are affected.")
        alert.addButton(withTitle: L10n.tr("Delete"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        AlertSheets.present(alert, in: host) { [weak host] response in
            guard response == .alertFirstButtonReturn else { return }
            if case .failure(let error) = store.delete(id: id) { show(error, name: workspace.name, in: host) }
        }
    }

    // MARK: Problems

    static func showWriteFailure() {
        inform(title: L10n.tr("Arbor couldn't save your workspaces"),
               message: L10n.tr("The change is kept until you quit, and Arbor will try again with your next change."), in: nil)
    }

    /// Every message of this feature that only needs an OK.
    static func inform(title: String, message: String = "", in host: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.tr("OK"))
        AlertSheets.present(alert, in: host)
    }

    private static func show(_ error: WorkspaceEditError, name: String, in host: NSWindow?) {
        inform(title: message(for: error, name: name), in: host)
    }

    private static func message(for error: WorkspaceEditError, name: String) -> String {
        switch error {
        case .invalidName: return L10n.tr("Enter a name with at least one visible character.")
        case .duplicateName: return L10n.format("A workspace named “%@” already exists.", name)
        case .notFound: return L10n.tr("That workspace no longer exists.")
        case .limitReached: return L10n.format("Arbor keeps up to %d workspaces. Delete one to save another.", WorkspaceList.limit)
        case .noStorableTabs: return L10n.tr("None of the tabs in this window can be saved: their addresses are too long.")
        case .tooLarge: return L10n.tr("There's no room for this change. Delete a workspace, or save one with fewer tabs.")
        case .readOnly: return store.issue.map(WorkspaceMenu.notice(for:)) ?? L10n.tr("Workspaces can't be changed right now.")
        }
    }

    private static func namePrompt(title: String, message: String, action: String, initial: String) -> (alert: NSAlert, field: NSTextField) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: WorkspaceName.clean(initial) ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.placeholderString = L10n.tr("Workspace name")
        field.setAccessibilityLabel(L10n.tr("Workspace name"))
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.window.initialFirstResponder = field
        return (alert, field)
    }
}
