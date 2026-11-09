import AppKit
import ArborCore

/// The one place that acts on a Windows shortcut; nothing is remembered, so every open is checked again.
enum WindowsShortcutOpener {
    /// Reads still running and prompts waiting, together: a read that finishes becomes a prompt.
    private static let maxPendingOpens = 8

    /// The last alert's text, for scripted checks.
    private(set) static var lastAlert: String?

    /// Where an open began. Captured on claim, because `window.location` moves as soon as a result opens a tab.
    private struct Origin {
        weak var window: BrowserWindowController?
        weak var tab: TabState?
        let location: Location
        let isBatch: Bool

        /// Spec §3.3: nil once the tab has closed or moved on, so a late result does nothing.
        var liveWindow: BrowserWindowController? {
            guard let window, let tab, window.tabs.contains(where: { $0 === tab }), tab.location == location else { return nil }
            return window
        }
    }

    // MARK: Claiming an open

    static func open(_ window: BrowserWindowController, _ file: FileItem) -> Bool {
        guard file.url.isFileURL, !file.isFolder, !file.isPackage else { return false }
        if file.isSymbolicLink { return refuseIfLinkToShortcut(file, in: window) }
        guard file.windowsShortcutKind != nil else { return false }
        begin(file.url, name: file.name, in: window)
        return true
    }

    /// The system follows links and aliases and opens the end of the chain with no check, whatever the link is named.
    private static func refuseIfLinkToShortcut(_ link: FileItem, in window: BrowserWindowController) -> Bool {
        var end = link.url.resolvingSymlinksInPath()
        if case .target(let target, _)? = Shortcuts.resolve(end) { end = target }
        guard WindowsShortcutKind(fileName: end.lastPathComponent) != nil else { return false }
        explain(cannotOpen(link.name), L10n.tr("This is a symbolic link to a Windows shortcut. Open the shortcut itself instead."), in: window)
        return true
    }

    /// Members aren't files on disk yet, and their target would be judged from a temporary folder.
    static func explainArchiveMember(_ window: BrowserWindowController, _ file: FileItem) -> Bool {
        guard file.windowsShortcutKind != nil, ArchiveCatalog.ref(for: file.url) != nil else { return false }
        explain(cannotOpen(file.name), L10n.tr("Windows shortcuts can't be opened from inside an archive. Extract it first, then open it."), in: window)
        return true
    }

    private static func begin(_ url: URL, name: String, in window: BrowserWindowController) {
        // Counts jobs stuck on a hung share too, so selecting hundreds can't pile up blocked threads.
        guard WindowsShortcutReader.inFlightCount + AlertSheets.waitingCount(in: window.window) < maxPendingOpens else {
            window.statusBar.setMessage(L10n.tr("Too many shortcuts to open at once. Open fewer at a time."), isError: true)
            return
        }
        let origin = Origin(window: window, tab: window.activeTab, location: window.location, isBatch: window.selectedItems.count > 1)
        WindowsShortcutReader.inspect(url) { outcome in
            guard let window = origin.liveWindow else { return }
            switch outcome {
            case .timedOut:
                explain(cannotOpen(name), WindowsShortcutReader.timeoutMessage, in: window)
            case .finished(.failure(let error)):
                explain(cannotOpen(name), error.localizedDescription, in: window)
            case .finished(.success(.internet(let shortcut))):
                openAddress(shortcut, file: url, name: name, in: window)
            case .finished(.success(.link(_, let destination))):
                follow(destination, shortcut: url, name: name, origin: origin, in: window)
            }
        }
    }

    // MARK: Acting on what the policy allows

    private static func openAddress(_ shortcut: InternetShortcut, file: URL, name: String, in window: BrowserWindowController) {
        switch shortcut.address {
        case .failure(let refusal):
            explain(cannotOpen(name), refusal.explanation, in: window)
        case .success(let url):
            let info = L10n.format("“%@” opens this address in your browser:\n\n%@\n\nSite: %@",
                                   "\(UntrustedText.display(name))", "\(url.absoluteString)", "\(UntrustedText.display(url.host ?? ""))")
            confirm(L10n.tr("Open this web address?"), info, in: window) {
                SystemOpen.open(url)
                recordOpened(file, in: window)
            }
        }
    }

    private static func follow(_ destination: LinkDestination, shortcut: URL, name: String, origin: Origin, in window: BrowserWindowController) {
        switch destination {
        case .folder(let folder):
            // Through open(), so the "open each folder in its own window" option still applies.
            let item = FileItem(url: folder, name: folder.lastPathComponent, isFolder: true)
            window.open([item], inNewTab: origin.isBatch || window.activeTab !== origin.tab)
        case .document(let target):
            let info = L10n.format("“%@” points to this file on your Mac:\n\n%@", "\(UntrustedText.display(name))", "\(UntrustedText.display(target.path))")
            confirm(L10n.tr("Open this file?"), info, in: window) { reopen(target, shortcut: shortcut, name: name, in: window) }
        case .revealOnly(let target):
            offerReveal(target, name: name, in: window)
        case .blocked(let block):
            explain(cannotOpen(name), block.explanation, in: window)
        }
    }

    /// Decides again after the answer, under its own key so a read from before the answer can't be reused.
    private static func reopen(_ target: URL, shortcut: URL, name: String, in window: BrowserWindowController) {
        WindowsShortcutReader.inspect(shortcut, key: "recheck:\(shortcut.path)") { [weak window] outcome in
            guard let window else { return }
            guard case .finished(.success(.link(_, .document(let current)))) = outcome, current == target else {
                explain(cannotOpen(name), L10n.tr("The shortcut or the file it points to changed, so Arbor didn't open it."), in: window)
                return
            }
            SystemOpen.open(target)
            recordOpened(target, in: window)
        }
    }

    /// Home ▸ Recent lists what was opened, as it does for every other route.
    private static func recordOpened(_ file: URL, in window: BrowserWindowController) {
        NotificationCenter.default.post(name: LocationEvents.didOpenFiles, object: window, userInfo: ["urls": [file]])
    }

    private static func offerReveal(_ target: URL, name: String, in window: BrowserWindowController) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = cannotOpen(name)
        alert.informativeText = L10n.format("It points to “%@”. Apps, scripts, installers and similar items can run code or change your Mac, so Arbor only shows them in their folder.", "\(UntrustedText.display(target.path))")
        alert.addButton(withTitle: L10n.tr("Show in Folder"))
        alert.addButton(withTitle: L10n.tr("Close")).keyEquivalent = escape
        record(alert)
        AlertSheets.present(alert, in: window.window) { [weak window] response in
            guard response == .alertFirstButtonReturn else { return }
            window?.navigate(to: target.deletingLastPathComponent(), select: [target.lastPathComponent])
        }
    }

    // MARK: Alerts

    private static func cannotOpen(_ name: String) -> String {
        L10n.format("“%@” can't be opened on this Mac.", "\(UntrustedText.display(name))")
    }

    /// Set by hand: NSAlert only gives Esc to a button titled exactly "Cancel", which a translation isn't.
    private static let escape = "\u{1b}"

    private static func explain(_ message: String, _ info: String, in window: BrowserWindowController) {
        lastAlert = oneLine(message, info)
        NSAlert.show(message, info, in: window.window)
    }

    private static func confirm(_ message: String, _ info: String, in window: BrowserWindowController, then proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        // No button takes Return: it opens items in the list (DEC-009), and a second press mustn't answer unread text.
        alert.addButton(withTitle: L10n.tr("Cancel")).keyEquivalent = escape
        alert.addButton(withTitle: L10n.tr("Open"))
        record(alert)
        AlertSheets.present(alert, in: window.window) { if $0 == .alertSecondButtonReturn { proceed() } }
    }

    private static func record(_ alert: NSAlert) { lastAlert = oneLine(alert.messageText, alert.informativeText) }

    private static func oneLine(_ message: String, _ info: String) -> String {
        "\(message) \(info)".replacingOccurrences(of: "\n", with: " ")
    }
}
