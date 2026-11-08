import AppKit
import ArborCore

extension BrowserWindowController: ItemViewDelegate {
    // MARK: - ItemViewDelegate

    func itemViewOpen(_ items: [FileItem], inNewTab: Bool) { open(items, inNewTab: inNewTab) }

    func itemViewSelectionDidChange() {
        if !activeTab.showsPage, let view = itemView {
            activeTab.selectedNames = view.selectedNames
            activeTab.selectedURLs = view.selectedItems.map(\.url)
        }
        updateChrome()
        refreshQuickLook()
        WindowHooks.selectionChanged.send(self)
    }

    func itemViewContextMenu() -> NSMenu? {
        contextMenu(for: selectedItems.isEmpty ? .backgroundContextMenu : .itemContextMenu)
    }

    func itemViewRename(_ item: FileItem, to newName: String) -> Bool {
        if let handled = InteractionHooks.commitRename.first((self, item, newName)) { return handled }
        if !item.isFolder {
            let change = ExtensionChange.between(item.name, newName)
            if change != .unchanged {
                let alert = NSAlert()
                alert.messageText = L10n.tr("Change the file name extension?")
                switch change {
                case .changed(let oldExt, let newExt):
                    alert.informativeText = L10n.format("If you change “.%@” to “.%@”, the file might open in a different app or stop opening.", "\(oldExt.lowercased())", "\(newExt.lowercased())")
                    alert.addButton(withTitle: L10n.format("Use .%@", "\(newExt.lowercased())"))
                case .added(let newExt):
                    alert.informativeText = L10n.format("If you add “.%@” to the name, the file might open in a different app or stop opening.", "\(newExt.lowercased())")
                    alert.addButton(withTitle: L10n.format("Use .%@", "\(newExt.lowercased())"))
                case .removed(let oldExt):
                    alert.informativeText = L10n.format("If you remove “.%@” from the name, the file might open in a different app or stop opening.", "\(oldExt.lowercased())")
                    alert.addButton(withTitle: L10n.tr("Remove the extension"))
                case .unchanged:
                    break
                }
                alert.addButton(withTitle: L10n.tr("Cancel"))
                // A sheet on this window. The view reopens the name field with the typed text underneath
                // (returning false); Cancel leaves it there to edit, Use closes it and renames.
                AlertSheets.present(alert, in: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn, let self else { return }
                    self.endRenameField()
                    DispatchQueue.main.async { _ = self.performRename(item, to: newName, reopenOnFailure: true) }
                }
                return false
            }
        }
        return performRename(item, to: newName, reopenOnFailure: false)
    }

    /// Renames without asking. A failure is reported in a sheet and the name field comes back with the typed
    /// text (the view reopens it when this returns false; `reopenOnFailure` when no view is waiting for the answer).
    private func performRename(_ item: FileItem, to newName: String, reopenOnFailure: Bool) -> Bool {
        do {
            let newURL = try Renamer.rename(item.url, to: newName)
            OperationCenter.shared.registerUndoRename(from: newURL, back: item.name)
            refreshSelecting(urls: [newURL])
            return true
        } catch {
            NSAlert.show(L10n.format("Couldn't rename “%@”.", "\(item.name)"), error.localizedDescription, in: window)
            if reopenOnFailure { itemView?.beginRename(named: item.name, text: newName) }
            return false
        }
    }

    /// Ends an open name field without renaming (the field editor's Escape).
    private func endRenameField() {
        guard itemView?.isEditingName == true, let editor = window?.firstResponder as? NSTextView else { return }
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }

    func itemViewTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL) {
        if InteractionHooks.drop.handle((self, kind, urls, folder)) { return }
        startTransfer(kind, urls, to: folder)
    }

    func itemViewSortChanged(_ order: FileSortOrder) { setSortOrder(order) }

    func itemViewKey(_ event: NSEvent) -> Bool {
        let registry = CommandRegistry.shared
        guard let command = registry.command(for: event, scope: .itemView) ?? registry.command(for: event, scope: .window) else { return false }
        let ctx = context(surface: .keyboard, sender: nil)
        guard command.isAvailable(ctx) else { return false }
        if command.isEnabled(ctx) { command.perform(ctx) } else { NSSound.beep() }
        return true
    }
}

extension BrowserWindowController: NavigationPaneDelegate {
    // MARK: - NavigationPaneDelegate

    func navigationPaneNavigate(to location: Location) { navigate(to: location) }
    func navigationPaneOpenInNewTab(_ location: Location) { openTab(location) }
    func navigationPaneTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL) {
        if InteractionHooks.drop.handle((self, kind, urls, folder)) { return }
        startTransfer(kind, urls, to: folder)
    }

    func navigationPaneMenu(for node: NavNode) -> NSMenu? {
        var ctx = context(surface: .treeContextMenu, sender: nil)
        ctx.selection = node.asItem.map { [$0] } ?? []
        ctx.targetFolder = node.url
        ctx.treeLocation = node.location
        return CommandDispatcher.shared.menu(for: .treeContextMenu, context: ctx)
    }
}

extension BrowserWindowController: LocationHost {
    // MARK: - LocationHost

    func openInNewTab(_ location: Location) { openTab(location) }
    func showStatusMessage(_ text: String?, isError: Bool) { statusBar.setMessage(text, isError: isError) }
    func reloadLocation() { reload() }
}
