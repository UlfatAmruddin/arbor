import AppKit
import ArborCore

/// What a Properties window is about: one file, folder, app/package or drive, or a multi-selection.
enum PropertiesSubject {
    case file, folder, package, volume, multiple
}

/// Items of one Properties window as read at open, plus pending edits. Apply writes only diffs and detects
/// changes by other apps meanwhile (FE-150, spec §11.3).
final class PropertiesModel {
    struct Entry {
        var url: URL
        var item: FileItem
        var original: EditableState
        var edited: EditableState
    }

    private(set) var entries: [Entry]
    let subject: PropertiesSubject
    /// Called after edits or reloads so tabs refresh and the window enables Apply.
    var observers: [() -> Void] = []
    /// Extra apply steps owned by tabs (folder template, icon, volume name): error message to stop, nil when done.
    var extraAppliers: [String: () -> String?] = [:]
    var extraChanges: Set<String> = [] { didSet { notify() } }
    /// Apply's last step when it is too slow for the main thread (rewriting a file); ends with an error message or nil.
    var slowApplier: ((_ done: @escaping (String?) -> Void) -> Void)?
    var hasSlowChange = false { didSet { notify() } }
    private var isRunningSlowApply = false

    init(items: [FileItem]) {
        entries = items.map { item in
            let state = (try? EditableState.read(item.url)) ?? EditableState(name: item.name)
            return Entry(url: item.url, item: item, original: state, edited: state)
        }
        if items.count > 1 {
            subject = .multiple
        } else if let item = items.first {
            if Location.isVolumeRoot(item.url) { subject = .volume }
            else if item.isPackage { subject = .package }
            else if item.isFolder { subject = .folder }
            else { subject = .file }
        } else {
            subject = .multiple
        }
    }

    var single: Entry? { entries.count == 1 ? entries[0] : nil }
    var urls: [URL] { entries.map(\.url) }
    var hasChanges: Bool { entries.contains { PropertyChangePlan(url: $0.url, original: $0.original, edited: $0.edited).hasChanges } || !extraChanges.isEmpty || hasSlowChange }

    func notify() { observers.forEach { $0() } }

    /// Applies to every item (multi-selection check boxes) or the single item.
    func edit(_ body: (inout EditableState, EditableState) -> Void) {
        for i in entries.indices { body(&entries[i].edited, entries[i].original) }
        notify()
    }

    func tri(_ key: KeyPath<EditableState, Bool>, edited: Bool = true) -> TriState {
        TriState(entries.map { edited ? $0.edited[keyPath: key] : $0.original[keyPath: key] })
    }

    // MARK: External changes

    /// Untouched fields follow the disk; edited fields changed on disk (and missing items) are returned.
    @discardableResult
    func refreshFromDisk() -> (conflicts: [(name: String, fields: [EditableField])], missing: [String]) {
        var conflicts: [(String, [EditableField])] = []
        var missing: [String] = []
        for i in entries.indices {
            guard FileOps.exists(entries[i].url), let current = try? EditableState.read(entries[i].url) else {
                missing.append(entries[i].original.name)
                continue
            }
            let plan = PropertyChangePlan(url: entries[i].url, original: entries[i].original, edited: entries[i].edited)
            let clashing = plan.conflicts(with: current)
            if !clashing.isEmpty { conflicts.append((entries[i].original.name, clashing)) }
            let edited = Set(plan.changedFields)
            var merged = entries[i].edited
            for field in EditableField.allCases where !edited.contains(field) { merged.copy(field, from: current) }
            entries[i].edited = merged
            var original = entries[i].original
            for field in EditableField.allCases where !clashing.contains(field) && !edited.contains(field) { original.copy(field, from: current) }
            entries[i].original = original
            if let fresh = FileItem(url: entries[i].url) { entries[i].item = fresh }
        }
        notify()
        return (conflicts, missing)
    }

    // MARK: Apply

    /// Asks first when another app changed an edited field; `completion(true)` when all written, failures in a sheet.
    func apply(in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard !isRunningSlowApply else { completion(false); return }
        let check = refreshFromDisk()
        if !check.missing.isEmpty {
            PropertiesWindowController.present(message: L10n.format("“%@” can't be found.", "\(check.missing[0])"),
                                               info: "It may have been moved, renamed or deleted by another app. Close this window and try again.",
                                               window: window)
            completion(false)
            return
        }
        if let first = check.conflicts.first {
            let alert = NSAlert()
            alert.messageText = L10n.format("“%@” was changed by another app while this window was open.", "\(first.name)")
            alert.informativeText = L10n.format("Changed: %@. Apply your changes anyway and replace those values?", "\(first.fields.map(\.title).joined(separator: ", "))")
            alert.addButton(withTitle: L10n.tr("Apply Anyway"))
            alert.addButton(withTitle: L10n.tr("Cancel"))
            PropertiesWindowController.present(alert, window: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { completion(false); return }
                self.finish(self.write(in: window), window: window, completion)
            }
            return
        }
        finish(write(in: window), window: window, completion)
    }

    private func finish(_ written: Bool, window: NSWindow?, _ completion: @escaping (Bool) -> Void) {
        guard written, hasSlowChange, let slowApplier else { completion(written); return }
        isRunningSlowApply = true
        slowApplier { [weak self] message in
            self?.isRunningSlowApply = false
            if let message {
                PropertiesWindowController.present(message: L10n.tr("Some properties couldn't be changed."), info: message, window: window)
            }
            completion(message == nil)
        }
    }

    private func write(in window: NSWindow?) -> Bool {
        var failures: [String] = []
        for i in entries.indices {
            let plan = PropertyChangePlan(url: entries[i].url, original: entries[i].original, edited: entries[i].edited)
            guard plan.hasChanges else { continue }
            let oldURL = entries[i].url
            do {
                let newURL = try plan.apply()
                entries[i].url = newURL
                if newURL != oldURL {
                    OperationCenter.shared.registerUndoRename(from: newURL, back: oldURL.lastPathComponent)
                }
                PropertiesFeature.itemsChanged(old: oldURL, new: newURL)
            } catch let error as PropertyApplyError {
                entries[i].url = error.url
                failures.append("“\(entries[i].original.name)”: \(error.localizedDescription)")
            } catch {
                failures.append("“\(entries[i].original.name)”: \(error.localizedDescription)")
            }
        }
        for key in extraChanges.sorted() {
            if let message = extraAppliers[key]?() { failures.append(message) } else { extraChanges.remove(key) }
        }
        // Start over from what's on disk now.
        for i in entries.indices {
            if let state = try? EditableState.read(entries[i].url) {
                entries[i].original = state
                entries[i].edited = state
            }
            if let fresh = FileItem(url: entries[i].url) { entries[i].item = fresh }
        }
        notify()
        if !failures.isEmpty {
            PropertiesWindowController.present(message: L10n.tr("Some properties couldn't be changed."), info: failures.joined(separator: "\n"), window: window)
            return false
        }
        return true
    }
}

extension EditableState {
    mutating func copy(_ field: EditableField, from other: EditableState) {
        switch field {
        case .name: name = other.name
        case .locked: locked = other.locked
        case .hidden: hidden = other.hidden
        case .mode: mode = other.mode
        case .tags: tags = other.tags
        case .comment: comment = other.comment
        case .quarantine: quarantined = other.quarantined
        }
    }
}

