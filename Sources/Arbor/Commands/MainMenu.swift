import AppKit
import ArborCore

/// Built from `CommandRegistry` after features register; only the app menu and window items are fixed.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Arbor"

        let app = NSMenu(title: appName)
        app.addItem(plain(L10n.format("About %@", appName), #selector(AppDelegate.showAbout(_:))))
        app.addItem(.separator())
        // `.mainMenu("Arbor")` commands (Settings…) go into the application menu.
        let appCommands = CommandRegistry.shared.entries(in: .mainMenu(appName))
        appCommands.forEach { app.addItem(CommandDispatcher.shared.menuItem($0.command, context: nil)) }
        if !appCommands.isEmpty { app.addItem(.separator()) }
        app.addItem(plain(L10n.format("Hide %@", appName), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(plain(L10n.tr("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(plain(L10n.tr("Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(plain(L10n.format("Quit %@", appName), #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(parent(appName, app))

        for title in CommandRegistry.shared.mainMenuTitles where title != appName {
            let menu = NSMenu(title: shownTitle(title))
            if title == "Window" {
                menu.addItem(plain(L10n.tr("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
                menu.addItem(plain(L10n.tr("Zoom"), #selector(NSWindow.performZoom(_:))))
                menu.addItem(.separator())
            }
            var lastSection: MenuSection?
            for (command, placement) in CommandRegistry.shared.entries(in: .mainMenu(title)) {
                if let last = lastSection, last != placement.section, menu.numberOfItems > 0 { menu.addItem(.separator()) }
                lastSection = placement.section
                menu.addItem(CommandDispatcher.shared.menuItem(command, context: nil))
            }
            main.addItem(parent(shownTitle(title), menu))
        }
        return main
    }

    /// Menu bar titles double as command slot ids ("File", "Edit"…), so only the shown title is translated.
    static func shownTitle(_ slot: String) -> String {
        switch slot {
        case "File": return L10n.tr("File")
        case "Edit": return L10n.tr("Edit")
        case "View": return L10n.tr("View")
        case "Go": return L10n.tr("Go")
        case "Window": return L10n.tr("Window")
        case "Help": return L10n.tr("Help")
        default: return L10n.tr(slot)
        }
    }

    private static func plain(_ title: String, _ action: Selector, _ key: String = "",
                              _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return item
    }

    private static func parent(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
