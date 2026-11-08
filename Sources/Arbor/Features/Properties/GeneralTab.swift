import AppKit
import UniformTypeIdentifiers
import ArborCore

/// Facts shown on the General tab, read off the main thread (a network item can be slow).
struct GeneralInfo {
    var typeText = ""
    var contentType: UTType?
    var openWith: URL?
    var location = ""
    var created: Date?
    var modified: Date?
    var accessed: Date?
    var fileSize: Int64 = 0
    var fileOnDisk: Int64 = 0
    var bundle: BundleInfo?
    var quarantined = false
    var dotHidden = false

    static func read(_ entry: PropertiesModel.Entry) -> GeneralInfo {
        let url = entry.url
        var info = GeneralInfo()
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
                                                  .contentTypeKey, .localizedTypeDescriptionKey])
        info.contentType = v?.contentType
        let kind = entry.item.isSymbolicLink ? entry.item.typeDescription
            : ExplorerTypeName.name(localized: v?.localizedTypeDescription ?? entry.item.typeDescription,
                                    typeIdentifier: v?.contentType?.identifier, isFolder: entry.item.isFolder)
        let ext = entry.item.isFolder ? "" : url.pathExtension
        info.typeText = ext.isEmpty ? kind : "\(kind) (.\(ext))"
        info.location = url.deletingLastPathComponent().path
        info.created = v?.creationDate
        info.modified = v?.contentModificationDate
        info.accessed = v?.contentAccessDate
        if !entry.item.isFolder && !entry.item.isPackage {
            let sizes = SizeScanner.entrySizes(url)
            info.fileSize = sizes.size
            info.fileOnDisk = sizes.onDisk
            info.openWith = NSWorkspace.shared.urlForApplication(toOpen: url)
            info.quarantined = FinderMetadata.isQuarantined(url)
        }
        if entry.item.isPackage { info.bundle = BundleInfo.read(url) }
        info.dotHidden = url.lastPathComponent.hasPrefix(".")
        return info
    }
}

/// Explorer's General tab for a file, folder, app/package or several items (FE-150, FE-156).
final class GeneralTab: PropertiesTab, PropertiesTabDebug {
    let title = "General"
    let view: NSView
    private let model: PropertiesModel
    private weak var controller: PropertiesWindowController?
    private let page = SheetPage()
    private let form = SheetForm()

    private let icon = fixedImage(nil, 32)
    private let nameField = SheetTextField()
    private let headerLabel = SheetLabel.make("")
    private let typeValue = SheetLabel.make("")
    private let openWithIcon = fixedImage(nil, 16)
    private let openWithName = SheetLabel.make("")
    private lazy var changeButton = SheetButton("Change…") { [weak self] _ in self?.changeApp() }
    private let versionValue = SheetLabel.make("")
    private let locationValue = SheetLabel.make("", selectable: true)
    private let sizeValue = SheetLabel.make("")
    private let onDiskValue = SheetLabel.make("")
    private let containsValue = SheetLabel.make("")
    private lazy var stopButton = SheetButton("Stop") { [weak self] _ in self?.stopScan() }
    private let createdValue = SheetLabel.make("")
    private let modifiedValue = SheetLabel.make("")
    private let accessedValue = SheetLabel.make("")
    private lazy var readOnly = SheetCheckbox("Read-only") { [weak self] box in self?.setLocked(box.state) }
    private lazy var hidden = SheetCheckbox("Hidden") { [weak self] box in self?.setHidden(box.state) }
    private lazy var advanced = SheetButton("Advanced…") { [weak self] _ in self?.showAdvanced() }
    private let attributeNote = SheetLabel.wrapping("", small: true)
    private let securityNote = SheetLabel.wrapping("This file came from another computer. macOS may check it with Gatekeeper before it opens.", small: true)
    private lazy var unblock = SheetCheckbox("Unblock") { [weak self] box in
        self?.model.edit { edited, _ in edited.quarantined = box.state != .on }
    }
    private var securityRow: NSView?
    private var securitySeparator: NSView?
    private var openWithRow: NSView?
    private var versionRow: NSView?
    private var containsRow: NSView?
    private var accessedRow: NSView?
    private var modifiedRow: NSView?

    private var infos: [GeneralInfo] = []
    private var cancel: ScanCancellation?
    private var scannedURLs: [URL] = []
    private var totals = SizeTotals()
    private var scanning = false
    private var infoLoad = 0

    init(model: PropertiesModel, controller: PropertiesWindowController) {
        self.model = model
        self.controller = controller
        view = page
        build()
        loadInfo()
    }

    private var isMulti: Bool { model.subject == .multiple }
    private var needsScan: Bool { model.subject != .file }

    private func build() {
        nameField.onChange = { [weak self] text in self?.model.edit { edited, _ in edited.name = text } }
        let headerValue: NSView = isMulti ? headerLabel : nameField
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(icon)
        header.addSubview(headerValue)
        headerValue.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerValue.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: form.labelWidth + 4),
            headerValue.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerValue.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        form.add(header)
        form.separator()
        form.row(isMulti ? "Type:" : (model.subject == .file ? "Type of file:" : "Type:"), typeValue)
        if model.subject == .file {
            let openWith = hstack([openWithIcon, openWithName], spacing: 6)
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(openWith)
            row.addSubview(changeButton)
            NSLayoutConstraint.activate([
                openWith.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                openWith.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                openWith.trailingAnchor.constraint(lessThanOrEqualTo: changeButton.leadingAnchor, constant: -8),
                changeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                changeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 24),
            ])
            openWithRow = form.row("Opens with:", row)
        }
        if model.subject == .package { versionRow = form.row("Version:", versionValue) }
        form.separator()
        form.row("Location:", locationValue)
        form.row("Size:", sizeValue)
        form.row("Size on disk:", onDiskValue)
        if needsScan {
            let contains = NSView()
            contains.translatesAutoresizingMaskIntoConstraints = false
            contains.addSubview(containsValue)
            contains.addSubview(stopButton)
            stopButton.minWidth = 56
            NSLayoutConstraint.activate([
                containsValue.leadingAnchor.constraint(equalTo: contains.leadingAnchor),
                containsValue.centerYAnchor.constraint(equalTo: contains.centerYAnchor),
                containsValue.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -8),
                stopButton.trailingAnchor.constraint(equalTo: contains.trailingAnchor),
                stopButton.centerYAnchor.constraint(equalTo: contains.centerYAnchor),
                contains.heightAnchor.constraint(equalToConstant: 24),
            ])
            containsRow = form.row("Contains:", contains)
        }
        if !isMulti {
            form.separator()
            form.row("Created:", createdValue)
            if model.subject != .folder {
                modifiedRow = form.row("Modified:", modifiedValue)
                accessedRow = form.row("Accessed:", accessedValue)
            }
        }
        form.separator()
        let checks = NSStackView(views: [readOnly, hidden])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 8
        checks.translatesAutoresizingMaskIntoConstraints = false
        let attributes = NSView()
        attributes.translatesAutoresizingMaskIntoConstraints = false
        attributes.addSubview(checks)
        attributes.addSubview(advanced)
        NSLayoutConstraint.activate([
            checks.leadingAnchor.constraint(equalTo: attributes.leadingAnchor),
            checks.topAnchor.constraint(equalTo: attributes.topAnchor),
            checks.bottomAnchor.constraint(equalTo: attributes.bottomAnchor),
            advanced.trailingAnchor.constraint(equalTo: attributes.trailingAnchor),
            advanced.topAnchor.constraint(equalTo: attributes.topAnchor, constant: -3),
        ])
        form.row("Attributes:", attributes, alignTop: true)
        form.add(indented(attributeNote))
        if model.subject == .file {
            let unblockBox = NSView()
            unblockBox.translatesAutoresizingMaskIntoConstraints = false
            unblockBox.addSubview(securityNote)
            unblockBox.addSubview(unblock)
            NSLayoutConstraint.activate([
                securityNote.topAnchor.constraint(equalTo: unblockBox.topAnchor),
                securityNote.leadingAnchor.constraint(equalTo: unblockBox.leadingAnchor),
                securityNote.trailingAnchor.constraint(lessThanOrEqualTo: unblock.leadingAnchor, constant: -8),
                securityNote.bottomAnchor.constraint(equalTo: unblockBox.bottomAnchor),
                unblock.trailingAnchor.constraint(equalTo: unblockBox.trailingAnchor),
                unblock.topAnchor.constraint(equalTo: unblockBox.topAnchor),
            ])
            form.separator()
            securitySeparator = form.stack.arrangedSubviews.last
            securityRow = form.row("Security:", unblockBox, alignTop: true)
            securityRow?.isHidden = true
            securitySeparator?.isHidden = true
        }
        page.embed(form.stack)
        page.setAccessibilityLabel("General")
    }

    private func indented(_ v: NSView) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: form.labelWidth + 4),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    // MARK: Loading

    private func loadInfo() {
        let entries = model.entries
        infoLoad += 1
        let token = infoLoad
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let infos = entries.map(GeneralInfo.read)
            DispatchQueue.main.async {
                guard let self, token == self.infoLoad else { return }
                self.infos = infos
                self.reload()
            }
        }
        if needsScan, scannedURLs != model.urls { startScan() }
    }

    private func startScan() {
        cancel?.cancel()
        let token = ScanCancellation()
        cancel = token
        scannedURLs = model.urls
        scanning = true
        totals = SizeTotals()
        stopButton.isHidden = false
        let urls = model.urls
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = SizeScanner.scan(urls, cancel: token, interval: 0.15) { partial in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.cancel === token, !token.isCancelled else { return }
                    self.totals = partial
                    self.showSizes()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cancel === token else { return }
                self.totals = result
                self.scanning = false
                self.stopButton.isHidden = true
                self.showSizes(stopped: token.isCancelled)
            }
        }
    }

    private func stopScan() {
        cancel?.cancel()
    }

    func close() {
        cancel?.cancel()
        cancel = nil
    }

    // MARK: Showing

    func reload() {
        let entries = model.entries
        guard !entries.isEmpty else { return }
        if model.urls != scannedURLs, needsScan, !scanning, !scannedURLs.isEmpty { loadInfo() }
        if let single = model.single {
            icon.image = single.item.isFolder ? IconProvider.shared.icon(for: single.item, size: 32)
                                              : IconProvider.shared.fileIcon(single.url, size: 32)
            if nameField.window?.firstResponder !== nameField.field.currentEditor() || nameField.field.currentEditor() == nil {
                if nameField.stringValue != single.edited.name { nameField.stringValue = single.edited.name }
            }
            nameField.isEditable = model.subject != .volume
        } else {
            icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            headerLabel.stringValue = SelectionSummary(items: entries.map(\.item)).countText
        }
        let summary = SelectionSummary(items: entries.map(\.item))
        if isMulti {
            typeValue.stringValue = summary.typeText
            locationValue.stringValue = summary.locationText
        } else if let info = infos.first {
            typeValue.stringValue = model.subject == .package && info.contentType?.conforms(to: .application) == true
                ? "Application (.\(entries[0].url.pathExtension))" : info.typeText
            locationValue.stringValue = info.location
            locationValue.toolTip = info.location
            if let app = info.openWith {
                openWithIcon.image = NSWorkspace.shared.icon(forFile: app.path)
                openWithName.stringValue = displayName(of: app).replacingOccurrences(of: ".app", with: "")
            } else {
                openWithIcon.image = nil
                openWithName.stringValue = "No app is set to open this file"
            }
            if let bundle = info.bundle {
                versionValue.stringValue = [bundle.version, bundle.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                if versionValue.stringValue.isEmpty { versionValue.stringValue = "Unknown" }
            }
            createdValue.stringValue = info.created.map { PropertyFormat.longDate($0) } ?? "Unknown"
            modifiedValue.stringValue = info.modified.map { PropertyFormat.longDate($0) } ?? "Unknown"
            accessedValue.stringValue = info.accessed.map { PropertyFormat.longDate($0) } ?? "Unknown"
            securityRow?.isHidden = !info.quarantined
            securitySeparator?.isHidden = !info.quarantined
            unblock.state = entries[0].edited.quarantined ? .off : .on
        }
        showSizes()
        readOnly.allowsMixed = model.tri(\.locked, edited: false) == .mixed
        hidden.allowsMixed = model.tri(\.hidden, edited: false) == .mixed
        readOnly.state = model.tri(\.locked)
        hidden.state = model.tri(\.hidden)
        containsRow?.isHidden = isMulti && !entries.contains { $0.item.isFolder || $0.item.isPackage }
        let allDot = infos.count == entries.count && !infos.isEmpty && infos.allSatisfy(\.dotHidden)
        hidden.isEnabled = !allDot
        if allDot { hidden.state = .on }
        readOnly.isEnabled = model.subject != .volume
        attributeNote.stringValue = noteText(allDot: allDot)
    }

    private func noteText(allDot: Bool) -> String {
        var text = "Read-only is macOS's Locked setting: the item can't be changed, renamed or moved to the Trash until it's turned off."
        if model.subject == .folder { text = "Read-only locks the folder itself (Finder: Locked): items can't be added, removed or renamed inside it." }
        if allDot { text += " Names that start with “.” are always hidden." }
        return text
    }

    private func showSizes(stopped: Bool = false) {
        if needsScan {
            let suffix = scanning ? "" : (stopped ? " (stopped)" : "")
            sizeValue.stringValue = PropertyFormat.propertiesSize(totals.size) + suffix
            onDiskValue.stringValue = PropertyFormat.propertiesSize(totals.sizeOnDisk) + suffix
            var contains = PropertyFormat.filesAndFolders(files: totals.files, folders: totals.folders)
            if totals.unreadable > 0 { contains += " (\(PropertyFormat.count(totals.unreadable, "folder", "folders")) couldn't be read)" }
            containsValue.stringValue = contains
            containsValue.toolTip = contains
            stopButton.isHidden = !scanning
        } else if let info = infos.first {
            sizeValue.stringValue = PropertyFormat.propertiesSize(info.fileSize)
            onDiskValue.stringValue = PropertyFormat.propertiesSize(info.fileOnDisk)
        }
    }

    // MARK: Editing

    private func setLocked(_ state: TriState) {
        model.edit { edited, original in edited.locked = state.boolValue ?? original.locked }
    }

    private func setHidden(_ state: TriState) {
        model.edit { edited, original in edited.hidden = state.boolValue ?? original.hidden }
    }

    private func showAdvanced() {
        guard let window = controller?.window else { return }
        AdvancedAttributesSheet.show(for: model, over: window)
    }

    private func changeApp() {
        guard let single = model.single, let window = controller?.window else { return }
        OpenWithChooser.show(for: single.url, contentType: infos.first?.contentType, over: window) { [weak self] in
            self?.loadInfo()
        }
    }

    var debugText: String {
        var lines = ["name: \(isMulti ? headerLabel.stringValue : nameField.stringValue)", "type: \(typeValue.stringValue)"]
        if model.subject == .file { lines.append("opens with: \(openWithName.stringValue)") }
        if model.subject == .package { lines.append("version: \(versionValue.stringValue)") }
        lines += ["location: \(locationValue.stringValue)", "size: \(sizeValue.stringValue)", "size on disk: \(onDiskValue.stringValue)"]
        if needsScan { lines.append("contains: \(containsValue.stringValue)  scanning: \(scanning)") }
        if !isMulti { lines.append("created: \(createdValue.stringValue)") }
        lines.append("read-only: \(readOnly.state)  hidden: \(hidden.state)\(hidden.isEnabled ? "" : " (disabled)")")
        if model.subject == .file { lines.append("security row: \(securityRow?.isHidden == false ? "shown, unblock=\(unblock.state)" : "hidden")") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Advanced Attributes

/// Explorer's Advanced Attributes dialog, with what is real on macOS (FE-156, FE-245).
enum AdvancedAttributesSheet {
    static func show(for model: PropertiesModel, over window: NSWindow) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Advanced Attributes"
        let content = ThemeBackgroundView(SheetColors.windowBackground)
        content.translatesAutoresizingMaskIntoConstraints = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        add(SheetLabel.wrapping("Choose the settings you want for \(model.single == nil ? "these items" : "this item").", secondary: false))
        add(SheetLabel.make("File attributes:", bold: true))
        let archive = SheetCheckbox("File is ready for archiving")
        archive.isEnabled = false
        add(archive)
        let tm = SheetLabel.wrapping("macOS has no archive bit. Time Machine backs up changed files automatically.", small: true)
        add(tm)
        let index = SheetCheckbox("Allow contents to be indexed (Spotlight)")
        index.state = .on
        index.isEnabled = false
        add(index)
        add(SheetLabel.wrapping("Spotlight indexes files automatically. To exclude a folder, add it under Spotlight › Search Privacy in System Settings.", small: true))
        add(SheetLabel.make("Compress or Encrypt attributes:", bold: true))
        let compress = SheetCheckbox("Compress contents to save disk space")
        compress.isEnabled = false
        add(compress)
        let encrypt = SheetCheckbox("Encrypt contents to secure data")
        encrypt.isEnabled = false
        add(encrypt)
        add(SheetLabel.wrapping("APFS has no per-file compression or encryption switch. Whole disks are encrypted with FileVault (System Settings › Privacy & Security).", small: true))
        let spotlight = SheetButton("Spotlight Settings…") { _ in
            SystemOpen.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
        }
        let ok = SheetButton("OK", isDefault: true) { [weak window, weak sheet] _ in
            if let sheet { window?.endSheet(sheet) }
        }
        let buttons = hstack([spotlight, NSView(), ok])
        add(buttons)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
        ])
        sheet.contentView = content
        if model.single != nil {
            DispatchQueue.global(qos: .utility).async { [weak tm] in
                guard let url = model.single?.url, let excluded = TimeMachineStatus.isExcluded(url) else { return }
                DispatchQueue.main.async {
                    tm?.stringValue = "macOS has no archive bit. Time Machine backs up changed files automatically"
                        + (excluded ? "; this item is excluded from Time Machine backups." : "; this item is included in backups.")
                }
            }
        }
        window.beginSheet(sheet)
    }
}

// MARK: - Opens with › Change…

/// "How do you want to open this file?": choose the default app for the file's type
/// (NSWorkspace.setDefaultApplication), or look for another app.
enum OpenWithChooser {
    static func show(for url: URL, contentType: UTType?, over window: NSWindow, done: @escaping () -> Void) {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let current = NSWorkspace.shared.urlForApplication(toOpen: url)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let content = ThemeBackgroundView(SheetColors.windowBackground)
        content.translatesAutoresizingMaskIntoConstraints = true
        let ext = url.pathExtension.isEmpty ? "this file" : ".\(url.pathExtension) files"
        let heading = SheetLabel.make("Select an app to open \(ext) from now on", bold: true)
        let list = SheetScrollList()
        let box = SheetBox()
        box.addSubview(list)
        var chosen = current
        var rows: [(SheetListRow, URL)] = []
        func rebuild() {
            for (row, app) in rows { row.isSelected = app == chosen }
        }
        for app in apps.prefix(40) {
            let image = fixedImage(NSWorkspace.shared.icon(forFile: app.path), 20)
            let name = SheetLabel.make(displayName(of: app).replacingOccurrences(of: ".app", with: ""))
            let row = SheetListRow([image, name], height: 28)
            row.onSelect = { chosen = app; rebuild() }
            rows.append((row, app))
            list.add(row)
        }
        rebuild()
        let note = SheetLabel.wrapping(contentType == nil ? "This file's type is unknown, so only this file will change." : "Every file of this type will open with the app you choose.", small: true)
        var more: SheetButton!
        more = SheetButton("Look for another app on this Mac…") { [weak sheet] _ in
            guard let sheet else { return }
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.beginSheetModal(for: sheet) { response in
                guard response == .OK, let app = panel.url else { return }
                chosen = app
                let image = fixedImage(NSWorkspace.shared.icon(forFile: app.path), 20)
                let row = SheetListRow([image, SheetLabel.make(displayName(of: app))], height: 28)
                row.onSelect = { chosen = app; rebuild() }
                rows.append((row, app))
                list.add(row)
                rebuild()
            }
        }
        let ok = SheetButton("OK", isDefault: true) { [weak window, weak sheet] _ in
            guard let sheet else { return }
            window?.endSheet(sheet)
            guard let app = chosen, app != current else { return }
            let finish: (Error?) -> Void = { error in
                DispatchQueue.main.async {
                    if let error { NSAlert.show("The default app couldn't be changed.", error.localizedDescription, in: window) }
                    done()
                }
            }
            if let type = contentType, !url.pathExtension.isEmpty {
                SystemOpen.setDefaultApplication(at: app, toOpen: type, completion: finish)
            } else {
                SystemOpen.setDefaultApplication(at: app, toOpenFileAt: url, completion: finish)
            }
        }
        let cancel = SheetButton("Cancel") { [weak window, weak sheet] _ in if let sheet { window?.endSheet(sheet) } }
        let buttons = hstack([NSView(), ok, cancel])
        for v in [heading, box, note, more!, buttons] as [NSView] { content.addSubview(v) }
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            box.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            list.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            note.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            more.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            more.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: more.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        sheet.contentView = content
        window.beginSheet(sheet)
    }
}
