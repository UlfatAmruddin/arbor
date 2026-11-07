import AppKit
import ArborCore

/// "Documents Library Locations" / "Gallery Locations": the folder list behind a library or the Gallery
/// collection, with Add…, Remove, Set save location and Restore defaults (FE-076, FE-075).
/// Changes apply on OK. Removing a folder only removes it from the list; its files stay where they are (FE-239).
final class LocationsDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode {
        case library(String)
        case gallery
    }

    struct Row: Equatable {
        var path: String
        var included: Bool
    }

    private let mode: Mode
    private(set) var rows: [Row]
    private(set) var saveLocation: String?
    let sheet: NSWindow
    private let table = NSTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let saveButton = NSButton(title: "Set save location", target: nil, action: nil)
    private weak var parent: NSWindow?
    private static var open: [LocationsDialog] = []

    /// The dialog on screen, for scripted checks.
    static var current: LocationsDialog? { open.last }

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .library(let name):
            let library = LibraryStore.definition(name) ?? LibraryDefinition(name: name, folders: [])
            rows = library.folders.map { Row(path: $0, included: true) }
            saveLocation = library.saveLocation
        case .gallery:
            rows = GalleryPrefs.collection.sources.map { Row(path: $0.path, included: $0.included) }
            saveLocation = nil
        }
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    var title: String {
        switch mode {
        case .library(let name): return "\(name) Library Locations"
        case .gallery: return "Gallery Locations"
        }
    }

    private var isLibrary: Bool { if case .library = mode { return true }; return false }

    // MARK: Layout

    private func build() {
        sheet.title = title
        let content = ThemeBackgroundView(Theme.contentBackground)
        let heading = NSTextField(labelWithString: isLibrary ? "Change how this library gathers its contents"
                                                             : "Choose the folders that Gallery shows")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = Theme.primaryText
        let info = NSTextField(wrappingLabelWithString: isLibrary
            ? "When you include a folder in a library, the files appear in the library, but continue to be stored in their original locations. Removing a folder from the library doesn't delete it or its files."
            : "Photos and videos in these folders and their subfolders appear in Gallery. Files stay where they are; removing a folder from the collection doesn't delete anything. Photos libraries are never scanned.")
        info.font = Theme.bodyFont
        info.textColor = Theme.secondaryText
        let listTitle = NSTextField(labelWithString: isLibrary ? "Library locations" : "Gallery locations")
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

        let add = NSButton(title: "Add…", target: self, action: #selector(addFolder(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeFolder(_:))
        saveButton.target = self
        saveButton.action = #selector(setSaveLocation(_:))
        let restore = NSButton(title: "Restore defaults", target: self, action: #selector(restoreDefaults(_:)))
        let side = NSStackView(views: isLibrary ? [add, removeButton, saveButton] : [add, removeButton])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 8
        side.translatesAutoresizingMaskIntoConstraints = false
        side.arrangedSubviews.forEach { ($0 as? NSButton)?.widthAnchor.constraint(equalToConstant: 140).isActive = true }

        let ok = NSButton(title: "OK", target: self, action: #selector(confirm(_:)))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss(_:)))
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
        for v in [stack, scroll, side, bottom] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
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
        if isLibrary, entry.path == saveLocation { notes.append("Default save location") }
        if missing.contains(entry.path) { notes.append("Not available") }
        if !isLibrary, !entry.included { notes.append("Turned off in Collection") }
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
    }

    private func reload() {
        table.reloadData()
        updateButtons()
        checkAvailability()
    }

    /// Folders that don't exist right now, checked off the main thread (they may be on a slow or
    /// disconnected volume).
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
            NSAlert.show("“\(url.lastPathComponent)” can't be included.",
                         "Photos libraries are managed by the Photos app and are never scanned. Choose a regular folder instead.",
                         in: sheet)
            return false
        }
        guard !rows.contains(where: { $0.path == path }) else { return false }
        rows.append(Row(path: path, included: true))
        if isLibrary, saveLocation == nil { saveLocation = path }
        reload()
        return true
    }

    func remove(_ url: URL) {
        let path = Location.normalizedKey(url)
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        rows.remove(at: index)
        if saveLocation == path { saveLocation = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].path }
        reload()
    }

    func setSave(_ url: URL) {
        let path = Location.normalizedKey(url)
        guard rows.contains(where: { $0.path == path }) else { return }
        saveLocation = path
        reload()
    }

    func restore() {
        switch mode {
        case .library(let name):
            let original = LibraryLogic.defaultDefinition(named: name, home: FileManager.default.homeDirectoryForCurrentUser)
            rows = original?.folders.map { Row(path: $0, included: true) } ?? []
            saveLocation = original?.saveLocation
        case .gallery:
            rows = GalleryCollection.defaults(home: FileManager.default.homeDirectoryForCurrentUser).sources.map { Row(path: $0.path, included: true) }
        }
        reload()
    }

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Include folder"
        panel.message = isLibrary ? "Include a folder in \(title.replacingOccurrences(of: " Locations", with: ""))" : "Add a folder to Gallery"
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

    @objc private func restoreDefaults(_ sender: Any?) { restore() }

    @objc func confirm(_ sender: Any?) {
        switch mode {
        case .library(let name):
            var library = LibraryDefinition(name: name, folders: rows.map { URL(fileURLWithPath: $0.path) })
            if let saveLocation { library.setSaveLocation(URL(fileURLWithPath: saveLocation)) }
            LibraryStore.update(library)
        case .gallery:
            GalleryPrefs.collection = GalleryCollection(sources: rows.map {
                GallerySource(URL(fileURLWithPath: $0.path), included: $0.included)
            })
        }
        close()
    }

    @objc func dismiss(_ sender: Any?) { close() }

    var debugSummary: String {
        "dialog \(title): " + rows.map { ($0.path == saveLocation ? "*" : "") + $0.path + ($0.included ? "" : " (off)") }.joined(separator: " | ")
    }
}
