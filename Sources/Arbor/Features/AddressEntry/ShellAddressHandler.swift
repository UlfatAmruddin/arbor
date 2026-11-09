import AppKit
import ArborCore

/// Acts on address text the resolver couldn't place: goes to a place, explains, or asks before a hand-off (SPEC §5.2).
enum ShellAddressHandler {
    static func handle(_ window: BrowserWindowController, text: String, error: PathResolutionError) -> Bool {
        if let outcome = ShellAddress.outcome(for: text, homeDirectory: FileManager.default.homeDirectoryForCurrentUser) {
            perform(outcome, in: window)
            return true
        }
        guard case .notFound = error, let command = ShellAddress.commandOutcome(for: text) else { return false }
        switch command {
        case .handoff(let target): handOff(target, in: window)
        case .refused(let message): refuse(message, in: window)
        }
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
        case .handoff(let target):
            handOff(target, in: window)
        case .noCounterpart(let reason):
            refuse(reason, in: window)
        case .unknown(let name):
            refuse(ShellAddress.unknownNameMessage(name), in: window)
        }
    }

    /// Only the target goes on from here; the typed text stops in this file.
    private static func handOff(_ target: AddressHandoffTarget, in window: BrowserWindowController) {
        let place = window.location
        if target == .terminal, let reason = AddressHandoffTarget.terminalRefusal(in: place) {
            refuse(reason, in: window)
            return
        }
        AddressHandoffConfirmation.ask(target.prompt(folder: place.folderURL), in: window.window) { accepted in
            guard accepted else { return }
            // The prompt named this folder; a window that has moved on must not open a different one.
            guard target != .terminal || window.location == place else {
                refuse(L10n.tr("The folder changed while Arbor was asking, so Terminal wasn't opened."), in: window)
                return
            }
            guard AddressHandoffLauncher.launch(target, in: window) else {
                refuse(L10n.format("Arbor couldn't open %@.", target.appName), in: window)
                return
            }
            window.addressBar.endEditing()
            window.itemView?.focus()
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
