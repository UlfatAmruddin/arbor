import AppKit
import BetterExplorerCore

/// Receives the Open in Better Explorer service declared in Info.plist (`NSMessage` plus the selector's fixed tail).
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    /// Any local app can send this, so it only reads file URLs; the shared open route checks them.
    @objc(openInBetterExplorer:userData:error:)
    func openInBetterExplorer(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = L10n.tr("Open in Better Explorer needs a file or folder.") as NSString
            return
        }
        (NSApp.delegate as? AppDelegate)?.application(NSApp, open: urls)
    }
}
