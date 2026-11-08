import AppKit
import ArborCore

/// Empty, Restore, permanent Delete and Properties for the Trash (FE-077, FE-090).
/// Wording follows Explorer's Recycle Bin dialogs (windows11-reference.md §3.4, §9.5) with the Mac name "Trash".
enum TrashActions {
    static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: Confirmation

    /// "Are you sure you want to permanently delete this file?" / "…this folder?" / "…these 12 items?"
    static func permanentQuestion(count: Int, single: FileItem?) -> String {
        if count == 1, let single {
            return L10n.format("Are you sure you want to permanently delete this %@?", "\(single.isFolder ? "folder" : "file")")
        }
        return L10n.format("Are you sure you want to permanently delete these %@ items?", "\(count.formatted())")
    }

    /// Yes / No like Explorer; No is the default button so Return never destroys anything.
    static func confirmPermanent(_ items: [FileItem], total: Int? = nil, window: NSWindow?, then: @escaping () -> Void) {
        let count = total ?? items.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = TrashIcon.image(full: true, size: 64)
        alert.messageText = permanentQuestion(count: count, single: count == 1 ? items.first : nil)
        var info = ""
        if count == 1, let item = items.first {
            info = describe(item)
        }
        alert.informativeText = info.isEmpty ? L10n.tr("This can't be undone.") : info + L10n.tr("\n\nThis can't be undone.")
        let yes = alert.addButton(withTitle: L10n.tr("Yes"))
        let no = alert.addButton(withTitle: L10n.tr("No"))
        yes.hasDestructiveAction = true
        yes.keyEquivalent = ""
        no.keyEquivalent = "\r"
        present(alert, in: window) { if $0 == .alertFirstButtonReturn { then() } }
    }

    static func describe(_ item: FileItem) -> String {
        let entry = TrashStore.entry(for: item.url)
        var lines = [item.name]
        lines.append(L10n.format("Original Location: %@", "\(entry?.record?.originalFolder ?? "Unknown")"))
        lines.append(L10n.format("Date Deleted: %@", "\(entry?.dateDeleted.map(dates.string(from:)) ?? "Unknown")"))
        if !item.isFolder, let size = item.size { lines.append(L10n.format("Size: %@", "\(StatusText.bytes(size))")) }
        return lines.joined(separator: "\n")
    }

    static func present(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        AlertSheets.present(alert, in: window, completion: completion)
    }

    // MARK: Delete (permanent) and Empty

    static func deletePermanently(_ items: [FileItem], window: BrowserWindowController?) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let next = window?.neighborURL(after: items)
        confirmPermanent(items, window: window?.window) {
            remove(items.map(\.url), window: window) { removed in
                window?.refreshSelecting(urls: next.map { [$0] } ?? [])
                if removed > 0 { window?.statusBar.setMessage(L10n.format("%@ permanently deleted.", "\(StatusText.items(removed))")) }
            }
        }
    }

    /// Empty Trash: everything in every Trash folder Arbor can read, after confirming the count.
    static func emptyTrash(window: BrowserWindowController?) {
        window?.statusBar.setMessage(L10n.tr("Checking the Trash…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = TrashStore.list(includeHidden: true)
            DispatchQueue.main.async {
                TrashStore.adopt(listing)
                switch listing {
                case .denied:
                    window?.statusBar.setMessage(nil)
                    let alert = NSAlert()
                    alert.messageText = L10n.tr("Arbor can't empty the Trash without Full Disk Access.")
                    alert.informativeText = L10n.tr("macOS protects the Trash folder. Turn on Arbor in System Settings → Privacy & Security → Full Disk Access, or empty the Trash in Finder.")
                    alert.addButton(withTitle: L10n.tr("Open Settings"))
                    alert.addButton(withTitle: L10n.tr("Cancel"))
                    present(alert, in: window?.window) { if $0 == .alertFirstButtonReturn { SystemOpen.open(TrashAccessPage.settingsURL) } }
                case .items(let entries, _, _):
                    window?.statusBar.setMessage(nil)
                    guard !entries.isEmpty else { window?.statusBar.setMessage(L10n.tr("The Trash is already empty.")); return }
                    confirmPermanent(entries.map(\.item), window: window?.window) {
                        remove(entries.map(\.item.url), window: window) { removed in
                            if window?.location == .trash { window?.reload() }
                            window?.statusBar.setMessage(removed > 0 ? "The Trash was emptied (\(StatusText.items(removed)))." : nil)
                        }
                    }
                }
            }
        }
    }

    /// Removes items off the main thread, forgets their journal records, and reports failures per item.
    private static func remove(_ urls: [URL], window: BrowserWindowController?, completion: @escaping (Int) -> Void) {
        let names = Dictionary(urls.map { ($0, TrashStore.displayName($0)) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .userInitiated).async {
            var removed: [URL] = []
            var failures: [String] = []
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed.append(url)
                } catch {
                    failures.append("• \(names[url] ?? url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            TrashJournal.shared.remove(removed)
            DispatchQueue.main.async {
                TrashStore.noteChanged()
                completion(removed.count)
                if !failures.isEmpty {
                    NSAlert.show(failures.count == 1 ? "1 item couldn't be deleted." : "\(failures.count) items couldn't be deleted.",
                                 failures.prefix(10).joined(separator: "\n") + (failures.count > 10 ? "\n…and \(failures.count - 10) more." : ""),
                                 in: window?.window)
                }
            }
        }
    }

    // MARK: Restore

    static func canRestore(_ items: [FileItem]) -> Bool {
        items.contains { TrashStore.entry(for: $0.url)?.record != nil }
    }

    /// Restores items Arbor knows the origin of. Conflicts ask Keep both / Skip; missing parent
    /// folders are recreated (like Windows). Items of unknown origin are reported, never guessed.
    static func restore(_ items: [FileItem], window: BrowserWindowController?) {
        let candidates = items.map {
            RestoreCandidate(trashedURL: $0.url, isFolder: $0.isFolder, record: TrashStore.entry(for: $0.url)?.record)
        }
        let plans = TrashRestorePlanner.plan(candidates, exists: FileOps.exists)
        let unknown = plans.filter { if case .unknownOrigin = $0 { return true }; return false }.count
        resolveConflicts(plans[...], decided: [], window: window?.window, applyAll: nil) { moves, skipped, cancelled in
            guard !cancelled else { return }
            perform(moves, skipped: skipped, unknown: unknown, window: window)
        }
    }

    typealias Move = (from: URL, to: URL, parents: [URL])

    private static func resolveConflicts(_ rest: ArraySlice<RestorePlan>, decided: [Move], window: NSWindow?, applyAll: Bool?,
                                         skipped: Int = 0, completion: @escaping ([Move], Int, Bool) -> Void) {
        guard let plan = rest.first else { completion(decided, skipped, false); return }
        let remaining = rest.dropFirst()
        switch plan {
        case .unknownOrigin:
            resolveConflicts(remaining, decided: decided, window: window, applyAll: applyAll, skipped: skipped, completion: completion)
        case .restore(let from, let to, let parents):
            resolveConflicts(remaining, decided: decided + [(from, to, parents)], window: window, applyAll: applyAll,
                             skipped: skipped, completion: completion)
        case .conflict(let from, let to, let keepBoth, let parents):
            func decide(_ keep: Bool, all: Bool?) {
                let next = keep ? decided + [(from, keepBoth, parents)] : decided
                resolveConflicts(remaining, decided: next, window: window, applyAll: all, skipped: skipped + (keep ? 0 : 1),
                                 completion: completion)
            }
            if let applyAll { decide(applyAll, all: applyAll); return }
            let isFolder = (try? from.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = (isFolder ? L10n.format("The destination already has a folder named “%@”.", to.lastPathComponent) : L10n.format("The destination already has a file named “%@”.", to.lastPathComponent))
            alert.informativeText = L10n.format("Restoring to “%@”.\n\nKeep both restores this one as “%@”. Skip leaves it in the Trash.", "\(to.deletingLastPathComponent().path)", "\(keepBoth.lastPathComponent)")
            alert.addButton(withTitle: L10n.tr("Keep Both"))
            alert.addButton(withTitle: L10n.tr("Skip"))
            alert.addButton(withTitle: L10n.tr("Cancel"))
            if remaining.contains(where: { if case .conflict = $0 { return true }; return false }) {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = L10n.tr("Do this for all current items")
            }
            present(alert, in: window) { response in
                let all = alert.suppressionButton?.state == .on
                switch response {
                case .alertFirstButtonReturn: decide(true, all: all ? true : nil)
                case .alertSecondButtonReturn: decide(false, all: all ? false : nil)
                default: completion(decided, skipped, true)
                }
            }
        }
    }

    private static func perform(_ moves: [Move], skipped: Int, unknown: Int, window: BrowserWindowController?) {
        DispatchQueue.global(qos: .userInitiated).async {
            var restored: [URL] = []
            var failures: [String] = []
            for move in moves {
                do {
                    restored.append(try TrashRestorer.restore(from: move.from, to: move.to, missingParents: move.parents,
                                                              journal: TrashJournal.shared))
                } catch {
                    failures.append("• \(move.to.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                if !restored.isEmpty { registerUndoRestore(restored) }
                TrashStore.noteChanged()
                if window?.location == .trash { window?.reload() }
                var parts: [String] = []
                if !restored.isEmpty { parts.append("\(StatusText.items(restored.count)) restored") }
                if skipped > 0 { parts.append("\(skipped) skipped") }
                if !parts.isEmpty { window?.statusBar.setMessage(parts.joined(separator: ", ") + ".") }
                if unknown > 0 {
                    NSAlert.show(unknown == 1 ? "1 item can't be restored." : "\(unknown) items can't be restored.",
                                 "Arbor only knows where items came from if Arbor moved them to the Trash. To put back items deleted in Finder, use Finder's Put Back.",
                                 style: .informational, in: window?.window)
                } else if !failures.isEmpty {
                    NSAlert.show(L10n.tr("Some items couldn't be restored."), failures.prefix(10).joined(separator: "\n"), in: window?.window)
                }
            }
        }
    }

    /// Undo of a restore moves the items back to the Trash (and redo restores them again).
    private static func registerUndoRestore(_ urls: [URL]) {
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { center in
            var pairs: [(original: URL, trashed: URL)] = []
            for url in urls where FileOps.exists(url) {
                if let trashed = try? SystemTrash.trash(url) { pairs.append((url, trashed)) }
            }
            // Redo restores again; every later Undo/Redo round keeps the name "Restore".
            center.registerUndoTrash(pairs, actionName: "Restore")
        }
        center.undoManager.setActionName(L10n.tr("Restore"))
    }

    // MARK: Properties

    /// Properties of selected Trash items: original location, date deleted and size (folders are
    /// measured only now, on request, off the main thread).
    static func showItemProperties(_ items: [FileItem], window: BrowserWindowController?) {
        guard !items.isEmpty else { return }
        window?.statusBar.setMessage(L10n.tr("Calculating size…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let sizes = items.map { measure($0.url) }
            DispatchQueue.main.async {
                window?.statusBar.setMessage(nil)
                let total = sizes.reduce(0) { $0 + $1.bytes }
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.icon = IconProvider.shared.icon(for: items[0], size: 48)
                if items.count == 1, let item = items.first {
                    let entry = TrashStore.entry(for: item.url)
                    alert.messageText = L10n.format("“%@” Properties", "\(item.name)")
                    var lines = [L10n.format("Type: %@", "\(item.typeDescription)"),
                                 "Original Location: \(entry?.record?.originalFolder ?? "Unknown")",
                                 "Date Deleted: \(entry?.dateDeleted.map(dates.string(from:)) ?? "Unknown")",
                                 "Size: \(sizeText(total))"]
                    if item.isFolder { lines.append(L10n.format("Contains: %@ files", "\(sizes[0].files.formatted())")) }
                    if let modified = item.modified { lines.append(L10n.format("Date Modified: %@", "\(dates.string(from: modified))")) }
                    lines.append(L10n.format("In: %@", "\(item.url.deletingLastPathComponent().path)"))
                    if entry?.record == nil {
                        lines.append("\nArbor didn't move this item to the Trash, so its original location isn't known.")
                    }
                    alert.informativeText = lines.joined(separator: "\n")
                } else {
                    alert.messageText = L10n.format("%@ Properties", "\(StatusText.items(items.count))")
                    alert.informativeText = L10n.format("Size: %@\nFiles: %@", "\(sizeText(total))", "\(sizes.reduce(0) { $0 + $1.files }.formatted())")
                }
                present(alert, in: window?.window) { _ in }
            }
        }
    }

    /// Trash properties: every Trash folder with its item count, size and the volume's free space.
    /// macOS has no per-volume maximum size or "remove files immediately" setting to change, so
    /// none is offered (DEC-019).
    static func showTrashProperties(window: BrowserWindowController?) {
        window?.statusBar.setMessage(L10n.tr("Calculating size…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = TrashStore.folders()
            var lines: [String] = []
            for folder in folders {
                let free = (try? (folder.volumeURL ?? folder.url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
                let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path))?.filter { $0 != ".DS_Store" && $0 != ".localized" }
                var line = "\(folder.volumeName) — \(folder.url.path)\n"
                if let items {
                    let size = measure(folder.url)
                    line += "    \(StatusText.items(items.count)), \(StatusText.bytes(size.bytes)) used"
                } else if FileManager.default.fileExists(atPath: folder.url.path) {
                    line += L10n.tr("    Contents can't be read (Full Disk Access is needed)")
                } else {
                    line += L10n.tr("    Empty")
                }
                if let free { line += "\n    Space available: \(StatusText.bytes(free))" }
                lines.append(line)
            }
            DispatchQueue.main.async {
                window?.statusBar.setMessage(nil)
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.icon = TrashIcon.image(full: TrashStore.isFull == true, size: 64)
                alert.messageText = L10n.tr("Trash Properties")
                alert.informativeText = lines.joined(separator: "\n\n")
                    + "\n\nmacOS manages the Trash size. To remove items automatically after 30 days, use Finder › Settings › Advanced."
                present(alert, in: window?.window) { _ in }
            }
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        "\(StatusText.bytes(bytes)) (\(bytes.formatted()) bytes)"
    }

    /// Logical size of a file, or of everything inside a folder. Called only on request.
    static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return (0, 0) }
        if values.isDirectory != true || values.isSymbolicLink == true { return (Int64(values.fileSize ?? 0), 1) }
        var bytes: Int64 = 0
        var files = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            bytes += Int64(v.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }
}

extension TrashStore {
    /// The name the list shows for a trashed item (falls back to the name on disk).
    static func displayName(_ url: URL) -> String { entry(for: url)?.item.name ?? url.lastPathComponent }
}
