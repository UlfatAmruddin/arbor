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
        switch PathResolver().resolve(text, relativeTo: addressBase) {
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
            if Self.unresolvedAddress.handle((self, text, error)) { return }
            statusBar.setMessage(error.localizedDescription, isError: true)
            addressBar.showInvalid()
        }
    }

    /// What relative typed paths are relative to. Not `folderURL`: this runs on every keystroke and it can ask the disk.
    var addressBase: URL {
        if case .folder(let url) = location { return url }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Asked only after the resolver failed, so a real item with the same name always wins.
    static let unresolvedAddress = Handlers<(BrowserWindowController, String, PathResolutionError), Void>(
        "BrowserWindowController.unresolvedAddress", "Address text the resolver could not place; true = handled.",
        signature: "(window, text, error) -> handled")

    /// Handles typed `smb://` / `\\server\share` addresses (network feature).
    static let networkAddressHandler = Handlers<(BrowserWindowController, URL), Void>(
        "BrowserWindowController.networkAddressHandler", "A network address typed in the address bar; true = handled.",
        signature: "(window, url) -> handled")

    func focusAddressBar(text: String? = nil) { addressBar.beginEditing(text: text) }
    func focusSearch() { searchBox.focus() }
}
