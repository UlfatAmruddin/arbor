import AppKit

/// Alerts about a browsing window are window-modal sheets on it, one at a time.
///
/// An alert that arrives while the window already shows a sheet (another alert, a dialog, a wizard) waits
/// its turn and appears when that sheet closes, instead of stacking or turning into an app-modal alert
/// that blocks every window. An alert with the same text and buttons as one already showing or waiting
/// in that window is merged into it: it isn't shown twice and its caller hears `.cancel` (the safe answer).
/// Without any window (nothing open), the alert is app-modal as a last resort.
///
/// Scripted checks answer these sheets with `button:<title>`; headless runs keep them invisible.
enum AlertSheets {
    private final class Pending {
        let alert: NSAlert
        let key: String
        let completion: ((NSApplication.ModalResponse) -> Void)?
        /// Callers whose identical alert was merged into this one.
        var merged: [(NSApplication.ModalResponse) -> Void] = []
        init(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)?) {
            self.alert = alert
            self.completion = completion
            key = ([alert.messageText, alert.informativeText] + alert.buttons.map(\.title)).joined(separator: "\u{1F}")
        }
    }

    private final class WindowQueue {
        weak var window: NSWindow?
        var showing: Pending?
        var waiting: [Pending] = []
        var observers: [NSObjectProtocol] = []
        init(_ window: NSWindow) { self.window = window }
    }

    private static var queues: [ObjectIdentifier: WindowQueue] = [:]

    /// Shows `alert` as a sheet on `window` (default: the frontmost browsing window), now or after the
    /// sheets already waiting there.
    static func present(_ alert: NSAlert, in window: NSWindow?, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if AppDelegate.isHeadless { alert.window.alphaValue = 0 }
        guard let host = window ?? BrowserWindowController.active?.window else {
            let response = alert.runModal()
            completion?(response)
            return
        }
        let queue = self.queue(for: host)
        let pending = Pending(alert, completion: completion)
        if let same = ([queue.showing].compactMap { $0 } + queue.waiting).first(where: { $0.key == pending.key }) {
            if let completion { same.merged.append(completion) }
            return
        }
        queue.waiting.append(pending)
        pump(queue)
    }

    /// Number of alerts waiting behind the current sheet of `window` (scripted checks).
    static func waitingCount(in window: NSWindow?) -> Int {
        guard let window else { return 0 }
        return queues[ObjectIdentifier(window)]?.waiting.count ?? 0
    }

    private static func queue(for window: NSWindow) -> WindowQueue {
        let id = ObjectIdentifier(window)
        if let existing = queues[id], existing.window === window { return existing }
        let queue = WindowQueue(window)
        let center = NotificationCenter.default
        // Another sheet (not one of ours) ended: the next alert may show now.
        queue.observers.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak queue] _ in
            guard let queue else { return }
            DispatchQueue.main.async { pump(queue) }
        })
        // The window closes: nobody can answer the waiting alerts, so they end as cancelled.
        queue.observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            guard let queue = queues.removeValue(forKey: id) else { return }
            queue.observers.forEach { center.removeObserver($0) }
            for pending in queue.waiting {
                pending.completion?(.cancel)
                pending.merged.forEach { $0(.cancel) }
            }
            queue.waiting = []
        })
        queues[id] = queue
        return queue
    }

    private static func pump(_ queue: WindowQueue) {
        guard queue.showing == nil, let window = queue.window, window.attachedSheet == nil, !queue.waiting.isEmpty else { return }
        let next = queue.waiting.removeFirst()
        queue.showing = next
        next.alert.beginSheetModal(for: window) { response in
            queue.showing = nil
            next.completion?(response)
            next.merged.forEach { $0(.cancel) }
            DispatchQueue.main.async { pump(queue) }
        }
    }
}
