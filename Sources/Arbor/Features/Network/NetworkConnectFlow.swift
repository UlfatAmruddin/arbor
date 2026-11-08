import AppKit
import ArborCore

/// Opening a share: connect (mount) asynchronously, then show the mounted folder in the tab that
/// asked (FE-176). Discovery, sign-in and mounting stay separate steps; nothing here blocks the UI,
/// and navigating elsewhere cancels the attempt.
enum NetworkConnectFlow {
    /// Connects and navigates `tab` (default: the active tab) to the share. `newTab` opens it in a new tab instead.
    @discardableResult
    static func open(_ address: NetworkAddress, in window: BrowserWindowController, tab: TabState? = nil, newTab: Bool = false,
                     differentCredentials: Bool = false, done: ((Bool) -> Void)? = nil) -> NetworkCancellable {
        let target = tab ?? window.activeTab
        let shown = address.shareRoot?.unc ?? address.unc
        let slow = DispatchWorkItem { [weak window] in window?.statusBar.setMessage("Connecting to \(shown)…") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: slow)
        return NetworkCenter.shared.connect(address, options: MountOptions(differentCredentials: differentCredentials)) { [weak window, weak target] result in
            slow.cancel()
            guard let window else { return }
            switch result {
            case .success(let folder):
                window.statusBar.setMessage(nil)
                if newTab {
                    window.openTab(.folder(folder))
                } else if let target, window.tabs.contains(where: { $0 === target }) {
                    show(folder, in: target, window: window)
                }
                done?(true)
            case .failure(.cancelled):
                window.statusBar.setMessage(nil)
                done?(false)
            case .failure(let error):
                window.statusBar.setMessage(error.localizedDescription, isError: true)
                presentFailure(error, address: address, window: window) { choice in
                    switch choice {
                    case .retry: open(address, in: window, tab: target, newTab: newTab, differentCredentials: differentCredentials, done: done)
                    case .differentCredentials: open(address, in: window, tab: target, newTab: newTab, differentCredentials: true, done: done)
                    case .cancel: done?(false)
                    }
                }
            }
        }
    }

    /// Navigates a tab to the mounted folder. A tab whose only history entry is the not-yet-mounted
    /// `.server` address (a new tab) gets that entry replaced, so Back never lands on it again.
    static func show(_ folder: URL, in tab: TabState, window: BrowserWindowController) {
        if case .server = tab.location, !tab.history.canGoBack, !tab.history.canGoForward {
            tab.history = NavigationHistory(start: .folder(folder))
            window.request(.reload, tab: tab)
        } else {
            window.request(.visit(.folder(folder), select: [], selectURLs: []), tab: tab)
        }
    }

    enum FailureChoice { case retry, differentCredentials, cancel }

    /// Explorer-style "can't access" message with Retry (and different credentials after a sign-in failure).
    static func presentFailure(_ error: NetworkError, address: NetworkAddress, window: BrowserWindowController,
                               choice: @escaping (FailureChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Arbor can't access \(address.shareRoot?.unc ?? address.unc)"
        alert.informativeText = (error.errorDescription ?? "") + (error.isAuthentication ? "" : "\n\nCheck the name and that the computer is on, or ask the person who manages it.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        if error.isAuthentication { alert.addButton(withTitle: "Use Different Credentials…") }
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: choice(.retry)
            case .alertSecondButtonReturn where error.isAuthentication: choice(.differentCredentials)
            default: choice(.cancel)
            }
        }
        AlertSheets.present(alert, in: window.window, completion: handle)
    }
}
