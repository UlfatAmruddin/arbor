import AppKit
import ArborCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [BrowserWindowController] = []
    private var didLaunch = false
    private var pendingOpen: [URL] = []
    static var isHeadless: Bool { Automation.environment["ARBOR_HEADLESS"] != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leftovers from crashed or killed earlier runs; never this process's own files.
        DispatchQueue.global(qos: .utility).async { TemporaryFiles.sweepLeftovers() }
        Theme.applyEnvironmentAppearance()
        Features.registerAll()
        NSApp.mainMenu = MainMenu.build()
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: L10n.tr("Window"))?.submenu
        didLaunch = true
        if !pendingOpen.isEmpty {
            // Decided here, not in the background: the first window comes before Home or session restore.
            show(Self.plan(for: pendingOpen))
            pendingOpen = []
        }
        if controllers.isEmpty, launchLocation() == nil { WindowHooks.restoreSession.value?(self) }
        if controllers.isEmpty {
            let start = launchLocation()
            openWindow(at: start?.location ?? WindowHooks.startLocation.value(), select: start?.select ?? [])
        }
        if !Self.isHeadless { NSApp.activate(ignoringOtherApps: true) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            FileClipboard.shared.refresh()
        }
        DebugScript.runIfRequested()
    }

    /// `Arbor /some/folder` from Terminal (FE-219): resolved like the address bar, never executed.
    private func launchLocation() -> (location: Location, select: [String])? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let arg = args.first else { return nil }
        if let place = Location.keyword(arg) { return (place, []) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        switch PathResolver().resolve(arg, relativeTo: cwd) {
        case .success(.folder(let url)): return (.folder(url), [])
        case .success(.file(let url)): return (.folder(url.deletingLastPathComponent()), [url.lastPathComponent])
        default: return nil
        }
    }

    /// Opens to Home, like Explorer (DEC-020).
    @discardableResult
    func openWindow(at location: Location = WindowHooks.startLocation.value(), select: [String] = []) -> BrowserWindowController {
        register(BrowserWindowController(location: location, initialSelection: select))
    }

    /// Adopts existing tabs (Move tab to new window).
    @discardableResult
    func openWindow(tabs: [TabState], activeIndex: Int = 0) -> BrowserWindowController {
        register(BrowserWindowController(tabs: tabs, activeIndex: activeIndex))
    }

    private func register(_ controller: BrowserWindowController) -> BrowserWindowController {
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        guard let window = controller.window else { return controller }
        if let key = NSApp.keyWindow, key.windowController is BrowserWindowController {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        }
        controller.showWindow(nil)
        if Self.isHeadless {
            // Invisible and click-through, so test runs don't disturb the screen.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        return controller
    }

    // Dock drop, `open -a Arbor`, Finder documents and the Open in Arbor service: a new tab in the front window.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder opens can arrive before launch finishes: wait until features exist.
        guard didLaunch else { pendingOpen += urls; return }
        openExternal(urls)
    }

    /// Checks the items off the main thread, so a dead mount can't hang the UI. `staleAfter` varies only in scripted checks.
    func openExternal(_ urls: [URL], staleAfter: TimeInterval = ExternalOpen.staleAfter) {
        let deadline = DispatchTime.now() + staleAfter
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = Self.plan(for: urls)
            DispatchQueue.main.async {
                if DispatchTime.now() < deadline { self?.show(plan) } else { Self.reportLate() }
            }
        }
    }

    private static func plan(for urls: [URL]) -> ExternalOpen.Plan {
        let found = ExternalOpen.items(for: urls)
        return ExternalOpen.plan(found.items, skipped: found.skipped, ownLocation: LocationRegistry.locationForOpening)
    }

    private func show(_ plan: ExternalOpen.Plan) {
        guard !plan.targets.isEmpty || plan.skipped > 0 else { return }
        if !Self.isHeadless { NSApp.activate(ignoringOtherApps: true) }
        for target in plan.targets {
            if let front = BrowserWindowController.active {
                front.openTab(target.location, select: target.select)
                front.window?.makeKeyAndOrderFront(nil)
            } else {
                openWindow(at: target.location, select: target.select)
            }
        }
        guard plan.skipped > 0 else { return }
        // A status message would be cleared when the new tab loads. Later, so at launch it is a sheet on the first window.
        DispatchQueue.main.async {
            NSAlert.show(L10n.format("Arbor couldn't open %@.", StatusText.items(plan.skipped)),
                         plan.skipped == 1
                            ? L10n.tr("It may have been moved or deleted, be on a drive that isn't available, or be over the limit Arbor opens at once.")
                            : L10n.tr("They may have been moved or deleted, be on a drive that isn't available, or be more than Arbor opens at once."),
                         in: BrowserWindowController.active?.window)
        }
    }

    /// The user has moved on: no activation and no alert, only a note in a window that is already open.
    private static func reportLate() {
        BrowserWindowController.active?.statusBar.setMessage(L10n.tr("A request to open items in Arbor took too long and was dropped."), isError: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running so a transfer can finish after its window closes.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard OperationCenter.shared.hasActiveJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Files are still being copied or moved.")
        alert.informativeText = L10n.tr("If you quit now, the file being copied is removed and the rest is not copied. Items that already finished are kept, originals are never removed before their copy completes, and Arbor lists what didn't finish the next time it opens.")
        alert.addButton(withTitle: L10n.tr("Keep Working"))
        alert.addButton(withTitle: L10n.tr("Quit Anyway"))
        if alert.runModal() == .alertSecondButtonReturn {
            // No partial files left; journals are kept for review next launch.
            OperationCenter.shared.cancelAllForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateCancel
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: L10n.tr("An open-source file manager for macOS with the layout of Windows File Explorer: tabs, a navigation pane, an editable address bar and a details view."),
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
        ])
    }
}
