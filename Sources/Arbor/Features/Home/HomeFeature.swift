import AppKit
import ArborCore

/// Home (FE-069–FE-072, FE-080, FE-082, FE-206, FE-239); see docs/features/home-and-this-mac.md.
enum HomeFeature: ExplorerFeature {
    static let id = "home"
    private static var observers: [NSObjectProtocol] = []
    static let privacySection = MenuSection(rank: 880, name: "homePrivacy")

    static func register() {
        LocationRegistry.register(ExplorerHomeProvider())
        registerCommands()
        observeActivity()
        registerDebugSteps()
    }

    /// Section the context menu was opened from.
    static func section(_ ctx: CommandContext) -> HomeSection? {
        guard ctx.location == .home, let id = (ctx.sender as? SectionTagged)?.sectionID else { return nil }
        return HomeSection(rawValue: id)
    }

    private static func files(_ ctx: CommandContext) -> [FileItem] {
        ctx.selection.filter { !$0.isFolder }
    }

    // MARK: Commands

    private static func registerCommands() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "home.openFileLocation", title: "Open file location", symbol: "folder",
                placements: [.itemContextMenu(.open, 35)],
                isAvailable: { ctx in ctx.location == .home && ctx.single.map { !$0.isFolder } == true },
                perform: { ctx in
                    guard let file = ctx.single else { return }
                    ctx.window?.navigate(to: .folder(file.url.deletingLastPathComponent()), select: [file.url.lastPathComponent])
                }),
            ExplorerCommand(
                id: "home.favorite", title: "Add to Favorites", symbol: "star",
                placements: [.itemContextMenu(.pin, 20)],
                dynamicTitle: { ctx in
                    let list = files(ctx)
                    return !list.isEmpty && list.allSatisfy { HomeStore.isFavorite($0.url) } ? L10n.tr("Remove from Favorites") : L10n.tr("Add to Favorites")
                },
                isAvailable: { ctx in ctx.hasSelection && files(ctx).count == ctx.selection.count },
                perform: { ctx in
                    let urls = files(ctx).map(\.url)
                    if urls.allSatisfy(HomeStore.isFavorite) {
                        HomeStore.removeFavorites(urls)
                        ctx.window?.statusBar.setMessage(L10n.tr("Removed from Favorites. The file itself wasn't changed."))
                    } else {
                        HomeStore.addFavorites(urls)
                        ctx.window?.statusBar.setMessage(urls.count == 1 ? L10n.tr("Added to Favorites.") : L10n.format("%@ files added to Favorites.", "\(urls.count)"))
                    }
                }),
            ExplorerCommand(
                id: "home.removeFromRecent", title: "Remove from Recent", symbol: "clock.badge.xmark",
                placements: [.itemContextMenu(.pin, 30)],
                isAvailable: { ctx in section(ctx) == .recent && ctx.hasSelection },
                perform: { ctx in
                    // Changes history only (FE-239): the file stays where it is.
                    HomeStore.removeFromRecent(ctx.selection.map(\.url))
                    ctx.window?.statusBar.setMessage(L10n.tr("Removed from Recent. The file itself wasn't changed."))
                }),
            ExplorerCommand(
                id: "home.removeFrequent", title: "Remove from Quick access", symbol: "pin.slash",
                placements: [.itemContextMenu(.pin, 15)],
                isAvailable: { ctx in
                    guard section(ctx) == .quickAccess, let folder = ctx.single, folder.isFolder else { return false }
                    return !QuickAccess.isPinned(folder.url)
                },
                perform: { ctx in if let url = ctx.single?.url { HomeStore.forgetFrequentFolder(url) } }),

            // Home's "…" menu: Explorer's Folder Options › General privacy switches.
            ExplorerCommand(
                id: "home.showRecentFiles", title: "Show recently used files",
                placements: [.seeMore(privacySection, 10)],
                isAvailable: { $0.location == .home },
                state: { _ in Prefs.showRecentFiles ? .on : .off },
                perform: { _ in Prefs.showRecentFiles.toggle() }),
            ExplorerCommand(
                id: "home.showFrequentFolders", title: "Show frequently used folders",
                placements: [.seeMore(privacySection, 20)],
                isAvailable: { $0.location == .home },
                state: { _ in Prefs.showFrequentFolders ? .on : .off },
                perform: { _ in Prefs.showFrequentFolders.toggle() }),
            ExplorerCommand(
                id: "home.clearHistory", title: "Clear Arbor history", symbol: "clock.arrow.circlepath",
                tooltip: "Clears Recent, frequently used folders, recent searches, recent locations, recent documents, operation history and Back/Forward. Pins, favorites and files are kept.",
                placements: [.seeMore(privacySection, 30)],
                isAvailable: { $0.location == .home },
                perform: { ctx in
                    HomeStore.clearHistory()
                    ctx.window?.statusBar.setMessage(L10n.tr("History cleared. Pinned folders, favorites and files weren't changed."))
                }),
        ])
    }

    // MARK: Recording

    private static func observeActivity() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: LocationEvents.didVisit, object: nil, queue: .main) { note in
            if let location = note.userInfo?["location"] as? Location { HomeStore.recordVisit(location) }
        })
        observers.append(nc.addObserver(forName: LocationEvents.didOpenFiles, object: nil, queue: .main) { note in
            if let urls = note.userInfo?["urls"] as? [URL] { HomeStore.recordOpened(urls) }
        })
        observers.append(nc.addObserver(forName: QuickAccess.changed, object: nil, queue: .main) { _ in
            HomeStore.syncPinReferences()
        })
        DispatchQueue.main.async { HomeStore.syncPinReferences() }
    }

    // MARK: Scripted checks (TESTING.md)

    static func homePage(_ window: BrowserWindowController?) -> ExplorerHomePage? {
        guard let tab = window?.activeTab, tab.showsPage else { return nil }
        return tab.page as? ExplorerHomePage
    }

    private static func registerDebugSteps() {
        // homerecord:/path|/path2 — record files as opened (no app is launched).
        DebugScript.registerStep("homerecord") { arg, _ in
            HomeStore.recordOpened(arg.components(separatedBy: "|").map { URL(fileURLWithPath: $0) })
            return 0.6
        }
        // homefav:/path|… — add files to Favorites.
        DebugScript.registerStep("homefav") { arg, _ in
            HomeStore.addFavorites(arg.components(separatedBy: "|").map { URL(fileURLWithPath: $0) })
            return 0.6
        }
        // homeselect:quickAccess|favorites|recent:Name|Name
        DebugScript.registerStep("homeselect") { arg, window in
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard let section = HomeSection(rawValue: parts.first ?? ""), let page = homePage(window) else { return 0.3 }
            page.select(section, names: parts.count > 1 ? parts[1].components(separatedBy: "|") : [])
            return 0.4
        }
        // homecollapse:recent — toggle a section header.
        DebugScript.registerStep("homecollapse") { arg, window in
            if let section = HomeSection(rawValue: arg) { homePage(window)?.toggleSection(section) }
            return 0.4
        }
        // homemenu:/out.txt — the context menu for the current Home selection.
        DebugScript.registerStep("homemenu") { arg, window in
            guard let page = homePage(window) else { return 0.3 }
            PageDebug.appendMenu("home menu (\(page.activeSection?.rawValue ?? "background"))", page.contextMenu(sender: page.sectionSender), to: arg)
            return 0.3
        }
        // homeperform:<command id> — run a command as if chosen from the Home context menu.
        DebugScript.registerStep("homeperform") { arg, window in
            guard let page = homePage(window), let window else { return 0.3 }
            let ctx = window.context(surface: .itemContextMenu, sender: page.sectionSender)
            if !CommandRegistry.shared.perform(arg, context: ctx) { NSLog("DebugScript: \(arg) unavailable on Home") }
            return 0.8
        }
        DebugScript.registerStep("homeclear") { _, _ in HomeStore.clearHistory(); return 0.8 }
        // pagekey:down|up|left|right|return|cmdreturn|tab — a key press to the focused view.
        DebugScript.registerStep("pagekey") { arg, window in
            PageDebug.sendKey(arg, to: window?.window)
            return 0.4
        }
        DebugScript.registerLogger("home.log") { window in
            homePage(window)?.debugSummary ?? "home: (not shown)"
        }
    }
}

/// Helpers for page-level script steps.
enum PageDebug {
    static func appendMenu(_ title: String, _ menu: NSMenu?, to path: String) {
        var text = "\(title):\n"
        menu?.update()
        for item in menu?.items ?? [] {
            if item.isSeparatorItem { text += "---\n"; continue }
            text += item.title + (item.state == .on ? " ✓" : "") + (item.isEnabled ? "" : " (disabled)") + "\n"
        }
        if menu == nil { text += "(no menu)\n" }
        append(text + "===\n", to: path)
    }

    static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func sendKey(_ name: String, to window: NSWindow?) {
        let keys: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "down": (125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.numericPad, .function]),
            "up": (126, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.numericPad, .function]),
            "left": (123, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.numericPad, .function]),
            "right": (124, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.numericPad, .function]),
            "return": (36, "\r", []),
            "cmdreturn": (36, "\r", [.command]),
            "tab": (48, "\t", []),
        ]
        guard let window, let (code, chars, mods) = keys[name],
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        if name == "tab" {
            if let view = window.firstResponder as? NSView { window.selectKeyView(following: view) }
            return
        }
        (window.firstResponder ?? window).keyDown(with: event)
    }
}
