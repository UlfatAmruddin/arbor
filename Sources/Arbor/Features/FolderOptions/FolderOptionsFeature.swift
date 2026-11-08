import AppKit
import ArborCore

extension MenuSection {
    /// "…" ▸ Options, last like Explorer.
    static let options = MenuSection(rank: 960, name: "options")
    /// View ▾ note saying where the folder's view comes from.
    static let viewSource = MenuSection(rank: 990, name: "viewSource")
}

/// Folder Options (FE-042/043/045/046), per-folder views (FE-040/041/052/248) and session restore
/// (FE-024/026/251). See docs/features/folder-options.md.
enum FolderOptionsFeature {
    static func register() {
        HeadlessPrefsSeed.load()
        registerCommands()
        installHooks()
        FolderViews.shared.install()
        SessionRestore.install()
        ItemClickBehavior.shared.install()
        NavigationPaneOptions.install()
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            prefsChanged(note.userInfo?["key"] as? String)
        }
        registerScriptSteps()
    }

    // MARK: Commands

    private static func registerCommands() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "folderOptions.open", title: "Options", symbol: "gearshape",
                placements: [.seeMore(.options, 10)],
                perform: { ctx in FolderOptionsWindowController.show(from: ctx.window) }),
            ExplorerCommand(
                id: "app.settings", title: "Settings…", shortcut: Shortcut(","),
                placements: [.mainMenu("Arbor", .main, 10)],
                perform: { ctx in FolderOptionsWindowController.show(from: ctx.window ?? BrowserWindowController.active) }),
            ExplorerCommand(
                id: "view.folderViewSource", title: "Folder view",
                placements: [.viewMenu(.viewSource, 10), .mainMenu("View", .viewSource, 10)],
                dynamicTitle: { ctx in
                    guard let window = ctx.window, let info = FolderViews.shared.info(for: window) else { return L10n.tr("Folder view: not a folder") }
                    return L10n.format("Folder view: %@ (%@)", "\(info.source.description)", "\(info.template.title)")
                },
                isAvailable: { ctx in ctx.location?.isFolder ?? false },
                isEnabled: { _ in false }),
            ExplorerCommand(
                id: "view.resetFolderView", title: "Reset This Folder's View",
                placements: [.mainMenu("View", .viewSource, 20)],
                isAvailable: { ctx in ctx.location?.isFolder ?? false },
                isEnabled: { ctx in ctx.window.flatMap { FolderViews.shared.info(for: $0) }?.source == .folder },
                perform: { ctx in if let window = ctx.window { FolderViews.shared.resetFolder(in: window) } }),
        ])
    }

    // MARK: Hooks

    private static func installHooks() {
        WindowHooks.startLocation = { Prefs.openTo }
        WindowHooks.tabTitle = { location in Prefs.fullPathInTitleBar ? location.folderURL?.path : nil }
        WindowHooks.openFolder = { _, location in
            guard Prefs.openFoldersInOwnWindow, let app = NSApp.delegate as? AppDelegate else { return false }
            app.openWindow(at: location)
            return true
        }
        WindowHooks.itemFilters.append { items, _ in
            Prefs.hideProtectedSystemFiles ? ProtectedSystemItems.filter(items) : items
        }
        WindowHooks.didCreate.append { controller in controller.statusBar.setVisibleForFolderOptions(Prefs.showStatusBar) }
        WindowHooks.willDisplay.append(syncProviderNotice)
        WindowHooks.didDisplay.append { window, _ in
            // Keep the dialog's "This folder:" line in step with its window.
            if let dialog = FolderOptionsWindowController.shared, dialog.origin === window, dialog.window?.isVisible == true {
                dialog.refreshFolderViewsInfo()
            }
        }
        PreviewPolicy.showsPreviewHandlers = { Prefs.showPreviewHandlers }
        // "Clear Arbor history" also clears Home's Recent, frequent folders and removal marks.
        FolderOptionsHistory.register("home") {
            HomeStore.clearHistory()
            return 1
        }
    }

    /// "Show sync provider notifications": a status-bar notice when entering a folder a sync provider owns.
    private static var lastProviderRoot: [ObjectIdentifier: String] = [:]

    private static func syncProviderNotice(_ window: BrowserWindowController, _ tab: TabState, _ location: Location, _ changed: Bool) {
        guard changed, tab === window.activeTab else { return }
        let id = ObjectIdentifier(window)
        guard let url = location.folderURL,
              let provider = SyncProviderDetector.provider(forPath: url.path, home: NSHomeDirectory()) else {
            lastProviderRoot[id] = nil
            return
        }
        guard lastProviderRoot[id] != provider.root else { return }
        lastProviderRoot[id] = provider.root
        guard Prefs.showSyncProviderNotifications else { return }
        window.statusBar.setMessage(L10n.format("This folder is synced by %@. Files stored only online download when you open them.", "\(provider.name)"))
    }

    private static func prefsChanged(_ key: String?) {
        guard let key else { return }
        HeadlessPrefsSeed.save()
        let windows = FolderViews.windows
        switch key {
        case "fullPathInTitleBar":
            windows.forEach { $0.refreshChrome() }
        case "showStatusBar":
            windows.forEach { $0.statusBar.setVisibleForFolderOptions(Prefs.showStatusBar) }
        case "hideProtectedSystemFiles":
            for window in windows {
                window.tabs.filter { $0 !== window.activeTab }.forEach { $0.items = nil }
                window.reload()
                window.navPane.rebuild()
                window.navPane.reveal(window.location)
            }
        case "clickItems", "underlineTitles", "showPopupDescriptions":
            windows.forEach { $0.itemView?.reloadRows() }
        case "navShowAllFolders", "navShowAvailabilityStatus", "navExpandToOpenFolder", "showLibraries":
            for window in windows {
                window.navPane.rebuild()
                window.navPane.reveal(window.location)
            }
        default:
            break
        }
    }

    // MARK: Scripted checks

    private static func registerScriptSteps() {
        DebugScript.registerStep("folderoptions") { arg, window in
            FolderOptionsWindowController.show(tab: FolderOptionsTab(rawValue: arg) ?? .general, from: window)
            return 1.0
        }
        DebugScript.registerStep("fotab") { arg, _ in
            FolderOptionsWindowController.shared?.selectTab(FolderOptionsTab(rawValue: arg) ?? .general)
            return 0.5
        }
        DebugScript.registerStep("foset") { arg, _ in
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return 0.3 }
            FolderOptionsWindowController.shared?.scriptSet(parts[0], OptionValue(parsing: parts[1]))
            return 0.5
        }
        DebugScript.registerStep("fobutton") { arg, _ in
            if FolderOptionsWindowController.shared?.scriptPress(arg) != true { NSLog("DebugScript: no Folder Options button \(arg)") }
            return 0.8
        }
        DebugScript.registerStep("fosnapshot") { arg, _ in
            guard let window = FolderOptionsWindowController.shared?.window else { return 0.3 }
            snapshot(window, to: arg)
            if let sheet = window.attachedSheet { snapshot(sheet, to: arg.replacingOccurrences(of: ".png", with: "-sheet.png")) }
            return 0.5
        }
        DebugScript.registerStep("folog") { arg, window in
            var text = FolderOptionsWindowController.shared?.debugState ?? "folder options: closed"
            text += "\nprefs: " + FolderOptionsPrefs.current().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            if let window { text += "\n" + FolderViews.shared.debugLine(window) }
            text += "\nsession file: \(SessionRestore.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)\n---\n"
            append(text, to: arg)
            return 0.3
        }
        DebugScript.registerStep("singleclick") { arg, window in
            if let window { ItemClickBehavior.shared.scriptClick(window, name: arg) }
            return 1.0
        }
        DebugScript.registerStep("doubleclick") { arg, window in
            if let window {
                ItemClickBehavior.shared.scriptClick(window, name: arg, clickCount: 1)
                ItemClickBehavior.shared.scriptClick(window, name: arg, clickCount: 2)
            }
            return 1.0
        }
        DebugScript.registerStep("hoverrow") { arg, window in
            if let window { ItemClickBehavior.shared.scriptHover(window, name: arg) }
            return 0.3
        }
        DebugScript.registerStep("typekeys") { arg, window in
            if let window { ItemClickBehavior.shared.scriptType(window, arg) }
            return 0.8
        }
        DebugScript.registerStep("setcolumn") { arg, window in
            // setcolumn:<id>:<width> resizes a column; setcolumn:<id>:hide / :show like the header menu.
            // Both go through the Details column editing path (saved for the folder).
            let parts = arg.split(separator: ":").map(String.init)
            guard parts.count == 2, let details = window?.itemView as? DetailsViewController,
                  var set = details.hostOptions?.columns else { return 0.3 }
            let id = ColumnID(parts[0])
            switch parts[1] {
            case "hide": details.setColumnVisible(id, false)
            case "show": details.setColumnVisible(id, true)
            default:
                guard let width = Double(parts[1]) else { return 0.3 }
                set.setWidth(width, of: id)
                details.setColumns(set)
            }
            return 0.5
        }
        DebugScript.registerStep("sortby") { arg, window in
            // sortby:<key>[:desc] — like clicking Sort ▾.
            let parts = arg.split(separator: ":").map(String.init)
            guard let window, let key = SortKey(rawValue: parts.first ?? "") else { return 0.3 }
            var order = window.activeTab.sortOrder
            order.key = key
            order.ascending = parts.count < 2 || parts[1] != "desc"
            window.setSortOrder(order)
            return 0.5
        }
        DebugScript.registerStep("sessionsave") { _, _ in
            SessionRestore.saveNow(sync: true)
            FolderViews.shared.saveNow(sync: true)
            return 0.3
        }
        DebugScript.registerStep("movewindow") { arg, window in
            // movewindow:x,y,w,h then screenschanged — simulates a display being unplugged.
            let v = arg.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { window?.window?.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true) }
            return 0.3
        }
        DebugScript.registerStep("screenschanged") { _, _ in
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            return 0.5
        }
        DebugScript.registerLogger { window in
            let shown = !window.statusBar.isHidden
            return FolderViews.shared.debugLine(window) + "\nstatus bar shown: \(shown)  " + ItemClickBehavior.shared.debugLine
                + "  window title: \(window.window?.title ?? "-")"
        }
    }

    static func snapshot(_ window: NSWindow, to path: String) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
}

extension StatusBarView {
    /// "Show status bar": collapses the bar to zero height so the file list takes its place.
    func setVisibleForFolderOptions(_ visible: Bool) {
        isHidden = !visible
        if let height = constraints.first(where: { $0.firstAttribute == .height && $0.secondItem == nil && $0.firstItem === self }) {
            height.constant = visible ? Theme.statusBarHeight : 0
        }
    }
}

/// Headless runs use a throwaway preferences domain. With `ARBOR_STATE_DIR` set, Folder Options values
/// are kept in that folder too, so a scripted run can test restore-at-launch across two launches.
enum HeadlessPrefsSeed {
    private static var url: URL? {
        guard AppDelegate.isHeadless, ProcessInfo.processInfo.environment["ARBOR_STATE_DIR"] != nil else { return nil }
        return FolderOptionsStorage.url("HeadlessFolderOptions.plist")
    }

    static func load() {
        guard let url, let values = NSDictionary(contentsOf: url) as? [String: Any] else { return }
        for (key, value) in values { Prefs.store.set(value, forKey: key) }
    }

    static func save() {
        guard let url else { return }
        var values: [String: Any] = [:]
        for (key, value) in FolderOptionsPrefs.current() {
            // Bridged settings are stored under their owner's key with their own meaning.
            let stored = FolderOptionsPrefs.storageKey(key)
            switch (key, value) {
            case ("hideExtensions", .bool(let b)): values[stored] = !b
            case ("hiddenFiles", .string(let s)): values[stored] = s == "show"
            case (_, .bool(let b)): values[stored] = b
            case (_, .string(let s)): values[stored] = s
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        (values as NSDictionary).write(to: url, atomically: true)
    }
}
