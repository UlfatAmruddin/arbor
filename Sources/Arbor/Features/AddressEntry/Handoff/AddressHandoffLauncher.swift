import ArborCore

/// The only way from a typed address to another app. It takes the closed target and the window, never text (SPEC §5.2).
enum AddressHandoffLauncher {
    /// False when the app is missing or the window isn't at a real folder.
    static func launch(_ target: AddressHandoffTarget, in window: BrowserWindowController) -> Bool {
        switch target.route {
        case .application(let identifier):
            return SystemOpen.openApplication(bundleIdentifier: identifier)
        case .settingsPane(let url):
            return SystemOpen.open(url)
        case .terminalAtCurrentFolder:
            guard let folder = window.location.folderURL else { return false }
            return SystemOpen.openTerminal(at: folder)
        }
    }
}
