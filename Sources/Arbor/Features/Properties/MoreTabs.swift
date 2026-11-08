import AppKit
import UniformTypeIdentifiers
import ArborCore

/// Which tabs a selection gets, in Explorer's order (spec §11.3 matrix, reference §10).
enum PropertiesTabs {
    static func make(for model: PropertiesModel, controller: PropertiesWindowController) -> [PropertiesTab] {
        switch model.subject {
        case .multiple:
            return [GeneralTab(model: model, controller: controller)]
        case .file:
            var tabs: [PropertiesTab] = [GeneralTab(model: model, controller: controller), SecurityTab(model: model),
                                         DetailsTab(model: model, controller: controller), PreviousVersionsTab(model: model, controller: controller)]
            if let url = model.single?.url, isSignableExecutable(url) { tabs.insert(SignaturesTab(model: model), at: 3) }
            return tabs
        case .folder:
            return [GeneralTab(model: model, controller: controller), SharingTab(model: model), SecurityTab(model: model),
                    PreviousVersionsTab(model: model, controller: controller), CustomizeTab(model: model, controller: controller)]
        case .package:
            return [GeneralTab(model: model, controller: controller), SecurityTab(model: model),
                    DetailsTab(model: model, controller: controller), SignaturesTab(model: model)]
        case .volume:
            return [DriveGeneralTab(model: model, controller: controller), FileSystemTab(model: model), ToolsTab(model: model), SharingTab(model: model),
                    SecurityTab(model: model)]
        }
    }

    /// Mach-O tools and scripts with a signature are worth a Digital Signatures tab.
    static func isSignableExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .executable) || type.conforms(to: .unixExecutable)
    }
}

// MARK: - Previous Versions

/// Document versions (NSFileVersion) and Time Machine status (FE-155). Nothing invented; browsing opens Time Machine.
final class PreviousVersionsTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("Previous Versions")
    let view: NSView
    private let model: PropertiesModel
    private weak var controller: PropertiesWindowController?
    private let page = SheetPage()
    private let list = SheetScrollList()
    private let empty = SheetLabel.wrapping(L10n.tr("There are no previous versions available."), secondary: true)
    private let tmStatus = SheetLabel.wrapping(L10n.tr("Checking Time Machine…"), secondary: false)
    private lazy var openButton = SheetButton(L10n.tr("Open")) { [weak self] _ in self?.openVersion() }
    private lazy var restoreToButton = SheetButton(L10n.tr("Restore To…")) { [weak self] _ in self?.restoreTo() }
    private lazy var restoreButton = SheetButton(L10n.tr("Restore")) { [weak self] _ in self?.restoreInPlace() }
    private lazy var browse = SheetButton(L10n.tr("Browse in Time Machine")) { [weak self] _ in self?.browseTimeMachine() }
    private lazy var settings = SheetButton(L10n.tr("Time Machine Settings…")) { _ in
        SystemOpen.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
    }
    private var versions: [DocumentVersion] = []
    private lazy var backups = TimeMachineVersionsView(controller: controller)
    private var rows: [SheetListRow] = []
    private var selected: Int?
    private var status: TimeMachineStatus?
    private var isFile: Bool { model.subject == .file }

    init(model: PropertiesModel, controller: PropertiesWindowController) {
        self.model = model
        self.controller = controller
        view = page
        build()
        load()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let icon = fixedImage(NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil), 28)
        icon.contentTintColor = Theme.iconTint
        let intro = SheetLabel.wrapping(isFile ? "Previous versions come from document versions saved by apps (File › Revert To) and from Time Machine backups."
                                               : "Previous versions of folders come from Time Machine backups.", secondary: false)
        add(hstack([icon, intro], spacing: 10))
        if isFile {
            add(SheetLabel.make(L10n.tr("File versions:")))
            let header = NSView()
            header.translatesAutoresizingMaskIntoConstraints = false
            let n = SheetLabel.make(L10n.tr("Name"), secondary: true), d = SheetLabel.make(L10n.tr("Date modified"), secondary: true)
            header.addSubview(n)
            header.addSubview(d)
            NSLayoutConstraint.activate([
                header.heightAnchor.constraint(equalToConstant: 20),
                n.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
                n.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                d.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 180),
                d.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
            let box = SheetBox()
            for v in [header, list, empty] as [NSView] { box.addSubview(v) }
            NSLayoutConstraint.activate([
                box.heightAnchor.constraint(equalToConstant: 150),
                header.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
                header.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                list.topAnchor.constraint(equalTo: header.bottomAnchor),
                list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
                list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
                list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
                empty.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: 8),
                empty.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                empty.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            ])
            empty.alignment = .center
            add(box)
            add(hstack([NSView(), openButton, restoreButton, restoreToButton]))
        }
        add(SheetSeparator())
        add(SheetLabel.make(L10n.tr("Time Machine"), bold: true))
        add(tmStatus)
        add(backups)
        add(hstack([browse, settings]))
        page.embed(stack)
        updateButtons()
    }

    private func load() {
        guard let url = model.single?.url else { return }
        backups.load(url)
        let isFile = self.isFile
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let versions = isFile ? DocumentVersions.list(url) : []
            let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
            let status = TimeMachineStatus.read(volume: volume)
            DispatchQueue.main.async {
                guard let self else { return }
                self.versions = versions
                self.status = status
                self.rebuild()
            }
        }
    }

    func reload() {}

    private func rebuild() {
        list.removeAll()
        rows = []
        for (i, v) in versions.enumerated() {
            let image = fixedImage(IconProvider.shared.fileIcon(model.single?.url ?? v.url, size: 16), 16)
            let name = SheetLabel.make(v.name)
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let date = SheetLabel.make(v.date.map { PropertyFormat.shortDate($0) } ?? "Unknown")
            let row = SheetListRow([image, name, date], height: 22)
            row.onSelect = { [weak self] in self?.select(i) }
            rows.append(row)
            list.add(row)
        }
        empty.isHidden = !versions.isEmpty
        var text: String
        if let status, status.available {
            if let dest = status.destinations.first {
                text = L10n.format("Backing up to “%@”.", "\(dest.name)")
                if status.destinations.count > 1 { text += " (\(status.destinations.count) backup disks)" }
            } else {
                text = L10n.tr("Time Machine isn't set up on this Mac.")
            }
            if let latest = status.localSnapshotDates.first {
                text += L10n.format(" This disk has %@; the newest is from %@.", "\(PropertyFormat.count(status.localSnapshotDates.count, "local snapshot", "local snapshots"))", "\(PropertyFormat.shortDate(latest))")
            }
            if status.isConfigured || !status.localSnapshotDates.isEmpty {
                text += L10n.tr(" To see older copies of this item, browse it in Time Machine.")
            }
        } else {
            text = L10n.tr("Time Machine status isn't available.")
        }
        tmStatus.stringValue = text
        browse.isHidden = !(status.map { $0.isConfigured || !$0.localSnapshotDates.isEmpty } ?? false)
        updateButtons()
    }

    private func select(_ i: Int) {
        selected = i
        for (j, row) in rows.enumerated() { row.isSelected = j == i }
        updateButtons()
    }

    private func updateButtons() {
        let has = selected.map { versions.indices.contains($0) } ?? false
        openButton.isEnabled = has
        restoreToButton.isEnabled = has
        restoreButton.isEnabled = has
    }

    private var current: DocumentVersion? { selected.flatMap { versions.indices.contains($0) ? versions[$0] : nil } }

    /// Opens a read-only copy so the stored version is never edited.
    private func openVersion() {
        guard let version = current, let url = model.single?.url else { return }
        let folder = TemporaryFiles.versionsFolder.appendingPathComponent(UUID().uuidString)
        let stamp = version.date.map { PropertyFormat.shortDate($0).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") } ?? "version"
        let (base, ext) = NameRules.splitExtension(url.lastPathComponent, treatAsFolder: false)
        let target = folder.appendingPathComponent("\(base) (\(stamp))" + (ext.map { ".\($0)" } ?? ""))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DocumentVersions.restore(version, to: target)
            try TemporaryFiles.makeVersionCopyReadOnly(target)
            VersionCopies.open(target, in: folder)
        } catch {
            PropertiesWindowController.present(message: L10n.tr("The version couldn't be opened."), info: error.localizedDescription, window: controller?.window)
        }
    }

    private func restoreTo() {
        guard let version = current, let url = model.single?.url, let window = controller?.window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = NameRules.keepBothName(for: url.lastPathComponent, treatAsFolder: false) {
            FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent($0).path)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            do {
                // The save panel already confirmed replacing; never delete an existing item here.
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try SystemTrash.trash(target)
                }
                try DocumentVersions.restore(version, to: target)
                PropertiesFeature.itemsChanged(old: target, new: target)
            } catch {
                DispatchQueue.main.async { PropertiesWindowController.present(message: "The version couldn't be restored.", info: error.localizedDescription, window: self?.controller?.window) }
            }
        }
    }

    private func restoreInPlace() {
        guard let version = current, let url = model.single?.url else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format("Restore “%@” to the version from %@?", "\(url.lastPathComponent)", "\(version.date.map { PropertyFormat.shortDate($0) } ?? "this date")")
        alert.informativeText = L10n.tr("The current contents are kept as another version, so you can switch back from this tab.")
        alert.addButton(withTitle: L10n.tr("Restore"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        PropertiesWindowController.present(alert, window: controller?.window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try DocumentVersions.restoreInPlace(version, of: url)
                PropertiesFeature.itemsChanged(old: url, new: url)
                self?.load()
            } catch {
                DispatchQueue.main.async {
                    PropertiesWindowController.present(message: L10n.tr("The version couldn't be restored."), info: error.localizedDescription, window: self?.controller?.window)
                }
            }
        }
    }

    /// Time Machine opens on Finder's front window, so the item is revealed in Finder first.
    private func browseTimeMachine() {
        guard let url = model.single?.url else { return }
        SystemOpen.reveal([url])
        let app = URL(fileURLWithPath: "/System/Applications/Time Machine.app")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            SystemOpen.openApplication(at: app)
        }
    }

    var debugText: String {
        ["versions: \(versions.count)\(versions.isEmpty ? " (\(empty.stringValue))" : "")",
         "time machine: \(tmStatus.stringValue)", "browse button: \(browse.isHidden ? "hidden" : "shown")",
         backups.debugText].joined(separator: "\n")
    }
}

// MARK: - Customize (folders)

/// "Optimize this folder for:" (via `FolderTemplateStore`) and the folder icon (NSWorkspace.setIcon), FE-154.
final class CustomizeTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("Customize")
    let view: NSView
    private let model: PropertiesModel
    private weak var controller: PropertiesWindowController?
    private let page = SheetPage()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var subfolders = SheetCheckbox(L10n.tr("Also apply this template to all subfolders")) { [weak self] _ in self?.changed() }
    private let iconPreview = fixedImage(nil, 48)
    private var pendingIcon: NSImage??   // .some(nil) = restore default
    private var store: FolderTemplateStore { FolderTemplateStore(defaults: Prefs.store) }

    init(model: PropertiesModel, controller: PropertiesWindowController) {
        self.model = model
        self.controller = controller
        view = page
        build()
        model.extraAppliers["template"] = { [weak self] in self?.applyTemplate() }
        model.extraAppliers["icon"] = { [weak self] in self?.applyIcon() }
        reload()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView, gap: CGFloat? = nil) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            if let gap, let prev = stack.arrangedSubviews.dropLast().last { stack.setCustomSpacing(gap, after: prev) }
        }
        add(SheetLabel.make(L10n.tr("What kind of folder do you want?"), bold: true))
        add(SheetLabel.make(L10n.tr("Optimize this folder for:")))
        popup.addItems(withTitles: FolderTemplate.allCases.map(\.title))
        popup.target = self
        popup.action = #selector(changed)
        popup.font = SheetColors.font
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        add(popup)
        add(subfolders)
        add(SheetLabel.wrapping(L10n.tr("Arbor uses this to choose columns and sorting for the folder. Finder doesn't use it."), small: true))
        add(SheetSeparator(), gap: 14)
        stack.arrangedSubviews.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        add(SheetLabel.make(L10n.tr("Folder icons"), bold: true), gap: 14)
        add(SheetLabel.wrapping(L10n.tr("You can change the folder's icon. Finder and other apps show it too."), small: true))
        let change = SheetButton(L10n.tr("Change Icon…")) { [weak self] _ in self?.chooseIcon() }
        let restore = SheetButton(L10n.tr("Restore Default")) { [weak self] _ in
            self?.pendingIcon = .some(nil)
            self?.changed()
        }
        add(hstack([iconPreview, change, restore], spacing: 10))
        page.embed(stack)
    }

    func reload() {
        guard let url = model.single?.url else { return }
        if !model.extraChanges.contains("template") {
            let choice = store.choice(for: url)
            popup.selectItem(at: FolderTemplate.allCases.firstIndex(of: choice?.template ?? .generalItems) ?? 0)
            subfolders.state = (choice?.appliesToSubfolders ?? false) ? .on : .off
        }
        switch pendingIcon {
        case .some(.some(let image)): iconPreview.image = image
        case .some(.none): iconPreview.image = IconProvider.shared.folderIcon(size: 48)
        case .none: iconPreview.image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    @objc private func changed() {
        model.extraChanges.insert("template")
        if pendingIcon != nil { model.extraChanges.insert("icon") }
        reload()
    }

    private func chooseIcon() {
        guard let window = controller?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = L10n.tr("Choose a picture for the folder's icon")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            self?.pendingIcon = .some(image)
            self?.changed()
        }
    }

    private func applyTemplate() -> String? {
        guard let url = model.single?.url else { return nil }
        let template = FolderTemplate.allCases[max(popup.indexOfSelectedItem, 0)]
        let sub = subfolders.state == .on
        store.set(template == .generalItems && !sub ? nil : .init(template: template, appliesToSubfolders: sub), for: url)
        NotificationCenter.default.post(name: PropertiesFeature.folderTemplateChanged, object: url)
        NotificationCenter.default.post(name: Prefs.changed, object: nil, userInfo: ["key": FolderTemplateStore.key])
        return nil
    }

    private func applyIcon() -> String? {
        guard let url = model.single?.url, let pending = pendingIcon else { return nil }
        let ok = NSWorkspace.shared.setIcon(pending, forFile: url.path, options: [])
        pendingIcon = nil
        return ok ? nil : "The folder icon couldn't be changed."
    }

    var debugText: String {
        "template: \(popup.titleOfSelectedItem ?? "")  subfolders: \(subfolders.state)  stored: \(model.single.flatMap { store.choice(for: $0.url) }.map { "\($0.template.rawValue)/\($0.appliesToSubfolders)" } ?? "none")"
    }

    func selectTemplateForScript(_ title: String, subfolders on: Bool) {
        if let i = FolderTemplate.allCases.firstIndex(where: { $0.title.lowercased() == title.lowercased() || $0.rawValue == title }) {
            popup.selectItem(at: i)
        }
        subfolders.state = on ? .on : .off
        changed()
    }
}

// MARK: - Sharing (folders, drives)

/// Network sharing is a system setting on the Mac (FE-154): an honest handoff, no fake share state.
final class SharingTab: PropertiesTab {
    let title = L10n.tr("Sharing")
    let view: NSView

    init(model: PropertiesModel) {
        let page = SheetPage()
        view = page
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let name = model.single?.url.lastPathComponent ?? ""
        let items: [NSView] = [
            SheetLabel.make(L10n.tr("Network File and Folder Sharing"), bold: true),
            hstack([fixedImage(IconProvider.shared.icon(for: model.entries[0].item, size: 32), 32), SheetLabel.make(name)], spacing: 10),
            SheetLabel.wrapping(L10n.tr("On a Mac, folders are shared with other computers in System Settings › General › Sharing › File Sharing, where you choose the folders and who can use them.")),
            SheetButton(L10n.tr("Sharing Settings…")) { _ in
                SystemOpen.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
            },
            SheetSeparator(),
            SheetLabel.make(L10n.tr("Share with nearby devices"), bold: true),
            SheetLabel.wrapping(L10n.tr("To send copies to people nearby, select the items and use Share in the command bar (AirDrop, Mail, Messages).")),
        ]
        for v in items {
            stack.addArrangedSubview(v)
            if v is NSTextField || v is SheetSeparator { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        stack.setCustomSpacing(16, after: items[3])
        page.embed(stack)
    }

    func reload() {}
}

// MARK: - Drives

/// Label, type, file system, usage pie; "Disk Cleanup" opens Storage settings (FE-183 boundary).
final class DriveGeneralTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("General")
    let view: NSView
    private let model: PropertiesModel
    private weak var controller: PropertiesWindowController?
    private let page = SheetPage()
    private let form = SheetForm(labelWidth: 84)
    private let nameField = SheetTextField()
    private let typeValue = SheetLabel.make("")
    private let fsValue = SheetLabel.make("")
    private let usedBytes = SheetLabel.make(""), usedShort = SheetLabel.make("")
    private let freeBytes = SheetLabel.make(""), freeShort = SheetLabel.make("")
    private let capBytes = SheetLabel.make(""), capShort = SheetLabel.make("")
    private let purgeable = SheetLabel.wrapping("", small: true)
    private let pie = PieChartView()
    private let caption = SheetLabel.make("")
    private var info: VolumeInfo?

    init(model: PropertiesModel, controller: PropertiesWindowController) {
        self.model = model
        self.controller = controller
        view = page
        build()
        model.extraAppliers["volumeName"] = { [weak self] in self?.applyName() }
        load()
    }

    private func build() {
        let icon = fixedImage(IconProvider.shared.icon(for: model.entries[0].item, size: 32), 32)
        nameField.onChange = { [weak self] _ in self?.model.extraChanges.insert("volumeName") }
        let header = hstack([icon, nameField], spacing: form.labelWidth + 4 - 34)
        form.add(header)
        form.separator()
        form.row(L10n.tr("Type:"), typeValue)
        form.row(L10n.tr("File system:"), fsValue)
        form.separator()
        func sizeRow(_ swatch: NSColor?, _ label: String, _ bytes: NSTextField, _ short: NSTextField) {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let l = SheetLabel.make(label)
            bytes.alignment = .right
            short.alignment = .right
            var views: [NSView] = [l, bytes, short]
            let sw = swatch.map { SwatchView($0) }
            if let sw { views.append(sw) }
            views.forEach(row.addSubview)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 20),
                l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
                l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                bytes.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -80),
                bytes.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                short.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                short.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            if let sw {
                NSLayoutConstraint.activate([sw.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                                             sw.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
            }
            form.add(row)
        }
        sizeRow(SheetColors.usedSpace, L10n.tr("Used space:"), usedBytes, usedShort)
        sizeRow(SheetColors.freeSpace, L10n.tr("Free space:"), freeBytes, freeShort)
        form.add(purgeable)
        form.separator()
        sizeRow(nil, L10n.tr("Capacity:"), capBytes, capShort)
        let chart = NSView()
        chart.translatesAutoresizingMaskIntoConstraints = false
        let cleanup = SheetButton(L10n.tr("Disk Cleanup")) { _ in
            SystemOpen.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
        }
        cleanup.toolTip = L10n.tr("Opens Storage in System Settings, where macOS recommends what to remove")
        for v in [pie, caption, cleanup] as [NSView] { chart.addSubview(v) }
        NSLayoutConstraint.activate([
            chart.heightAnchor.constraint(equalToConstant: 130),
            pie.centerXAnchor.constraint(equalTo: chart.centerXAnchor, constant: -30),
            pie.topAnchor.constraint(equalTo: chart.topAnchor, constant: 4),
            pie.widthAnchor.constraint(equalToConstant: 120),
            pie.heightAnchor.constraint(equalToConstant: 84),
            caption.centerXAnchor.constraint(equalTo: pie.centerXAnchor),
            caption.topAnchor.constraint(equalTo: pie.bottomAnchor, constant: 8),
            cleanup.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            cleanup.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
        ])
        form.add(chart)
        page.embed(form.stack)
    }

    private func load() {
        guard let url = model.single?.url else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = VolumeInfo.read(url)
            DispatchQueue.main.async {
                self?.info = info
                self?.show()
            }
        }
    }

    private func show() {
        guard let info else { typeValue.stringValue = L10n.tr("This drive's details couldn't be read."); return }
        if !model.extraChanges.contains("volumeName") { nameField.stringValue = info.name }
        nameField.isEditable = info.canRename && !info.isReadOnly
        nameField.toolTip = nameField.isEditable ? nil : "This drive can't be renamed here."
        typeValue.stringValue = info.typeText
        fsValue.stringValue = info.fileSystem
        func put(_ n: Int64, _ a: NSTextField, _ b: NSTextField) {
            a.stringValue = L10n.format("%@ bytes", "\(PropertyFormat.grouped(n))")
            b.stringValue = PropertyFormat.adaptiveSize(n)
        }
        put(info.used, usedBytes, usedShort)
        put(info.free, freeBytes, freeShort)
        put(info.capacity, capBytes, capShort)
        purgeable.stringValue = info.purgeable > 0
            ? "macOS can free up another \(PropertyFormat.adaptiveSize(info.purgeable)) of purgeable space (caches, snapshots, optimized iCloud files) when needed."
            : ""
        purgeable.isHidden = info.purgeable == 0
        pie.fraction = info.usedFraction
        caption.stringValue = L10n.format("Drive %@", "\(info.name)")
    }

    func reload() {
        if !model.extraChanges.contains("volumeName"), model.extraChanges.isEmpty, info != nil { load() }
    }

    private func applyName() -> String? {
        guard let url = model.single?.url else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != info?.name else { return nil }
        var values = URLResourceValues()
        values.volumeName = name
        var target = url
        do {
            try target.setResourceValues(values)
            info?.name = name
            return nil
        } catch {
            return L10n.format("The drive couldn't be renamed: %@", "\(error.localizedDescription)")
        }
    }

    var debugText: String {
        ["drive: \(nameField.stringValue) (editable: \(nameField.isEditable))", "type: \(typeValue.stringValue)", "file system: \(fsValue.stringValue)",
         "used: \(usedBytes.stringValue) / \(usedShort.stringValue)", "free: \(freeBytes.stringValue) / \(freeShort.stringValue)",
         "capacity: \(capBytes.stringValue) / \(capShort.stringValue)", "pie: \(Int((pie.fraction * 100).rounded()))%",
         "caption: \(caption.stringValue)"].joined(separator: "\n")
    }
}

/// Explorer's drive Tools tab mapped to Disk Utility (FE-183 boundary).
final class ToolsTab: PropertiesTab {
    let title = L10n.tr("Tools")
    let view: NSView

    init(model: PropertiesModel) {
        let page = SheetPage()
        view = page
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let check = SheetButton(L10n.tr("Check")) { _ in
            SystemOpen.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        }
        check.toolTip = L10n.tr("Opens Disk Utility; select the drive and click First Aid")
        let items: [NSView] = [
            SheetLabel.make(L10n.tr("Error checking"), bold: true),
            SheetLabel.wrapping(L10n.tr("This option checks the drive for file system errors. On a Mac this is First Aid in Disk Utility."), secondary: false),
            check,
            SheetSeparator(),
            SheetLabel.make(L10n.tr("Optimize and defragment drive"), bold: true),
            SheetLabel.wrapping(L10n.tr("APFS drives and SSDs don't need defragmenting; macOS keeps them optimized automatically. There is nothing to run."), secondary: false),
        ]
        for v in items {
            stack.addArrangedSubview(v)
            if !(v is SheetButton) { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        stack.setCustomSpacing(16, after: check)
        page.embed(stack)
    }

    func reload() {}
}

// MARK: - Digital Signatures (apps, packages, signed tools)

/// The code signature: Explorer's Digital Signatures tab in Mac terms (FE-157).
final class SignaturesTab: PropertiesTab, PropertiesTabDebug {
    let title = L10n.tr("Digital Signatures")
    let view: NSView
    private let model: PropertiesModel
    private let page = SheetPage()
    private let form = SheetForm(labelWidth: 110)
    private let status = SheetLabel.wrapping(L10n.tr("Checking the signature…"), secondary: false)
    private let statusIcon = fixedImage(NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil), 20)
    private let signer = SheetLabel.make("")
    private let team = SheetLabel.make("")
    private let identifier = SheetLabel.make("", selectable: true)
    private let timestamp = SheetLabel.make("")
    private let chain = SheetLabel.wrapping("", secondary: false, small: true)
    private var work: DispatchWorkItem?
    private var info: CodeSignatureInfo?

    init(model: PropertiesModel) {
        self.model = model
        view = page
        form.add(SheetLabel.make(L10n.tr("Digital Signature Information"), bold: true))
        form.add(hstack([statusIcon, status], spacing: 8))
        form.separator()
        form.row(L10n.tr("Signer:"), signer)
        form.row(L10n.tr("Team ID:"), team)
        form.row(L10n.tr("Identifier:"), identifier)
        form.row(L10n.tr("Signing time:"), timestamp)
        form.separator()
        form.add(SheetLabel.make(L10n.tr("Certificate chain:")))
        form.add(chain)
        page.embed(form.stack)
        load()
    }

    private func load() {
        guard let url = model.single?.url else { return }
        let work = DispatchWorkItem { [weak self] in
            let info = CodeSignatureInfo.read(url)
            DispatchQueue.main.async { self?.show(info) }
        }
        self.work = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func show(_ info: CodeSignatureInfo) {
        self.info = info
        status.stringValue = info.statusText
        let (symbol, color): (String, NSColor) = {
            switch info.status {
            case .valid where info.isVerified: return ("checkmark.seal.fill", SheetColors.success)
            case .valid where info.trust == .untrusted: return ("exclamationmark.triangle", Theme.secondaryText)
            case .valid: return ("checkmark.seal", Theme.secondaryText)
            case .unsigned: return ("seal", Theme.secondaryText)
            case .invalid: return ("xmark.seal.fill", SheetColors.failure)
            }
        }()
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = color
        signer.stringValue = info.signerName ?? "—"
        team.stringValue = info.teamIdentifier ?? "—"
        identifier.stringValue = info.identifier ?? "—"
        timestamp.stringValue = info.signingTimeText ?? L10n.tr("Not available")
        chain.stringValue = info.certificates.isEmpty ? L10n.tr("No certificates.") : info.certificates.enumerated().map { "\(String(repeating: "  ", count: $0.offset))\($0.element)" }.joined(separator: "\n")
    }

    func reload() {}
    func close() { work?.cancel() }

    var debugText: String {
        ["status: \(status.stringValue)", "signer: \(signer.stringValue)", "team: \(team.stringValue)", "identifier: \(identifier.stringValue)",
         "chain: \(chain.stringValue.replacingOccurrences(of: "\n", with: " > "))"].joined(separator: "\n")
    }
}
