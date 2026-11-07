import AppKit
import ArborCore

/// The menu bar, built from `CommandRegistry` (`.mainMenu("File")` etc.) after features register.
/// Only the application menu and the standard window items are fixed here (AppKit adds Enter Full Screen).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Arbor"

        let app = NSMenu(title: appName)
        app.addItem(plain("About \(appName)", #selector(AppDelegate.showAbout(_:))))
        app.addItem(.separator())
        // Commands placed in `.mainMenu("Arbor")` (Settings… ⌘,) go into the application menu.
        let appCommands = CommandRegistry.shared.entries(in: .mainMenu(appName))
        appCommands.forEach { app.addItem(CommandDispatcher.shared.menuItem($0.command, context: nil)) }
        if !appCommands.isEmpty { app.addItem(.separator()) }
        app.addItem(plain("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(plain("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(plain("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(plain("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(parent(appName, app))

        for title in CommandRegistry.shared.mainMenuTitles where title != appName {
            let menu = NSMenu(title: title)
            if title == "Window" {
                menu.addItem(plain("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
                menu.addItem(plain("Zoom", #selector(NSWindow.performZoom(_:))))
                menu.addItem(.separator())
            }
            var lastSection: MenuSection?
            for (command, placement) in CommandRegistry.shared.entries(in: .mainMenu(title)) {
                if let last = lastSection, last != placement.section, menu.numberOfItems > 0 { menu.addItem(.separator()) }
                lastSection = placement.section
                menu.addItem(CommandDispatcher.shared.menuItem(command, context: nil))
            }
            main.addItem(parent(title, menu))
        }
        return main
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
