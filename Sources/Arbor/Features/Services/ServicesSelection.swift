import AppKit
import ArborCore

/// The one rule for what may be sent to another app's service.
enum ServicesSelection {
    /// Older services still declare this type; AppKit may ask for only that, and `writeObjects` also provides it.
    static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// All or nothing: a service must never act on part of what the user selected.
    static func urls(in window: BrowserWindowController) -> [URL] {
        let context = window.context(surface: .menuBar, sender: nil)
        guard context.location != .trash, context.location?.archiveFile == nil,
              !context.selection.isEmpty, context.selection.count <= ExternalOpen.maxItems,
              !MenuAudit.involvesDisconnectedDrive(context) else { return [] }
        let urls = context.selection.map(\.url)
        return urls.allSatisfy(\.isFileURL) ? urls : []
    }
}
