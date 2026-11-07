import AppKit
import ArborCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [BrowserWindowController] = []
    static var isHeadless: Bool { ProcessInfo.processInfo.environment["ARBOR_HEADLESS"] != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.applyEnvironmentAppearance()
        Features.registerAll()
        NSApp.mainMenu = MainMenu.build()
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        if controllers.isEmpty, launchLocation() == nil { WindowHooks.restoreSession?(self) }
        if controllers.isEmpty {
            let start = launchLocation()
            openWindow(at: start?.location ?? WindowHooks.startLocation(), select: start?.select ?? [])
        }
        if !Self.isHeadless { NSApp.activate(ignoringOtherApps: true) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            FileClipboard.shared.refresh()
        }
        DebugScript.runIfRequested()
    }

    /// `Arbor /some/folder` from Terminal (FE-219). The argument is resolved like the address bar; never executed.
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

    /// New window. Explorer opens new windows and tabs to Home (DEC-020).
    @discardableResult
    func openWindow(at location: Location = WindowHooks.startLocation(), select: [String] = []) -> BrowserWindowController {
        register(BrowserWindowController(location: location, initialSelection: select))
    }

    /// A window that adopts existing tabs (Move tab to new window).
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
            // Rendered and scriptable, but invisible and click-through, so test runs don't disturb the screen.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        return controller
    }

    // Dropping a folder on the Dock icon, or `open -a Arbor folder`: a new tab in the front window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let location = Location.folder(isDirectory.boolValue ? url : url.deletingLastPathComponent())
            let select = isDirectory.boolValue ? [] : [url.lastPathComponent]
            if let front = BrowserWindowController.active {
                front.openTab(location, select: select)
                front.window?.makeKeyAndOrderFront(nil)
            } else {
                openWindow(at: location, select: select)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Like other Mac apps the app keeps running, so a transfer can finish after its window closes.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard OperationCenter.shared.hasActiveJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Files are still being copied or moved."
        alert.informativeText = "If you quit now, the file being copied is removed and the rest is not copied. Items that already finished are kept, originals are never removed before their copy completes, and Arbor lists what didn't finish the next time it opens."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertSecondButtonReturn {
            // Stop cleanly (no partial file left) and keep the jobs' journals for review next launch.
            OperationCenter.shared.cancelAllForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateCancel
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "An open-source file manager for macOS with the layout of Windows File Explorer: tabs, a navigation pane, an editable address bar and a details view.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
        ])
    }
}
