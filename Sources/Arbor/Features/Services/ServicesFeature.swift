import AppKit
import ArborCore

/// macOS Services (FE-218, docs/features/qa-core.md): AppKit builds and runs the menus; Arbor never lists or performs a service.
enum ServicesFeature: ExplorerFeature {
    static let id = "services"

    static func register() {
        NSApp.registerServicesMenuSendTypes([.fileURL], returnTypes: [])
        // Headless runs stay off the system's service registry.
        if !AppDelegate.isHeadless { NSApp.servicesProvider = ServicesProvider.shared }
        // Every context menu reaches the window as requestor, but only the item menu is about the selected files.
        CommandDispatcher.menuBuilt.observe("services.item-menus-only") { slot, menu in
            menu.allowsContextMenuPlugIns = slot == .itemContextMenu
        }
        ServicesDebug.register()
    }
}
