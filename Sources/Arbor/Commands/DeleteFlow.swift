import AppKit
import ArborCore

/// The Trash and permanent-delete work behind both the base Delete commands and their replacement, which differ only in how they ask.
enum DeleteFlow {
    /// Moves `items` to the Trash. What can't go is explained; `askToDeletePermanently` gets the items a permanent delete could still remove, and why.
    static func moveToTrash(_ items: [FileItem], window: BrowserWindowController,
                            askToDeletePermanently: @escaping (_ items: [FileItem], _ reason: String) -> Void) {
        let nextSelection = window.neighborURL(after: items)
        var trashed: [(original: URL, trashed: URL)] = []
        var failed: [(item: FileItem, failure: TrashFailure)] = []
        for item in items {
            do {
                trashed.append((item.url, try SystemTrash.trash(item.url)))
            } catch {
                failed.append((item, SystemTrash.failure(error, for: item.url)))
            }
        }
        if !trashed.isEmpty {
            OperationCenter.shared.registerUndoTrash(trashed)
            window.statusBar.setMessage(L10n.format("%@ moved to the Trash. Press ⌘Z to undo.", "\(StatusText.items(trashed.count))"))
        }
        window.refreshSelecting(urls: nextSelection.map { [$0] } ?? [])

        // Never silently turn "move to Trash" into a permanent delete (spec §9.5).
        let deletable = failed.filter(\.failure.canDeletePermanently)
        let refused = failed.filter { !$0.failure.canDeletePermanently }
        let ask = { if !deletable.isEmpty { askToDeletePermanently(deletable.map(\.item), reasons(deletable.map(\.failure))) } }
        guard !refused.isEmpty else { return ask() }
        let alert = NSAlert()
        alert.messageText = cannotTrashTitle(refused.map(\.item))
        alert.informativeText = reasons(refused.map(\.failure))
        AlertSheets.present(alert, in: window.window) { _ in ask() }
    }

    static func cannotTrashTitle(_ items: [FileItem]) -> String {
        items.count == 1 ? L10n.format("“%@” can't be moved to the Trash.", items[0].name)
                         : L10n.format("%@ items can't be moved to the Trash.", "\(items.count)")
    }

    private static func reasons(_ failures: [TrashFailure]) -> String {
        Set(failures.map(\.reason)).sorted().joined(separator: "\n")
    }

    /// Deletes off the main thread, then refreshes (selecting `next`) and reports what couldn't be removed.
    static func deletePermanently(_ items: [FileItem], selecting next: URL?, window: BrowserWindowController?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let failures = items.compactMap { item -> String? in
                let error = FileOps.removePermanently(item.url)
                return error == 0 ? nil : "• \(item.name): \(FileOps.removalFailureReason(errno: error))"
            }
            DispatchQueue.main.async {
                guard let window else { return }
                window.refreshSelecting(urls: next.map { [$0] } ?? [])
                if !failures.isEmpty {
                    NSAlert.show(L10n.tr("Some items couldn't be deleted."), failures.joined(separator: "\n"), in: window.window)
                }
            }
        }
    }
}
