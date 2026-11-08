import AppKit
import ArborCore

extension BrowserWindowController: NSWindowDelegate {
    // MARK: - Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { OperationCenter.shared.undoManager }

    func windowDidBecomeKey(_ notification: Notification) {
        updateChrome()
        (window as? BrowserWindow)?.layoutTrafficLights()
    }

    func windowDidResize(_ notification: Notification) { (window as? BrowserWindow)?.layoutTrafficLights() }

    func windowWillEnterFullScreen(_ notification: Notification) { tabStrip.leadingInset = 10 }

    func windowDidExitFullScreen(_ notification: Notification) {
        tabStrip.leadingInset = Theme.trafficLightInset
        (window as? BrowserWindow)?.layoutTrafficLights()
    }

    func windowWillClose(_ notification: Notification) {
        watchToken = nil
        tabs.forEach { $0.pendingLoad?.cancel() }
        sidePane.releaseAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        onClose?()
    }
}
