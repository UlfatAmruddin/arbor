import AppKit
import ArborCore

/// The system pasteboard plus this app's record of whether the files were cut or copied.
final class FileClipboard {
    static let shared = FileClipboard()
    static let changed = Notification.Name("ArborClipboardChanged")
    /// Headless test runs use a private pasteboard so they never overwrite the user's clipboard.
    private let pasteboard = Automation.environment["ARBOR_HEADLESS"] == nil
        ? NSPasteboard.general
        : NSPasteboard(name: NSPasteboard.Name("io.github.arbor-files.test.\(getpid())"))
    private(set) var intent: TransferIntent?

    func write(_ urls: [URL], kind: TransferKind) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        intent = TransferIntent(kind: kind, urls: urls, pasteboardChangeCount: pasteboard.changeCount)
        post()
    }

    func writePaths(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        post()
    }

    func readURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func pasteKind(for urls: [URL]) -> TransferKind {
        TransferIntent.pasteKind(intent: intent, changeCount: pasteboard.changeCount, pasteboardURLs: urls)
    }

    func isCut(_ url: URL) -> Bool { intent?.marksCut(url, changeCount: pasteboard.changeCount) ?? false }

    func finishedCut() {
        // Like Explorer, a finished cut-and-paste empties the clipboard; a second Paste would only fail (QA-CORE-3).
        // Only content this app wrote is cleared.
        if let intent, intent.kind == .move, intent.isCurrent(changeCount: pasteboard.changeCount) {
            pasteboard.clearContents()
        }
        intent = nil
        post()
    }

    /// Another app may have changed the pasteboard while we were in the background.
    func refresh() { post() }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}
