import AppKit
import ArborCore

/// The system pasteboard plus this app's record of whether the files were cut or copied.
/// Other apps see standard file URLs and text only, so a cut reaches them as a copy (FE-101).
final class FileClipboard {
    /// Headless test runs use a private pasteboard so they never overwrite the user's clipboard.
    static let shared = FileClipboard(pasteboard: Automation.environment["ARBOR_HEADLESS"] == nil
        ? NSPasteboard.general
        : NSPasteboard(name: NSPasteboard.Name("io.github.arbor-files.test.\(getpid())")))
    static let changed = Notification.Name("ArborClipboardChanged")

    let pasteboard: NSPasteboard
    private(set) var intent: TransferIntent?
    /// Another app's content whose files Arbor moved away: it stays that app's, but is no longer offered.
    private var movedAwayChangeCount: Int?

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    func write(_ urls: [URL], kind: TransferKind) {
        pasteboard.clearContents()
        pasteboard.writeObjects(Self.items(for: urls))
        intent = TransferIntent(kind: kind, urls: urls, pasteboardChangeCount: pasteboard.changeCount)
        post()
    }

    func writePaths(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        post()
    }

    /// Apps asking for text read only the first item, so that one carries every path.
    private static func items(for urls: [URL]) -> [NSPasteboardItem] {
        urls.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index == 0 { item.setString(ClipboardFiles.plainText(for: urls), forType: .string) }
            return item
        }
    }

    var changeCount: Int { pasteboard.changeCount }

    var itemCount: Int { pasteboard.pasteboardItems?.count ?? 0 }

    func contents() -> ClipboardFiles.Contents {
        guard canPaste else { return .nothing }
        return ClipboardFiles.read(itemCount: itemCount) {
            // Not limited to file URLs: a web link has to be seen to be refused, not quietly left out.
            (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        }
    }

    func readURLs() -> [URL] {
        if case .files(let urls) = contents() { return urls }
        return []
    }

    /// Asked while menus are built, so it reads only the types: a hung owner can't stall the window.
    var canPaste: Bool {
        changeCount != movedAwayChangeCount
            && pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func pasteKind(for urls: [URL]) -> TransferKind {
        TransferIntent.pasteKind(intent: intent, changeCount: pasteboard.changeCount, pasteboardURLs: urls)
    }

    func isCut(_ url: URL) -> Bool { intent?.marksCut(url, changeCount: pasteboard.changeCount) ?? false }

    /// Like Explorer, a finished move empties the clipboard; a second Paste would only fail (QA-CORE-3).
    /// Only content this app wrote is cleared, and only if it is still what was pasted.
    func finishedMove(changeCount: Int) {
        if pasteboard.changeCount == changeCount {
            if intent?.isCurrent(changeCount: changeCount) == true {
                pasteboard.clearContents()
                intent = nil
            } else {
                movedAwayChangeCount = changeCount
            }
        }
        post()
    }

    /// Another app may have changed the pasteboard while we were in the background.
    func refresh() { post() }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}
