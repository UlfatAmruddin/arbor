import AppKit
import ArborCore

/// The Details tab's rows for properties stored inside an image, audio file or document (FE-152); offers only what a rewrite can keep.
final class EmbeddedMetadataSection {
    private let model: PropertiesModel
    private var snapshot: EmbeddedSnapshot?
    private let textFields: [EmbeddedField: SheetTextField] = {
        var fields = Dictionary(uniqueKeysWithValues: EmbeddedField.allCases.filter { $0 != .rating }.map { ($0, SheetTextField()) })
        fields[.dateTaken] = SheetTextField(placeholder: L10n.tr("YYYY-MM-DD HH:MM:SS"))
        fields[.year] = SheetTextField(placeholder: L10n.tr("YYYY"))
        fields[.track] = SheetTextField(placeholder: L10n.tr("3 or 3/12"))
        return fields
    }()
    private let ratingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ratingTarget = PopupTarget()
    /// Reads the file again after a write or refusal.
    var onNeedsReload: (() -> Void)?

    init(model: PropertiesModel) {
        self.model = model
        ratingPopup.font = SheetColors.font
        ratingPopup.addItem(withTitle: L10n.tr("Not rated"))
        ratingPopup.addItems(withTitles: (1...5).compactMap { SpotlightMetadata.format(NSNumber(value: $0), .rating) })
        ratingPopup.target = ratingTarget
        ratingPopup.action = #selector(PopupTarget.changed)
        ratingTarget.onChange = { [weak self] in self?.editsChanged() }
        ratingPopup.setAccessibilityLabel(EmbeddedField.rating.label)
        for (field, control) in textFields {
            control.field.setAccessibilityLabel(field == .track ? L10n.tr("Track number") : field.label)
            control.onChange = { [weak self] _ in self?.editsChanged() }
        }
        model.slowApplier = { [weak self] done in
            guard let self else { done(nil); return }
            self.save(done)
        }
    }

    /// Labels of rows this section replaces, so Spotlight's copies aren't shown beside them.
    var replacedRowLabels: Set<String> {
        guard let snapshot else { return [] }
        if snapshot.support.isAudio || snapshot.support.isDocument {
            var labels = EmbeddedField.allCases.filter { snapshot.editable.contains($0) || snapshot.values[$0] != nil }.map(\.label)
            // Spotlight files an audio file's artist under its generic name.
            if labels.contains(EmbeddedField.artist.label) { labels.append(L10n.tr("Authors")) }
            return Set(labels)
        }
        var labels: [String] = []
        if snapshot.support.fields.contains(.title) { labels.append(L10n.tr("Title")) }
        if snapshot.support.fields.contains(.description) { labels.append(L10n.tr("Comments")) }
        if snapshot.support.fields.contains(.rating) { labels.append(L10n.tr("Rating")) }
        return Set(labels)
    }

    /// Called on the main thread with the result of a background read.
    func show(_ fresh: EmbeddedSnapshot?) {
        snapshot = fresh
        model.hasSlowChange = false
        guard let fresh else { return }
        for (field, control) in textFields { control.stringValue = fresh.values[field] ?? "" }
        textFields[.dateTaken]?.stringValue = fresh.values[.dateTaken].map { EmbeddedDate.display(fromExif: $0) ?? $0 } ?? ""
        ratingPopup.selectItem(at: fresh.values[.rating].flatMap { Int($0) } ?? 0)
    }

    func addRows(addGroup: (String) -> Void, addRow: (String, NSView) -> Void, addNote: (String) -> Void) {
        guard let snapshot else { return }
        let offered = EmbeddedField.allCases.filter { snapshot.editable.contains($0) || snapshot.values[$0] != nil }
        let wording = Self.wording(snapshot.support)
        guard !offered.isEmpty || (!wording.isImage && snapshot.blocked != nil) else { return }
        addGroup(wording.group)
        for field in offered {
            let view: NSView
            if snapshot.editable.contains(field) {
                view = field == .rating ? ratingPopup : textFields[field] ?? NSView()
            } else {
                let value = readOnlyText(field)
                let label = SheetLabel.make(value, selectable: true)
                label.toolTip = value
                view = label
            }
            addRow(field.label, view)
        }
        addNote(snapshot.blocked?.localizedDescription ?? wording.note)
    }

    /// What the rows are called for each kind of file.
    private static func wording(_ support: EmbeddedSupport) -> (group: String, note: String, undoFailure: String, isImage: Bool) {
        if support.isAudio {
            return (L10n.tr("Stored in this audio file"), L10n.tr("Saved inside the file without changing the sound itself. The previous version goes to the Trash."),
                    L10n.tr("The audio file's previous properties couldn't be put back."), false)
        }
        if support.isDocument {
            return (L10n.tr("Stored in this document"), L10n.tr("Saved inside the file without changing its contents. The previous version goes to the Trash."),
                    L10n.tr("The document's previous properties couldn't be put back."), false)
        }
        return (L10n.tr("Stored in this image"), L10n.tr("Saved inside the file without changing the picture itself. The previous version goes to the Trash."),
                L10n.tr("The image's previous properties couldn't be put back."), true)
    }

    private func readOnlyText(_ field: EmbeddedField) -> String {
        let value = snapshot?.values[field] ?? ""
        if field == .dateTaken { return EmbeddedDate.display(fromExif: value) ?? value }
        return value
    }

    private var typed: [EmbeddedField: String] {
        var values = textFields.mapValues(\.stringValue)
        values[.rating] = String(max(ratingPopup.indexOfSelectedItem, 0))
        return values
    }

    private func editsChanged() {
        guard let snapshot else { return }
        // Text that can't be saved still counts as a change, so Apply reports it instead of ignoring it.
        let changed = (try? EmbeddedEdits.make(from: typed, snapshot: snapshot).isEmpty == false) ?? true
        if model.hasSlowChange != changed { model.hasSlowChange = changed }
    }

    private func save(_ done: @escaping (String?) -> Void) {
        guard let snapshot, let url = model.single?.url else { done(nil); return }
        let edits: [EmbeddedField: String]
        do { edits = try EmbeddedEdits.make(from: typed, snapshot: snapshot) } catch {
            done(error.localizedDescription)
            return
        }
        guard !edits.isEmpty else { done(nil); return }
        // A rename earlier in this Apply may have moved the file.
        let current = snapshot.moved(to: url)
        let undoFailure = Self.wording(snapshot.support).undoFailure
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try EmbeddedMetadataEditor.save(edits, over: current) }
            DispatchQueue.main.async {
                switch result {
                case .success(let step):
                    Self.registerUndo(step, failure: undoFailure)
                    IconProvider.shared.purgeFileIcons()
                    PropertiesFeature.itemsChanged(old: step.url, new: step.url)
                    self?.model.hasSlowChange = false
                    self?.onNeedsReload?()
                    done(nil)
                case .failure(let error):
                    if (error as? EmbeddedFailure)?.fileMayHaveChanged == true { self?.onNeedsReload?() }
                    done(error.localizedDescription)
                }
            }
        }
    }

    /// Undo puts the previous version back from the Trash; Redo swaps again. Both refuse if either file changed since.
    private static func registerUndo(_ step: EmbeddedMetadataEditor.Revert, failure: String) {
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { _ in
            do {
                let opposite = try EmbeddedMetadataEditor.revert(step)
                registerUndo(opposite, failure: failure)
                IconProvider.shared.purgeFileIcons()
                PropertiesFeature.itemsChanged(old: step.url, new: step.url)
            } catch {
                NSAlert.show(failure, error.localizedDescription, in: NSApp.keyWindow)
            }
        }
        center.undoManager.setActionName(L10n.tr("Edit Properties"))
    }

    // MARK: Scripted checks

    var debugLines: [String] {
        guard let snapshot else { return ["embedded: none"] }
        var lines = ["embedded type: \(snapshot.typeIdentifier)",
                     "embedded editable: \(EmbeddedField.allCases.filter { snapshot.editable.contains($0) }.map(\.rawValue).joined(separator: ","))"]
        if let blocked = snapshot.blocked { lines.append("embedded blocked: \(blocked.localizedDescription)") }
        lines += EmbeddedField.allCases.map { "embedded \($0.rawValue): \(snapshot.values[$0] ?? "")" }
        return lines
    }

    func setForScript(_ field: EmbeddedField, _ value: String) {
        if field == .rating { ratingPopup.selectItem(at: Int(value) ?? 0) } else { textFields[field]?.stringValue = value }
        editsChanged()
    }

    private final class PopupTarget: NSObject {
        var onChange: (() -> Void)?
        @objc func changed() { onChange?() }
    }
}

extension EmbeddedMetadataSection {
    /// propembedded:<field>=<value> (title, subject, author, keywords, category, description, rating, date, artist, album, year, track, genre, comment)
    /// | touch=1 (another app changed the file).
    static func registerScriptSteps() {
        DebugScript.registerStep("propembedded") { arg, _ in
            guard let controller = PropertiesWindowController.front,
                  let tab = controller.tabs.compactMap({ $0 as? DetailsTab }).first else { return 0.5 }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return 0.5 }
            switch parts[0] {
            case "date": tab.embedded.setForScript(.dateTaken, parts[1])
            case "touch":
                if let url = controller.model.single?.url { _ = try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path) }
            default:
                if let field = EmbeddedField(rawValue: parts[0]) { tab.embedded.setForScript(field, parts[1]) } else { NSLog("DebugScript: unknown embedded property \(parts[0])") }
            }
            return 0.5
        }
    }
}
