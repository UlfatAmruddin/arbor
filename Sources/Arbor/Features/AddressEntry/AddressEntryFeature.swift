import AppKit
import ArborCore

/// Typing in the address bar: path suggestions (FE-006) and `shell:` names (FE-213). See docs/features/address-entry.md.
enum AddressEntryFeature: ExplorerFeature {
    static let id = "address-entry"
    /// `shell:` names open pages these features provide; `shell:recent` also honors Home's show/hide setting.
    static let requires = ["home", "trash", "this-mac", "network", "gallery-libraries"]

    static func register() {
        WindowHooks.didCreate.observe("address-entry.completion") { window in
            window.addressBar.editingSession = AddressCompletionController(window: window)
        }
        BrowserWindowController.unresolvedAddress.register("address-entry.shell-names", handles: ShellAddressHandler.handle)
        AddressEntryScriptSteps.register()
    }
}
