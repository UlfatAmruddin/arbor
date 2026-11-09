import AppKit
import ArborCore

/// The Workspaces submenu, built each time it opens.
enum WorkspaceMenu {
    private static var store: WorkspaceStore { WorkspacesFeature.store }

    static func items(_ ctx: CommandContext) -> [NSMenuItem] {
        var items = [disabledRow(L10n.tr("Arbor addition, not part of File Explorer"))]
        if let issue = store.issue { items.append(disabledRow(notice(for: issue))) }
        if let save = CommandRegistry.shared.command("workspaces.save") {
            items.append(CommandDispatcher.shared.menuItem(save, context: ctx))
        }
        if store.isLoaded {
            items.append(.separator())
            items += store.list.workspaces.map { row(for: $0, window: ctx.window) }
            if store.list.workspaces.isEmpty { items.append(disabledRow(L10n.tr("No saved workspaces"))) }
        }
        return items
    }

    static func notice(for issue: WorkspaceLoad.Issue) -> String {
        switch issue {
        case .damaged(copyKept: true):
            return L10n.format("The saved workspaces were damaged. The file was kept as %@.", WorkspaceFile.damagedCopyName)
        case .damaged(copyKept: false):
            return L10n.tr("The saved workspaces are damaged and couldn't be set aside. Workspaces are read-only.")
        case .partial(1, copyKept: true):
            return L10n.format("1 saved entry couldn't be read. A copy of the file was kept as %@.", WorkspaceFile.damagedCopyName)
        case .partial(let skipped, copyKept: true):
            return L10n.format("%d saved entries couldn't be read. A copy of the file was kept as %@.", skipped, WorkspaceFile.damagedCopyName)
        case .partial(_, copyKept: false):
            return L10n.tr("Some saved entries couldn't be read and no copy could be made. Workspaces are read-only.")
        case .newerVersion:
            return L10n.tr("Saved by a newer version of Arbor. Workspaces are read-only.")
        case .unreadable:
            return L10n.tr("The workspaces file can't be read. Workspaces are read-only.")
        }
    }

    private static func disabledRow(_ title: String) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        return row
    }

    private static func row(for workspace: Workspace, window: BrowserWindowController?) -> NSMenuItem {
        let row = NSMenuItem(title: workspace.name, action: nil, keyEquivalent: "")
        row.toolTip = workspace.tabs.count == 1 ? L10n.tr("1 tab") : L10n.format("%d tabs", workspace.tabs.count)
        let menu = NSMenu(title: workspace.name)
        // ClosureMenuItem is its own target, so automatic validation would re-enable disabled rows.
        menu.autoenablesItems = false
        actions(for: workspace.id, window: window).forEach(menu.addItem)
        row.submenu = menu
        return row
    }

    private static func actions(for id: String, window: BrowserWindowController?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let window {
            let replace = ClosureMenuItem(L10n.tr("Replace tabs in this window")) { [weak window] in
                if let window { WorkspaceOpener.shared.open(id, replacing: window) } else { NSSound.beep() }
            }
            replace.isEnabled = window.window?.attachedSheet == nil
            items.append(replace)
        }
        items.append(ClosureMenuItem(L10n.tr("Open in new window")) { WorkspaceOpener.shared.open(id) })
        items.append(.separator())
        let host = window?.window
        let rename = ClosureMenuItem(L10n.tr("Rename…")) { [weak host] in WorkspacePrompts.rename(id, in: host) }
        let delete = ClosureMenuItem(L10n.tr("Delete…")) { [weak host] in WorkspacePrompts.delete(id, in: host) }
        rename.isEnabled = store.canEdit
        delete.isEnabled = store.canEdit
        return items + [rename, delete]
    }
}
