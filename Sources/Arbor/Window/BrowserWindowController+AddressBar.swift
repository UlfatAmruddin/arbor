import AppKit
import ArborCore

extension BrowserWindowController {
    // MARK: - Address bar

    func submitAddress(_ text: String) {
        if let place = Location.keyword(text) {
            addressBar.endEditing()
            navigate(to: place)
            itemView?.focus()
            return
        }
        let base = location.folderURL ?? FileManager.default.homeDirectoryForCurrentUser
        switch PathResolver().resolve(text, relativeTo: base) {
        case .success(.folder(let url)):
            addressBar.endEditing()
            navigate(to: url)
            itemView?.focus()
        case .success(.file(let url)):
            addressBar.endEditing()
            navigate(to: url.deletingLastPathComponent(), select: [url.lastPathComponent])
            itemView?.focus()
        case .success(.network(let url)):
            addressBar.endEditing()
            if Self.networkAddressHandler.handle((self, url)) { itemView?.focus(); return }
            SystemOpen.open(url)
            statusBar.setMessage(L10n.format("Connecting to %@… The share will appear under This Mac once it's mounted.", "\(url.host ?? url.absoluteString)"))
            itemView?.focus()
        case .failure(let error):
            statusBar.setMessage(error.localizedDescription, isError: true)
            addressBar.showInvalid()
        }
    }

    /// `smb://` / `\\server\share` typed in the address bar; a handler returns true when it handled it (network feature).
    static let networkAddressHandler = Handlers<(BrowserWindowController, URL), Void>(
        "BrowserWindowController.networkAddressHandler", "A network address typed in the address bar; true = handled.",
        signature: "(window, url) -> handled")

    func focusAddressBar(text: String? = nil) { addressBar.beginEditing(text: text) }
    func focusSearch() { searchBox.focus() }
}
