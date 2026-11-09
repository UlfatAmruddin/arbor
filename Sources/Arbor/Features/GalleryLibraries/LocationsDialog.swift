import AppKit
import ArborCore

/// Folder list behind a library or the Gallery collection (FE-076, FE-075).
/// Applies on OK; Remove only edits the list, files stay put (FE-239).
final class LocationsDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode {
        case library(String)
        case gallery
    }

    struct Row: Equatable {
        var path: String
        var included: Bool
    }

    /// The library being edited, nil in Gallery. Its methods hold the folder rules, so the dialog has no copy of them.
    private var draft: LibraryDefinition?
    private var galleryRows: [Row] = []
    let sheet: NSWindow
    private let table = NSTableView()
    private let removeButton = NSButton(title: L10n.tr("Remove"), target: nil, action: nil)
    private let saveButton = NSButton(title: L10n.tr("Set save location"), target: nil, action: nil)
    private let moveUpButton = NSButton(title: L10n.tr("Move up"), target: nil, action: nil)
    private let moveDownButton = NSButton(title: L10n.tr("Move down"), target: nil, action: nil)
    private let optimizePopup = NSPopUpButton()
    private weak var parent: NSWindow?
    private static var open: [LocationsDialog] = []

    /// The dialog on screen, for scripts.
    static var current: LocationsDialog? { open.last }

    init(mode: Mode) {
        let height: CGFloat
        switch mode {
        case .library(let name):
            draft = LibraryStore.definition(name) ?? LibraryDefinition(name: name, folders: [])
            height = 460   // room for the Optimize row and the move buttons
        case .gallery:
            galleryRows = GalleryPrefs.collection.sources.map { Row(path: $0.path, included: $0.included) }
            height = 400
        }
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    var title: String {
        if let draft { return L10n.format("%@ Library Locations", "\(draft.name)") }
        return L10n.tr("Gallery Locations")
    }

    private var isLibrary: Bool { draft != nil }

    private var rows: [Row] { draft?.folders.map { Row(path: $0, included: true) } ?? galleryRows }

    private var saveLocation: String? { draft?.saveLocation }

    // MARK: Layout

    private func build() {
        sheet.title = title
        let content = ThemeBackgroundView(Theme.contentBackground)
        let heading = NSTextField(labelWithString: isLibrary ? L10n.tr("Change how this library gathers its contents")
                                                             : L10n.tr("Choose the folders that Gallery shows"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = Theme.primaryText
        let info = NSTextField(wrappingLabelWithString: isLibrary
            ? L10n.tr("When you include a folder in a library, the files appear in the library, but continue to be stored in their original locations. Removing a folder from the library doesn't delete it or its files.")
            : L10n.tr("Photos and videos in these folders and their subfolders appear in Gallery. Files stay where they are; removing a folder from the collection doesn't delete anything. Photos libraries are never scanned."))
        info.font = Theme.bodyFont
        info.textColor = Theme.secondaryText
        let listTitle = NSTextField(labelWithString: isLibrary ? L10n.tr("Library locations") : L10n.tr("Gallery locations"))
        listTitle.font = Theme.bodyFont
        listTitle.textColor = Theme.primaryText

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .plain
        table.backgroundColor = Theme.contentBackground
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(listTitle.stringValue)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: L10n.tr("Add…"), target: self, action: #selector(addFolder(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeFolder(_:))
        saveButton.target = self
        saveButton.action = #selector(setSaveLocation(_:))
        moveUpButton.target = self
        moveUpButton.action = #selector(moveUp(_:))
        moveDownButton.target = self
        moveDownButton.action = #selector(moveDown(_:))
        let restore = NSButton(title: L10n.tr("Restore defaults"), target: self, action: #selector(restoreDefaults(_:)))
        restore.isHidden = !hasDefaults
        let side = NSStackView(views: isLibrary ? [add, removeButton, saveButton, moveUpButton, moveDownButton] : [add, removeButton])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 8
        side.translatesAutoresizingMaskIntoConstraints = false
        side.arrangedSubviews.forEach { ($0 as? NSButton)?.widthAnchor.constraint(equalToConstant: 140).isActive = true }

        let ok = NSButton(title: L10n.tr("OK"), target: self, action: #selector(confirm(_:)))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: L10n.tr("Cancel"), target: self, action: #selector(dismiss(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [restore, NSView(), ok, cancel])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        [ok, cancel].forEach { $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true }

        let stack = NSStackView(views: [heading, info, listTitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let optimize = makeOptimizeRow()
        for v in [stack, scroll, side, optimize, bottom] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: optimize.topAnchor, constant: isLibrary ? -12 : 0),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            optimize.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            optimize.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            optimize.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -16),
            side.topAnchor.constraint(equalTo: scroll.topAnchor),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        sheet.contentView = content
        updateButtons()
        checkAvailability()
    }

    /// Libraries only; an empty row in Gallery keeps one set of constraints.
    private func makeOptimizeRow() -> NSView {
        guard isLibrary else {
            let empty = NSView()
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 0).isActive = true
            return empty
        }
        let label = NSTextField(labelWithString: L10n.tr("Optimize this library for:"))
        label.font = Theme.bodyFont
        label.textColor = Theme.primaryText
        for option in FolderTemplate.allCases {
            optimizePopup.addItem(withTitle: option.title)
            optimizePopup.lastItem?.representedObject = option.rawValue
        }
        optimizePopup.target = self
        optimizePopup.action = #selector(optimizeChanged(_:))
        optimizePopup.setAccessibilityLabel(label.stringValue)
        selectTemplateInPopup()
        let row = NSStackView(views: [label, optimizePopup])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func selectTemplateInPopup() {
        if let template = draft?.template, let index = FolderTemplate.allCases.firstIndex(of: template) { optimizePopup.selectItem(at: index) }
    }

    private var libraryDefaults: LibraryDefinition? {
        draft.flatMap { LibraryLogic.defaultDefinition(named: $0.name, home: LibraryStore.home) }
    }

    /// A custom library has no original folders to go back to.
    private var hasDefaults: Bool { !isLibrary || libraryDefaults != nil }

    func present(in window: NSWindow?) {
        Self.open.append(self)
        parent = window
        if let window {
            window.beginSheet(sheet) { _ in }
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    private func close() {
        if let parent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        Self.open.removeAll { $0 === self }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let url = URL(fileURLWithPath: entry.path)
        let icon = NSImageView(image: IconProvider.shared.folderIcon(IconProvider.shared.folderKind(for: url), size: 32))
        let title = NSMutableAttributedString(string: url.lastPathComponent,
                                              attributes: [.font: Theme.bodyFont, .foregroundColor: Theme.primaryText])
        var notes: [String] = []
        if isLibrary, entry.path == saveLocation { notes.append(L10n.tr("Default save location")) }
        if missing.contains(entry.path) { notes.append(L10n.tr("Not available")) }
        if !isLibrary, !entry.included { notes.append(L10n.tr("Turned off in Collection")) }
        if !notes.isEmpty {
            title.append(NSAttributedString(string: "   " + notes.joined(separator: " · "),
                                            attributes: [.font: Theme.statusFont, .foregroundColor: Theme.secondaryText]))
        }
        let name = NSTextField(labelWithAttributedString: title)
        name.lineBreakMode = .byTruncatingTail
        let detail = entry.path
        let sub = NSTextField(labelWithString: detail)
        sub.font = Theme.statusFont
        sub.textColor = Theme.secondaryText
        sub.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let cell = NSStackView(views: [icon, text])
        cell.spacing = 10
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        let row = table.selectedRow
        removeButton.isEnabled = row >= 0
        saveButton.isEnabled = row >= 0 && rows[row].path != saveLocation
        moveUpButton.isEnabled = row > 0
        moveDownButton.isEnabled = row >= 0 && row < rows.count - 1
    }

    private func reload() {
        table.reloadData()
        updateButtons()
        checkAvailability()
    }

    /// Folders missing right now, checked off-main (volumes may be slow or offline).
    private var missing = Set<String>()

    private func checkAvailability() {
        let paths = rows.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            DispatchQueue.main.async {
                guard let self, gone != self.missing else { return }
                self.missing = gone
                self.table.reloadData()
            }
        }
    }

    // MARK: Editing (also used by scripts)

    @discardableResult
    func add(_ url: URL) -> Bool {
        let path = Location.normalizedKey(url)
        if GalleryScanRules.isExcluded(path: path) {
            NSAlert.show(L10n.format("“%@” can't be included.", "\(url.lastPathComponent)"),
                         L10n.tr("Photos libraries are managed by the Photos app and are never scanned. Choose a regular folder instead."),
                         in: sheet)
            return false
        }
        let added = isLibrary ? addToDraft(url) : addToGallery(path)
        if added { reload() }
        return added
    }

    private func addToDraft(_ url: URL) -> Bool {
        let outcome = draft?.add(url)
        if outcome == .full {
            NSAlert.show(L10n.format("A library can include up to %@ folders.", "\(LibraryLogic.maxFolders)"),
                         L10n.tr("Remove a folder from this library, then try again."), in: sheet)
        }
        return outcome == .added
    }

    private func addToGallery(_ path: String) -> Bool {
        guard !galleryRows.contains(where: { $0.path == path }) else { return false }
        galleryRows.append(Row(path: path, included: true))
        return true
    }

    func remove(_ url: URL) {
        if isLibrary {
            draft?.remove(url)
        } else {
            let path = Location.normalizedKey(url)
            galleryRows.removeAll { $0.path == path }
        }
        reload()
    }

    func setSave(_ url: URL) {
        draft?.setSaveLocation(url)
        reload()
    }

    func move(_ url: URL, by offset: Int) {
        draft?.move(url, by: offset)
        reload()
        let path = Location.normalizedKey(url)
        if let row = rows.firstIndex(where: { $0.path == path }) { table.selectRowIndexes([row], byExtendingSelection: false) }
    }

    func setTemplate(_ value: FolderTemplate) {
        draft?.template = value
        selectTemplateInPopup()
    }

    func restore() {
        if isLibrary {
            guard let original = libraryDefaults else { return }
            draft = original
            selectTemplateInPopup()
        } else {
            galleryRows = GalleryCollection.defaults(home: FileManager.default.homeDirectoryForCurrentUser).sources.map { Row(path: $0.path, included: true) }
        }
        reload()
    }

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.tr("Include folder")
        if let draft {
            panel.message = L10n.format("Include a folder in the “%@” library", draft.name)
        } else {
            panel.message = L10n.tr("Add a folder to Gallery")
        }
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let self else { return }
            panel.urls.forEach { self.add($0) }
        }
    }

    @objc private func removeFolder(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        remove(URL(fileURLWithPath: rows[row].path))
    }

    @objc private func setSaveLocation(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        setSave(URL(fileURLWithPath: rows[row].path))
    }

    @objc private func moveUp(_ sender: Any?) { moveSelected(by: -1) }
    @objc private func moveDown(_ sender: Any?) { moveSelected(by: 1) }

    private func moveSelected(by offset: Int) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        move(URL(fileURLWithPath: rows[row].path), by: offset)
    }

    @objc private func optimizeChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let value = FolderTemplate(rawValue: raw) { setTemplate(value) }
    }

    @objc private func restoreDefaults(_ sender: Any?) { restore() }

    @objc func confirm(_ sender: Any?) {
        if let draft {
            guard commit(draft) else { return }
        } else {
            GalleryPrefs.collection = GalleryCollection(sources: galleryRows.map {
                GallerySource(URL(fileURLWithPath: $0.path), included: $0.included)
            })
        }
        close()
    }

    /// False keeps the dialog open so the edits aren't lost.
    private func commit(_ library: LibraryDefinition) -> Bool {
        do {
            try LibraryActions.commit(library)
            return true
        } catch {
            NSAlert.show(L10n.tr("The library couldn't be saved."), error.localizedDescription, in: sheet)
            return false
        }
    }

    @objc func dismiss(_ sender: Any?) { close() }

    var restoreIsOffered: Bool { hasDefaults }

    var debugSummary: String {
        "dialog \(title): " + rows.map { ($0.path == saveLocation ? "*" : "") + $0.path + ($0.included ? "" : " (off)") }.joined(separator: " | ")
            + "  optimize=\((draft?.template ?? .generalItems).rawValue) restore=\(restoreIsOffered)"
    }
}
