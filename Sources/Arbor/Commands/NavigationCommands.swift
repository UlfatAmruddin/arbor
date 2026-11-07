import AppKit
import ArborCore

/// Back, Forward, Up, Refresh, address/search focus and Go-menu places (FE-001–FE-015).
enum NavigationCommands {
    static func register() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "nav.back", title: "Back", symbol: "arrow.left", shortcut: Shortcut("["),
                keyBindings: [KeyBinding(51), KeyBinding(123, [.option])],   // Delete (Backspace), ⌥←
                placements: [.mainMenu("Go", .navigation, 10)],
                isEnabled: { $0.tab?.history.canGoBack ?? false },
                perform: { $0.window?.goBack() }),
            ExplorerCommand(
                id: "nav.forward", title: "Forward", symbol: "arrow.right", shortcut: Shortcut("]"),
                keyBindings: [KeyBinding(124, [.option])],
                placements: [.mainMenu("Go", .navigation, 20)],
                isEnabled: { $0.tab?.history.canGoForward ?? false },
                perform: { $0.window?.goForward() }),
            ExplorerCommand(
                id: "nav.up", title: "Up", symbol: "arrow.up", shortcut: .function(NSUpArrowFunctionKey, [.command]),
                keyBindings: [KeyBinding(126, [.option])],
                placements: [.mainMenu("Go", .navigation, 30)],
                isEnabled: { $0.location?.parent() != nil },
                perform: { $0.window?.goUp() }),
            ExplorerCommand(
                id: "nav.refresh", title: "Refresh", symbol: "arrow.clockwise", shortcut: Shortcut("r"),
                keyBindings: [KeyBinding(96), KeyBinding(96, scope: .window)],   // F5
                placements: [.mainMenu("View", .properties, 10), .backgroundContextMenu(.view, 30)],
                isEnabled: { $0.window != nil },
                perform: { $0.window?.reload() }),
            ExplorerCommand(
                id: "nav.address", title: "Go to Address…", shortcut: Shortcut("l"),
                keyBindings: [KeyBinding(2, [.option], scope: .window)],          // ⌥D (Alt+D)
                placements: [.mainMenu("Go", .tools, 10)],
                isEnabled: { $0.window != nil },
                perform: { $0.window?.focusAddressBar() }),
            ExplorerCommand(
                id: "nav.search", title: "Search", shortcut: Shortcut("f"),
                keyBindings: [KeyBinding(14, [.command], scope: .window)],        // ⌘E (Ctrl+E)
                placements: [.mainMenu("Edit", .tools, 10)],
                isEnabled: { $0.window != nil },
                perform: { $0.window?.focusSearch() }),
            ExplorerCommand(
                id: "nav.connectToServer", title: "Connect to Server…", shortcut: Shortcut("k"),
                placements: [.mainMenu("Go", .tools, 20)],
                isEnabled: { $0.window != nil },
                perform: { $0.window?.focusAddressBar(text: "smb://") }),
        ])

        let fm = FileManager.default
        func place(_ id: String, _ title: String, _ location: Location?, _ shortcut: Shortcut?, _ order: Double) -> ExplorerCommand {
            ExplorerCommand(id: "go.\(id)", title: title, shortcut: shortcut,
                            placements: [.mainMenu("Go", .places, order)],
                            isAvailable: { _ in location != nil },
                            perform: { ctx in
                                guard let location else { return }
                                if let window = ctx.window { window.navigate(to: location) }
                                else { (NSApp.delegate as? AppDelegate)?.openWindow(at: location) }
                            })
        }
        func folder(_ dir: FileManager.SearchPathDirectory) -> Location? {
            fm.urls(for: dir, in: .userDomainMask).first.map { .folder($0) }
        }
        r.register([
            place("home", "Home", .home, Shortcut("h", [.command, .shift]), 10),
            place("thisMac", "This Mac", .thisMac, Shortcut("c", [.command, .shift]), 15),
            place("desktop", "Desktop", folder(.desktopDirectory), Shortcut("d", [.command, .shift]), 20),
            place("documents", "Documents", folder(.documentDirectory), Shortcut("o", [.command, .shift]), 30),
            place("downloads", "Downloads", folder(.downloadsDirectory), Shortcut("l", [.command, .option]), 40),
            place("userFolder", "Home Folder", .folder(fm.homeDirectoryForCurrentUser), nil, 45),
            place("applications", "Applications", .folder(URL(fileURLWithPath: "/Applications")), Shortcut("a", [.command, .shift]), 50),
            place("network", "Network", .network, Shortcut("k", [.command, .shift]), 60),
            place("trash", "Trash", .trash, nil, 70),
        ])
    }
}

/// Tabs and windows (FE-017–FE-022): ⌘T, ⌘W, ⌘1…⌘9, ⌃Tab, ⇧⌘[ / ⇧⌘], and the tab context menu.
enum TabCommands {
    static func register() {
        let r = CommandRegistry.shared
        func index(_ ctx: CommandContext) -> Int? {
            guard let window = ctx.window else { return nil }
            return ctx.tabIndex ?? window.activeIndex
        }
        r.register([
            ExplorerCommand(
                id: "tab.new", title: "New Tab", symbol: "plus", shortcut: Shortcut("t"),
                placements: [.mainMenu("File", .new, 10), .tabContextMenu(.new, 10)],
                perform: { ctx in
                    if let window = ctx.window { window.openTab(WindowHooks.startLocation()) }
                    else { (NSApp.delegate as? AppDelegate)?.openWindow() }
                }),
            ExplorerCommand(
                id: "window.new", title: "New Window", shortcut: Shortcut("n"),
                placements: [.mainMenu("File", .new, 5)],
                perform: { _ in (NSApp.delegate as? AppDelegate)?.openWindow() }),
            ExplorerCommand(
                id: "tab.duplicate", title: "Duplicate Tab",
                placements: [.tabContextMenu(.new, 20), .mainMenu("Window", .tabs, 30)],
                isEnabled: { $0.window != nil },
                perform: { ctx in if let i = index(ctx) { ctx.window?.duplicateTab(at: i) } }),
            ExplorerCommand(
                id: "tab.close", title: "Close Tab", shortcut: Shortcut("w"),
                placements: [.mainMenu("File", .tabs, 10), .tabContextMenu(.organize, 10)],
                isEnabled: { $0.window != nil || NSApp.keyWindow != nil },
                perform: { ctx in
                    if let window = ctx.window, let i = index(ctx) { window.closeTab(at: i) }
                    else { NSApp.keyWindow?.performClose(nil) }
                }),
            ExplorerCommand(
                id: "tab.closeOthers", title: "Close Other Tabs",
                placements: [.tabContextMenu(.organize, 20)],
                isEnabled: { ($0.window?.tabs.count ?? 0) > 1 },
                perform: { ctx in if let i = index(ctx) { ctx.window?.closeOtherTabs(except: i) } }),
            ExplorerCommand(
                id: "tab.closeRight", title: "Close Tabs to the Right",
                placements: [.tabContextMenu(.organize, 30)],
                isEnabled: { ctx in index(ctx).map { $0 < (ctx.window?.tabs.count ?? 0) - 1 } ?? false },
                perform: { ctx in if let i = index(ctx) { ctx.window?.closeTabs(rightOf: i) } }),
            ExplorerCommand(
                id: "tab.moveToNewWindow", title: "Move Tab to New Window",
                placements: [.tabContextMenu(.window, 10), .mainMenu("Window", .tabs, 40)],
                isEnabled: { ($0.window?.tabs.count ?? 0) > 1 },
                perform: { ctx in if let i = index(ctx) { ctx.window?.moveTabToNewWindow(at: i) } }),
            ExplorerCommand(
                id: "tab.next", title: "Show Next Tab", shortcut: Shortcut("\t", [.control]),
                keyBindings: [KeyBinding(48, [.control], scope: .window), KeyBinding(30, [.command, .shift], scope: .window)],
                placements: [.mainMenu("Window", .tabs, 10)],
                isEnabled: { ($0.window?.tabs.count ?? 0) > 1 },
                perform: { $0.window?.selectNextTab(1) }),
            ExplorerCommand(
                id: "tab.previous", title: "Show Previous Tab", shortcut: Shortcut("\t", [.control, .shift]),
                keyBindings: [KeyBinding(48, [.control, .shift], scope: .window), KeyBinding(33, [.command, .shift], scope: .window)],
                placements: [.mainMenu("Window", .tabs, 20)],
                isEnabled: { ($0.window?.tabs.count ?? 0) > 1 },
                perform: { $0.window?.selectNextTab(-1) }),
        ])
        for n in 1...9 {
            r.register(ExplorerCommand(
                id: n == 9 ? "tab.selectLast" : "tab.select\(n)", title: n == 9 ? "Show Last Tab" : "Show Tab \(n)",
                shortcut: Shortcut("\(n)"),
                placements: [.mainMenu("Window", .window, Double(n))],
                isEnabled: { ctx in n == 9 ? ctx.window != nil : n <= (ctx.window?.tabs.count ?? 0) },
                perform: { ctx in
                    guard let window = ctx.window else { return }
                    window.selectTab(at: n == 9 ? window.tabs.count - 1 : n - 1)
                }))
        }
    }
}
