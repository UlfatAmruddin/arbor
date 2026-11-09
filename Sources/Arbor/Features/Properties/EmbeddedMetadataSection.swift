import AppKit
import ArborCore

/// The Details tab's rows for properties stored inside an image (FE-152); offers only what a rewrite can keep.
final class EmbeddedMetadataSection {
    private let model: PropertiesModel
    private var snapshot: EmbeddedSnapshot?
    private let titleField = SheetTextField()
    private let descriptionField = SheetTextField()
    private let dateField = SheetTextField(placeholder: L10n.tr("YYYY-MM-DD HH:MM:SS"))
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
        for (field, control) in [(EmbeddedField.title, titleField), (.description, descriptionField), (.dateTaken, dateField)] {
            control.field.setAccessibilityLabel(field.label)
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
        titleField.stringValue = fresh.values[.title] ?? ""
        descriptionField.stringValue = fresh.values[.description] ?? ""
        dateField.stringValue = fresh.values[.dateTaken].map { EmbeddedDate.display(fromExif: $0) ?? $0 } ?? ""
        ratingPopup.selectItem(at: fresh.values[.rating].flatMap { Int($0) } ?? 0)
    }

    func addRows(addGroup: (String) -> Void, addRow: (String, NSView) -> Void, addNote: (String) -> Void) {
        guard let snapshot else { return }
        let offered = EmbeddedField.allCases.filter { snapshot.editable.contains($0) || snapshot.values[$0] != nil }
        guard !offered.isEmpty else { return }
        addGroup(L10n.tr("Stored in this image"))
        for field in offered {
            let view: NSView
            if snapshot.editable.contains(field) {
                view = field == .rating ? ratingPopup : textField(field)
            } else {
                let value = readOnlyText(field)
                let label = SheetLabel.make(value, selectable: true)
                label.toolTip = value
                view = label
            }
            addRow(field.label, view)
        }
        if let blocked = snapshot.blocked {
            addNote(blocked.localizedDescription)
        } else {
            addNote(L10n.tr("Saved inside the file without changing the picture itself. The previous version goes to the Trash."))
        }
    }

    private func textField(_ field: EmbeddedField) -> SheetTextField {
        switch field {
        case .title: return titleField
        case .description: return descriptionField
        default: return dateField
        }
    }

    private func readOnlyText(_ field: EmbeddedField) -> String {
        let value = snapshot?.values[field] ?? ""
        if field == .dateTaken { return EmbeddedDate.display(fromExif: value) ?? value }
        return value
    }

    private var typed: [EmbeddedField: String] {
        [.title: titleField.stringValue, .description: descriptionField.stringValue, .dateTaken: dateField.stringValue,
         .rating: String(max(ratingPopup.indexOfSelectedItem, 0))]
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try EmbeddedMetadataEditor.save(edits, over: current) }
            DispatchQueue.main.async {
                switch result {
                case .success(let step):
                    Self.registerUndo(step)
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
    private static func registerUndo(_ step: EmbeddedMetadataEditor.Revert) {
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { _ in
            do {
                let opposite = try EmbeddedMetadataEditor.revert(step)
                registerUndo(opposite)
                IconProvider.shared.purgeFileIcons()
                PropertiesFeature.itemsChanged(old: step.url, new: step.url)
            } catch {
                NSAlert.show(L10n.tr("The image's previous properties couldn't be put back."), error.localizedDescription, in: NSApp.keyWindow)
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
        switch field {
        case .title: titleField.stringValue = value
        case .description: descriptionField.stringValue = value
        case .dateTaken: dateField.stringValue = value
        case .rating: ratingPopup.selectItem(at: Int(value) ?? 0)
        }
        editsChanged()
    }

    private final class PopupTarget: NSObject {
        var onChange: (() -> Void)?
        @objc func changed() { onChange?() }
    }
}

extension EmbeddedMetadataSection {
    /// propembedded:title=Hello | description=… | rating=3 | date=2024-03-07 14:30:00 | touch=1 (another app changed the file).
    static func registerScriptSteps() {
        DebugScript.registerStep("propembedded") { arg, _ in
            guard let controller = PropertiesWindowController.front,
                  let tab = controller.tabs.compactMap({ $0 as? DetailsTab }).first else { return 0.5 }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return 0.5 }
            switch parts[0] {
            case "title": tab.embedded.setForScript(.title, parts[1])
            case "description": tab.embedded.setForScript(.description, parts[1])
            case "rating": tab.embedded.setForScript(.rating, parts[1])
            case "date": tab.embedded.setForScript(.dateTaken, parts[1])
            case "touch":
                if let url = controller.model.single?.url { _ = try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path) }
            default: NSLog("DebugScript: unknown embedded property \(parts[0])")
            }
            return 0.5
        }
    }
}
