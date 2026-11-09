import AppKit
import ArborCore

/// "Restore previous folder windows at launch" (FE-024) and off-screen window recovery (FE-026).
/// While on, windows are saved to Session.json on every change (keys only, never listings, FE-251); off deletes it.
enum SessionRestore {
    static var fileURL: URL? { FolderOptionsStorage.url("Session.json") }
    private static var lastWritten: Data?
    private static var timer: Timer?
    /// Cached so the exit flush works after a scripted run discarded its preferences.
    private static var enabled = false

    static func install() {
        WindowHooks.restoreSession.provide("folder-options.session-restore") { app in restore(into: app) }
        WindowHooks.didCreate.observe("folder-options.recover-placement") { controller in recoverPlacement(controller) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            FolderViews.windows.forEach(recoverPlacement)
        }
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            guard note.userInfo?["key"] as? String == "restorePreviousWindows" else { return }
            updateTimer()
            if Prefs.restorePreviousWindows { saveNow(sync: false) } else { deleteFile() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            saveNow(sync: true)
        }
        // Scripted runs end with exit(); flush the last state then too.
        atexit {
            SessionRestore.saveNow(sync: true)
            FolderViews.shared.saveNow(sync: true)
        }
        updateTimer()
    }

    private static func updateTimer() {
        enabled = Prefs.restorePreviousWindows
        timer?.invalidate()
        timer = nil
        guard Prefs.restorePreviousWindows, fileURL != nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { _ in saveNow(sync: false) }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Saving

    /// The open windows, back to front.
    static func snapshot() -> SessionState {
        let order = NSApp.orderedWindows
        let controllers = FolderViews.windows.sorted { a, b in
            (order.firstIndex { $0 === a.window } ?? Int.max) > (order.firstIndex { $0 === b.window } ?? Int.max)
        }
        return SessionState(windows: controllers.compactMap { c in
            guard let window = c.window, !c.tabs.isEmpty else { return nil }
            return SessionWindow(frame: window.frame, tabs: c.tabs.map(\.sessionTab), activeTab: c.activeIndex)
        })
    }

    static func saveNow(sync: Bool) {
        guard Thread.isMainThread, enabled, let url = fileURL, let data = snapshot().encoded(),
              data != lastWritten else { return }
        lastWritten = data
        let write = { try? FolderViewStore.write(data, to: url) }
        if sync { FolderOptionsStorage.writeQueue.sync { _ = write() } } else { FolderOptionsStorage.writeQueue.async { _ = write() } }
    }

    private static func deleteFile() {
        guard let url = fileURL else { return }
        lastWritten = nil
        FolderOptionsStorage.writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Restoring

    /// Reopens the saved windows. Tabs whose folder is gone fall back to Home when they load.
    static func restore(into app: AppDelegate) {
        guard Prefs.restorePreviousWindows, let url = fileURL, let data = try? Data(contentsOf: url),
              let state = SessionState.decode(data) else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        for saved in state.windows {
            let tabs = saved.tabs.compactMap(TabState.init(session:))
            guard !tabs.isEmpty else { continue }
            let active = min(saved.activeTab, tabs.count - 1)
            let controller = app.openWindow(tabs: tabs, activeIndex: active)
            if let frame = saved.rect, let window = controller.window {
                window.setFrame(screens.isEmpty ? frame : WindowPlacement.recover(frame, screens: screens), display: true)
            }
        }
        lastWritten = data
    }

    /// Moves a window whose title bar is off every screen (display unplugged) back onto one (FE-026).
    static func recoverPlacement(_ controller: BrowserWindowController) {
        guard let window = controller.window, !window.styleMask.contains(.fullScreen) else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        let fixed = WindowPlacement.recover(window.frame, screens: screens)
        if fixed != window.frame { window.setFrame(fixed, display: true) }
    }
}
