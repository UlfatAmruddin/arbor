import AppKit
import ArborCore

/// Previous Versions ▸ copies of the item in Time Machine backups (FE-155), listed from
/// `tmutil listbackups` when macOS lets Arbor read them. Without Full Disk Access that is explained,
/// with a button to the Privacy settings, never shown as "no versions". "Open" opens a read-only copy
/// (folders open in a new tab; backups are read-only); "Restore…" copies the version back into the
/// item's folder as a normal copy job, so an existing item is never replaced without the usual
/// Replace / Skip / Keep both decision.
final class TimeMachineVersionsView: NSStackView {
    private enum State: Equatable {
        case loading, versions, none, needsAccess, notConfigured, unavailable(String)
    }

    private weak var controller: PropertiesWindowController?
    private var item: URL?
    private var versions: [BackupVersion] = []
    private var state = State.loading
    private var selected: Int?
    private var rows: [SheetListRow] = []
    private var token = 0
    private let list = SheetScrollList()
    private let message = SheetLabel.wrapping("Looking for this item in Time Machine backups…")
    private lazy var openButton = SheetButton("Open") { [weak self] _ in self?.openVersion() }
    private lazy var restoreButton = SheetButton("Restore…") { [weak self] _ in self?.confirmRestore() }
    private lazy var privacyButton = SheetButton("Privacy Settings…") { _ in
        if AppDelegate.isHeadless { TimeMachineVersionsView.lastOpened = "settings: Full Disk Access"; return }
        NSWorkspace.shared.open(TimeMachineBackups.fullDiskAccessSettingsURL)
    }

    /// Headless runs record what would be opened instead of launching apps.
    static var lastOpened: String?
    /// The most recently loaded section (scripts select rows in it).
    static weak var latest: TimeMachineVersionsView?

    init(controller: PropertiesWindowController?) {
        self.controller = controller
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let n = SheetLabel.make("Backup", secondary: true), d = SheetLabel.make("Date modified", secondary: true)
        header.addSubview(n)
        header.addSubview(d)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 20),
            n.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            n.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            d.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 184),
            d.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        let box = SheetBox()
        for v in [header, list, message] as [NSView] { box.addSubview(v) }
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 104),
            header.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            list.topAnchor.constraint(equalTo: header.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            message.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
        message.alignment = .center
        message.preferredMaxLayoutWidth = 300
        let title = SheetLabel.make("Copies in Time Machine backups:")
        for v in [title, box, hstack([privacyButton, NSView(), openButton, restoreButton])] as [NSView] {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        privacyButton.isHidden = true
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    func load(_ url: URL) {
        Self.latest = self
        item = url
        token += 1
        let token = self.token
        state = .loading
        show()
        let env = ProcessInfo.processInfo.environment
        let overrideBackups = AppDelegate.isHeadless ? env["ARBOR_TM_BACKUPS"] : nil
        let overrideAccess = AppDelegate.isHeadless ? env["ARBOR_TM_ACCESS"] : nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
            let listing: TimeMachineBackups.Listing
            if overrideAccess == "denied" {
                listing = .needsFullDiskAccess
            } else if overrideAccess == "unconfigured" {
                listing = .notConfigured
            } else if let overrideBackups {
                listing = .backups(overrideBackups.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            } else {
                let configured = TimeMachineStatus.read(volume: volume).isConfigured
                listing = TimeMachineBackups.list(configured: configured)
            }
            var found: [BackupVersion] = []
            var state: State
            switch listing {
            case .backups(let roots):
                found = TimeMachineBackups.versions(of: url, volumeRoot: volume, in: roots)
                state = found.isEmpty ? .none : .versions
            case .notConfigured: state = .notConfigured
            case .needsFullDiskAccess: state = .needsAccess
            case .unavailable(let why): state = .unavailable(why)
            }
            DispatchQueue.main.async {
                guard let self, token == self.token else { return }
                self.versions = found
                self.state = state
                self.selected = nil
                self.show()
            }
        }
    }

    private func show() {
        list.removeAll()
        rows = []
        for (i, v) in versions.enumerated() {
            let icon = fixedImage(v.isFolder ? IconProvider.shared.folderIcon(size: 16) : IconProvider.shared.fileIcon(v.url, size: 16), 16)
            let date = SheetLabel.make(PropertyFormat.shortDate(v.date))
            date.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let modified = SheetLabel.make(v.modified.map { PropertyFormat.shortDate($0) } ?? "")
            let row = SheetListRow([icon, date, modified], height: 22)
            row.toolTip = v.url.path
            row.onSelect = { [weak self] in self?.select(i) }
            rows.append(row)
            list.add(row)
        }
        let text: String
        switch state {
        case .loading: text = "Looking for this item in Time Machine backups…"
        case .versions: text = ""
        case .none: text = "No Time Machine backup has a copy of this item."
        case .notConfigured: text = "Time Machine isn't set up, so there are no backups to restore from."
        case .needsAccess: text = "Arbor needs Full Disk Access to look inside Time Machine backups. Turn it on for Arbor in System Settings › Privacy & Security › Full Disk Access, then reopen this tab."
        case .unavailable(let why): text = "Time Machine backups can't be read right now. \(why)"
        }
        message.stringValue = text
        message.isHidden = state == .versions
        privacyButton.isHidden = state != .needsAccess
        updateButtons()
    }

    private func select(_ i: Int) {
        selected = i
        for (j, row) in rows.enumerated() { row.isSelected = j == i }
        updateButtons()
    }

    private func updateButtons() {
        let has = current != nil
        openButton.isEnabled = has
        restoreButton.isEnabled = has
    }

    private var current: BackupVersion? { selected.flatMap { versions.indices.contains($0) ? versions[$0] : nil } }

    // MARK: Actions

    private func openVersion() {
        guard let version = current, let item else { return }
        if version.isFolder {
            BrowserWindowController.active?.openTab(.folder(version.url))
            Self.lastOpened = "tab: \(version.url.path)"
            return
        }
        // A locked copy in a temporary folder: the backup itself is never opened for editing.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Arbor Versions/\(UUID().uuidString)")
        let stamp = PropertyFormat.shortDate(version.date).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let (base, ext) = NameRules.splitExtension(item.lastPathComponent, treatAsFolder: false)
        let target = folder.appendingPathComponent("\(base) (\(stamp))" + (ext.map { ".\($0)" } ?? ""))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: version.url, to: target)
            try FileFlags.update(target, locked: true)
            if AppDelegate.isHeadless {
                // Scripted runs record it and leave nothing locked behind in the temporary folder.
                Self.lastOpened = "file: \(target.lastPathComponent) locked=\((try? FileFlags.read(target).isLocked) == true)"
                _ = try? FileFlags.update(target, locked: false)
                try? FileManager.default.removeItem(at: folder)
            } else {
                NSWorkspace.shared.open(target)
            }
        } catch {
            PropertiesWindowController.present(message: "The version couldn't be opened.", info: error.localizedDescription, window: controller?.window)
        }
    }

    private func confirmRestore() {
        guard let version = current, let item else { return }
        let folder = item.deletingLastPathComponent()
        let alert = NSAlert()
        alert.messageText = "Restore “\(item.lastPathComponent)” from the backup of \(PropertyFormat.shortDate(version.date))?"
        alert.informativeText = "Arbor copies the backed-up version into “\(displayName(of: folder))”. If an item with the same name is there, you choose whether to replace it (it goes to the Trash), skip, or keep both."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        PropertiesWindowController.present(alert, window: controller?.window) { response in
            guard response == .alertFirstButtonReturn, let browser = BrowserWindowController.active else { return }
            browser.startTransfer(.copy, [version.url], to: folder)
        }
    }

    // MARK: Scripting

    func scriptSelect(_ i: Int) { if versions.indices.contains(i) { select(i) } }

    /// "open" or "restore" (the document-versions list above has buttons with the same titles).
    func scriptPress(_ which: String) {
        let button = which == "open" ? openButton : restoreButton
        if button.isEnabled { button.onClick?(button) }
    }

    var debugText: String {
        "backups: \(state == .versions ? "\(versions.count) versions" : message.stringValue) | privacy button: \(privacyButton.isHidden ? "hidden" : "shown") | open=\(openButton.isEnabled) restore=\(restoreButton.isEnabled)"
            + (versions.isEmpty ? "" : " | " + versions.map { PropertyFormat.shortDate($0.date) }.joined(separator: ", "))
            + " | last opened: \(Self.lastOpened ?? "-")"
    }
}
