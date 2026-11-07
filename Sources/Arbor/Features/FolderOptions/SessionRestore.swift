import AppKit
import ArborCore

/// "Restore previous folder windows at launch" (FE-024) and window placement recovery (FE-026).
///
/// While the option is on, the open windows (frame, tabs, each tab's location, Back/Forward and view)
/// are written to Application Support/Arbor/Session.json whenever they change, so a crash or logout
/// loses nothing. Turning the option off deletes the file. Only keys are saved, never listings (FE-251).
enum SessionRestore {
    static var fileURL: URL? { FolderOptionsStorage.url("Session.json") }
    private static var lastWritten: Data?
    private static var timer: Timer?
    /// Cached so the exit flush works after a scripted run discarded its preferences.
    private static var enabled = false

    static func install() {
        WindowHooks.restoreSession = { app in restore(into: app) }
        WindowHooks.didCreate.append { controller in recoverPlacement(controller) }
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
            let tabs = c.tabs.map { SessionTab(history: $0.history, viewMode: $0.viewMode.rawValue, sort: $0.sortOrder) }
            return SessionWindow(frame: window.frame, tabs: tabs, activeTab: c.activeIndex)
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
            let tabs: [TabState] = saved.tabs.compactMap { entry in
                guard let history = entry.history() else { return nil }
                let tab = TabState(location: history.current.location,
                                   viewMode: ViewMode(rawValue: entry.viewMode) ?? .details, sortOrder: entry.sortOrder)
                tab.history = history
                return tab
            }
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
