import AppKit

/// AppKit asks the window (as the window's delegate) whether the selection can go to a service.
extension BrowserWindowController: NSServicesMenuRequestor {
    @objc override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                       returnType: NSPasteboard.PasteboardType?) -> Any? {
        // Type first: AppKit calls this dozens of times per menu. No return type: nothing writes back into Arbor.
        guard sendType == .fileURL, returnType == nil, !isEditingText, !ServicesSelection.urls(in: self).isEmpty else {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        return self
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.fileURL) || types.contains(ServicesSelection.legacyFilenames) else { return false }
        let urls = ServicesSelection.urls(in: self)
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls as [NSURL])
    }
}
