import AppKit
import UniformTypeIdentifiers
import ArborCore

/// Explorer's Details tab (FE-151, FE-152, FE-161). Finder tags and comments, stored beside the file, are editable
/// in their own group; so are the properties inside an image that a lossless rewrite can change (`EmbeddedMetadataSection`).
final class DetailsTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("Details")
    let view: NSView
    private let model: PropertiesModel
    private weak var controller: PropertiesWindowController?
    private let page = SheetPage()
    private let list = SheetScrollList()
    private let tagsField = SheetTextField(placeholder: L10n.tr("Add a tag"))
    private let commentField = SheetTextField(placeholder: L10n.tr("Add comments"))
    private lazy var removeLink: NSButton = {
        let b = NSButton(title: L10n.tr("Remove Properties and Personal Information"), target: self, action: #selector(removeProperties))
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [.foregroundColor: SheetColors.accent, .font: SheetColors.font])
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    private var rows: [MetadataRow] = []
    private var loadToken = 0
    private var loadedURL: URL?
    let embedded: EmbeddedMetadataSection

    init(model: PropertiesModel, controller: PropertiesWindowController) {
        self.model = model
        self.controller = controller
        embedded = EmbeddedMetadataSection(model: model)
        view = page
        embedded.onNeedsReload = { [weak self] in self?.load() }
        tagsField.onChange = { [weak self] text in
            let tags = FinderMetadata.parseTags(text)
            self?.model.edit { edited, _ in edited.tags = tags }
        }
        commentField.onChange = { [weak self] text in self?.model.edit { edited, _ in edited.comment = text } }
        build()
        load()
    }

    private func build() {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let p = SheetLabel.make(L10n.tr("Property"), secondary: true)
        let v = SheetLabel.make(L10n.tr("Value"), secondary: true)
        let line = SheetSeparator()
        for x in [p, v, line] as [NSView] { header.addSubview(x) }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 24),
            p.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            p.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            v.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 150),
            v.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        let box = SheetBox()
        for x in [header, list] as [NSView] { box.addSubview(x) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            list.topAnchor.constraint(equalTo: header.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        page.addSubview(box)
        page.addSubview(removeLink)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: page.topAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            box.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            box.bottomAnchor.constraint(equalTo: removeLink.topAnchor, constant: -8),
            removeLink.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            removeLink.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -10),
        ])
        removeLink.isHidden = !(model.single.map { MetadataRemoval.canRemove(from: $0.url) } ?? false)
    }

    private func load() {
        guard let entry = model.single else { return }
        loadedURL = entry.url
        loadToken += 1
        let token = loadToken
        let url = entry.url, item = entry.item
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            var rows = SpotlightMetadata.rows(for: url, isImage: type?.conforms(to: .image) ?? false)
            rows.removeAll { $0.label == L10n.tr("Where from") }
            let whereFrom = FinderMetadata.whereFroms(of: url)
            if !whereFrom.isEmpty { rows.append(MetadataRow(group: L10n.tr("Origin"), label: L10n.tr("Where from"), value: whereFrom.joined(separator: "; "))) }
            if item.isPackage, let bundle = BundleInfo.read(url) {
                let app: [(String, String?)] = [("Product name", bundle.name), ("Product version", bundle.version), ("Build", bundle.build),
                                                ("Bundle identifier", bundle.identifier), ("Minimum macOS", bundle.minimumSystem),
                                                ("Architecture", bundle.architectureText), ("Copyright", bundle.copyright)]
                rows += app.compactMap { label, value in value.map { MetadataRow(group: L10n.tr("Application"), label: label, value: $0) } }
            }
            rows += Self.fileRows(url: url, item: item)
            let snapshot = EmbeddedSnapshot.read(url)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.embedded.show(snapshot)
                let replaced = self.embedded.replacedRowLabels
                self.rows = rows.filter { !replaced.contains($0.label) }
                self.rebuild()
            }
        }
    }

    static func fileRows(url: URL, item: FileItem) -> [MetadataRow] {
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        var attributes: [String] = []
        if let flags = try? FileFlags.read(url) {
            if flags.isLocked { attributes.append("Locked") }
            if flags.isHidden || url.lastPathComponent.hasPrefix(".") { attributes.append("Hidden") }
        }
        if FinderMetadata.isQuarantined(url) { attributes.append("Quarantined") }
        let security = try? ItemSecurity.read(url)
        var rows: [MetadataRow] = [
            MetadataRow(group: L10n.tr("File"), label: L10n.tr("Name"), value: url.lastPathComponent),
            MetadataRow(group: L10n.tr("File"), label: L10n.tr("Item type"), value: item.isSymbolicLink ? item.typeDescription
                        : ExplorerTypeName.name(localized: v?.localizedTypeDescription ?? item.typeDescription, typeIdentifier: nil,
                                                isFolder: item.isFolder, windowsShortcut: item.windowsShortcutKind)),
            MetadataRow(group: L10n.tr("File"), label: L10n.tr("Folder path"), value: url.deletingLastPathComponent().path),
        ]
        if let d = v?.creationDate { rows.append(MetadataRow(group: L10n.tr("File"), label: L10n.tr("Date created"), value: PropertyFormat.shortDate(d))) }
        if let d = v?.contentModificationDate { rows.append(MetadataRow(group: L10n.tr("File"), label: L10n.tr("Date modified"), value: PropertyFormat.shortDate(d))) }
        if !item.isFolder && !item.isPackage {
            rows.append(MetadataRow(group: L10n.tr("File"), label: L10n.tr("Size"), value: PropertyFormat.adaptiveSize(SizeScanner.entrySizes(url).size)))
        }
        rows.append(MetadataRow(group: L10n.tr("File"), label: L10n.tr("Attributes"), value: attributes.isEmpty ? L10n.tr("None") : attributes.joined(separator: ", ")))
        if let s = security { rows.append(MetadataRow(group: L10n.tr("File"), label: L10n.tr("Owner"), value: L10n.format("%@ (%@)", s.ownerName, s.groupName))) }
        rows.append(MetadataRow(group: L10n.tr("File"), label: L10n.tr("Computer"), value: Host.current().localizedName ?? "This Mac"))
        return rows
    }

    func reload() {
        guard let entry = model.single else { return }
        if !isEditing(tagsField) { tagsField.stringValue = FinderMetadata.tagText(entry.edited.tags) }
        if !isEditing(commentField) { commentField.stringValue = entry.edited.comment }
        if entry.url != loadedURL, loadedURL != nil { load() }
    }

    private func isEditing(_ f: SheetTextField) -> Bool {
        f.field.currentEditor() != nil
    }

    private func rebuild() {
        list.removeAll()
        var group = ""
        func addGroup(_ name: String) {
            let label = SheetLabel.make(name, bold: true)
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let line = SheetSeparator()
            row.addSubview(label)
            row.addSubview(line)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 26),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
                line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
            list.add(row)
        }
        func addRow(_ label: String, _ value: NSView) {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let l = SheetLabel.make(label, secondary: true)
            row.addSubview(l)
            row.addSubview(value)
            value.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
                l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                l.widthAnchor.constraint(equalToConstant: 132),
                l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                value.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 150),
                value.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(greaterThanOrEqualTo: value.heightAnchor, constant: 2),
            ])
            list.add(row)
        }
        // Finder's own metadata first: it is what the user can edit here.
        addGroup(L10n.tr("Finder tags and comments"))
        addRow(L10n.tr("Tags"), tagsField)
        addRow(L10n.tr("Comments"), commentField)
        func addNote(_ text: String) {
            let note = SheetLabel.wrapping(text, small: true)
            let noteRow = NSView()
            noteRow.translatesAutoresizingMaskIntoConstraints = false
            noteRow.addSubview(note)
            NSLayoutConstraint.activate([
                note.topAnchor.constraint(equalTo: noteRow.topAnchor, constant: 2),
                note.bottomAnchor.constraint(equalTo: noteRow.bottomAnchor, constant: -2),
                note.leadingAnchor.constraint(equalTo: noteRow.leadingAnchor, constant: 14),
                note.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor, constant: -8),
            ])
            list.add(noteRow)
        }
        addNote(L10n.tr("Stored by macOS alongside the file, not inside it. Other computers and some cloud services may not keep them."))
        embedded.addRows(addGroup: addGroup, addRow: addRow, addNote: addNote)
        for row in rows {
            if row.group != group {
                group = row.group
                addGroup(group)
            }
            let value = SheetLabel.make(row.value, selectable: true)
            value.toolTip = row.value
            addRow(row.label, value)
        }
        if !rows.contains(where: { !["File", "Application", "Origin"].contains($0.group) }) {
            let none = SheetLabel.wrapping(L10n.tr("This file has no embedded properties that Spotlight or ImageIO can read."), small: true)
            let r = NSView()
            r.translatesAutoresizingMaskIntoConstraints = false
            r.addSubview(none)
            NSLayoutConstraint.activate([
                none.topAnchor.constraint(equalTo: r.topAnchor, constant: 8),
                none.bottomAnchor.constraint(equalTo: r.bottomAnchor, constant: -4),
                none.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14),
                none.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -8),
            ])
            list.add(r)
        }
        reload()
    }

    @objc private func removeProperties() {
        guard let entry = model.single else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Remove Properties")
        let copyName = NameRules.duplicateName(for: entry.url.lastPathComponent, treatAsFolder: false) {
            FileManager.default.fileExists(atPath: entry.url.deletingLastPathComponent().appendingPathComponent($0).path)
        }
        alert.informativeText = L10n.format("Create a copy with all possible properties removed?\n\nCamera details, dates, location (GPS), authors, keywords and copyright are left out. The copy is saved as “%@”. The original isn't changed.", "\(copyName)")
        alert.addButton(withTitle: L10n.tr("Create Copy"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        let window = controller?.window
        PropertiesWindowController.present(alert, window: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let copy = try MetadataRemoval.createCleanCopy(of: entry.url)
                PropertiesFeature.itemsChanged(old: copy, new: copy)
            } catch {
                DispatchQueue.main.async {
                    PropertiesWindowController.present(message: L10n.tr("The copy couldn't be created."), info: error.localizedDescription, window: window)
                }
            }
        }
    }

    var debugText: String {
        var lines = ["tags: \(tagsField.stringValue)", "comments: \(commentField.stringValue)",
                     "remove link: \(removeLink.isHidden ? "hidden" : "shown")"]
        lines += embedded.debugLines
        lines += rows.map { "\($0.group) / \($0.label): \($0.value)" }
        return lines.joined(separator: "\n")
    }

    func setTagsForScript(_ text: String) {
        tagsField.stringValue = text
        tagsField.onChange?(text)
    }

    func setCommentForScript(_ text: String) {
        commentField.stringValue = text
        commentField.onChange?(text)
    }

    func removePropertiesForScript() { removeProperties() }
}
