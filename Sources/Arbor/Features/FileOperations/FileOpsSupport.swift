import AppKit
import ArborCore

extension Prefs {
    private static func setFileOps(_ value: Bool, _ key: String) {
        store.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["key": key])
    }

    /// Off by default like Windows 11 (windows11-reference §9.5); permanent deletion always asks.
    static var displayDeleteConfirmation: Bool {
        get { store.bool(forKey: "displayDeleteConfirmation") }
        set { setFileOps(newValue, "displayDeleteConfirmation") }
    }

    /// On by default like Windows: folders merge silently, the prompt is opt-in (DEC-fileops-3).
    static var hideFolderMergeConflicts: Bool {
        get { store.object(forKey: "hideFolderMergeConflicts") as? Bool ?? true }   // Windows default: on
        set { setFileOps(newValue, "hideFolderMergeConflicts") }
    }

    /// The progress window's "More details" state, remembered like Explorer.
    static var fileOpsMoreDetails: Bool {
        get { store.bool(forKey: "fileOpsMoreDetails") }
        set { setFileOps(newValue, "fileOpsMoreDetails") }
    }
}

/// Where job journals live and how jobs are configured.
enum FileOpsEnvironment {
    /// `ARBOR_JOURNAL_DIR`, else a private folder in headless runs, else ~/Library/Application Support/Arbor/Jobs.
    static let journalDirectory: URL = {
        let env = Automation.environment
        if let path = env["ARBOR_JOURNAL_DIR"] { return URL(fileURLWithPath: path) }
        if AppDelegate.isHeadless {
            return TemporaryFiles.headlessFolder("journal")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Arbor/Jobs")
    }()

    static func makeJournal(_ kind: TransferKind, sources: [URL], destination: URL) -> JobJournal? {
        try? JobJournal(directory: journalDirectory, kind: kind, sources: sources, destination: destination)
    }

    /// `ARBOR_TRANSFER_THROTTLE` (bytes/s) slows headless runs so scripts can photograph and pause a job.
    static var transferOptions: FileTransfer.Options {
        var options = FileTransfer.Options()
        if AppDelegate.isHeadless, let text = Automation.environment["ARBOR_TRANSFER_THROTTLE"], let limit = Int64(text), limit > 0 {
            options.bytesPerSecondLimit = limit
            options.allowClone = false
        }
        return options
    }
}

// MARK: - Undo Copy (FE-129)

extension OperationCenter {
    /// Trashes only copies unchanged since made (same inode, size, dates; folders: every entry);
    /// anything changed is left alone and named. Redo puts them back.
    func registerUndoCopy(_ copies: [(url: URL, fingerprint: ItemFingerprint)]) {
        guard !copies.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { center in
            // Redo must be registered during this undo; the box is filled when the background check ends.
            let box = UndoCopyResult()
            center.undoManager.registerUndo(withTarget: center) { c in c.redoCopy(box) }
            center.undoManager.setActionName(L10n.tr("Copy"))
            DispatchQueue.global(qos: .userInitiated).async {
                let plan = CopyUndo.plan(copies)
                var trashed: [(original: URL, trashed: URL, fingerprint: ItemFingerprint)] = []
                var failed: [String] = []
                for url in plan.unchanged {
                    guard let print = copies.first(where: { $0.url == url })?.fingerprint else { continue }
                    do { trashed.append((url, try SystemTrash.trash(url), print)) } catch { failed.append(url.lastPathComponent) }
                }
                DispatchQueue.main.async {
                    box.trashed = trashed
                    box.done = true
                    let refused = plan.changed.map(\.lastPathComponent) + failed
                    if let window = BrowserWindowController.active {
                        window.statusBar.setMessage(trashed.isEmpty ? L10n.tr("Nothing was undone.") :
                            L10n.format("Undo Copy: %@ moved to the Trash.", StatusText.items(trashed.count)))
                        window.reload()
                    }
                    if !refused.isEmpty {
                        NSAlert.show(refused.count == 1 ? L10n.tr("1 copy wasn't removed.") : L10n.format("%@ copies weren't removed.", StatusText.number(refused.count)),
                                     L10n.tr("They changed after they were copied, so undoing could lose work:\n") + refused.joined(separator: ", "),
                                     in: NSApp.keyWindow)
                    }
                }
            }
        }
        undoManager.setActionName(L10n.tr("Copy"))
    }

    private func redoCopy(_ box: UndoCopyResult) {
        guard box.done else { return }
        var restored: [(url: URL, fingerprint: ItemFingerprint)] = []
        var skipped: [String] = []
        for item in box.trashed {
            guard FileOps.exists(item.trashed), !FileOps.exists(item.original) else { skipped.append(item.original.lastPathComponent); continue }
            do {
                try FileManager.default.moveItem(at: item.trashed, to: item.original)
                restored.append((item.original, ItemFingerprint.of(item.original) ?? item.fingerprint))
            } catch { skipped.append(item.original.lastPathComponent) }
        }
        if !skipped.isEmpty {
            NSAlert.show(L10n.tr("Some copies couldn't be put back."),
                         L10n.tr("Their location is taken or they're no longer in the Trash:\n") + skipped.joined(separator: ", "), in: NSApp.keyWindow)
        }
        BrowserWindowController.active?.reload()
        registerUndoCopy(restored)
    }
}

final class UndoCopyResult {
    var trashed: [(original: URL, trashed: URL, fingerprint: ItemFingerprint)] = []
    var done = false
}
