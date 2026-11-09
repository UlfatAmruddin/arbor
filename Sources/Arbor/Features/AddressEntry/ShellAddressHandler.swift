import AppKit
import ArborCore

/// Acts on address text the resolver couldn't place. Goes to places or explains; it never starts anything (SPEC §5.2).
enum ShellAddressHandler {
    static func handle(_ window: BrowserWindowController, text: String, error: PathResolutionError) -> Bool {
        if let outcome = ShellAddress.outcome(for: text, homeDirectory: FileManager.default.homeDirectoryForCurrentUser) {
            perform(outcome, in: window)
            return true
        }
        guard case .notFound = error, ShellAddress.isWindowsCommand(text) else { return false }
        refuse(ShellAddress.commandMessage(for: text), in: window)
        return true
    }

    private static func perform(_ outcome: ShellAddress.Outcome, in window: BrowserWindowController) {
        switch outcome {
        case .place(let place):
            go(to: place, in: window)
        case .recentFiles where Prefs.showRecentFiles:
            go(to: .home, in: window)
        case .recentFiles:
            refuse(L10n.tr("Home's Recent list is turned off. Turn on Show recently used files to use it."), in: window)
        case .noCounterpart(let reason):
            refuse(reason, in: window)
        case .unknown(let name):
            refuse(ShellAddress.unknownNameMessage(name), in: window)
        }
    }

    private static func go(to place: Location, in window: BrowserWindowController) {
        window.addressBar.endEditing()
        window.navigate(to: place)
        window.itemView?.focus()
    }

    /// The text stays editable, as for any other address that failed (SPEC §5.2).
    private static func refuse(_ message: String, in window: BrowserWindowController) {
        window.statusBar.setMessage(message, isError: true)
        window.addressBar.showInvalid()
    }
}
