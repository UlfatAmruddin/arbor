import AppKit
import ArborCore

extension MenuSection {
    static let workspaces = MenuSection(rank: 940, name: "workspaces")
}

/// Named tab sets (FE-027), an Arbor addition: File Explorer has none. See docs/features/workspaces.md.
enum WorkspacesFeature: ExplorerFeature {
    static let id = "workspaces"

    static let store = WorkspaceStore(fileURL: FolderOptionsStorage.url("Workspaces.json"), queue: FolderOptionsStorage.writeQueue)

    static func register() {
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "workspaces.menu", title: "Workspaces", symbol: "square.stack",
                placements: [.seeMore(.workspaces, 10), .mainMenu("Window", .workspaces, 10)],
                submenu: WorkspaceMenu.items),
            ExplorerCommand(
                id: "workspaces.save", title: "Save current tabs as workspace…",
                isEnabled: { ctx in ctx.window != nil && store.canEdit },
                perform: { ctx in if let window = ctx.window { WorkspacePrompts.save(from: window) } }),
        ])
        WindowHooks.didCreate.observe("workspaces.load") { _ in store.loadIfNeeded() }
        store.onWriteFailure = WorkspacePrompts.showWriteFailure
        // Saves are queued; scripted runs end with exit().
        atexit { WorkspacesFeature.store.flush() }
        WorkspaceScriptSteps.register()
    }
}
