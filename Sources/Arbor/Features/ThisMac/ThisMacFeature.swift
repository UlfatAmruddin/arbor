import AppKit
import ArborCore

/// This Mac page (FE-074) and the drives under "This Mac" in the navigation pane.
enum ThisMacFeature: ExplorerFeature {
    static let id = "this-mac"
    private static var observers: [NSObjectProtocol] = []

    static func register() {
        LocationRegistry.register(ThisMacPageProvider())
        NavigationPaneController.volumeNodes.provide("this-mac.drives") { VolumeCatalog.navigationNodes() }
        observers.append(NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            guard note.userInfo?["key"] as? String == HomePrefKeys.hideEmptyDrives else { return }
            for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] {
                controller.navPane.rebuild()
                controller.navPane.reveal(controller.location)
            }
        })
        registerDebugSteps()
    }

    static func page(_ window: BrowserWindowController?) -> ThisMacPage? {
        guard let tab = window?.activeTab, tab.showsPage else { return nil }
        return tab.page as? ThisMacPage
    }

    private static func registerDebugSteps() {
        // macselect:Macintosh HD|Backup
        DebugScript.registerStep("macselect") { arg, window in
            page(window)?.select(names: arg.components(separatedBy: "|"))
            return 0.4
        }
        // macmenu:/out.txt — the context menu for the selected drive.
        DebugScript.registerStep("macmenu") { arg, window in
            guard let page = page(window) else { return 0.3 }
            PageDebug.appendMenu("this mac menu", page.contextMenu(sender: page.activeGrid), to: arg)
            return 0.3
        }
        // hideemptydrives:on|off
        DebugScript.registerStep("hideemptydrives") { arg, _ in
            Prefs.hideEmptyDrives = arg != "off"
            return 0.8
        }
        DebugScript.registerLogger("this-mac.log") { window in page(window)?.debugSummary ?? "thismac: (not shown)" }
    }
}
