import AppKit
import ArborCore

/// Explorer's "Map Network Drive" dialog (FE-177), adapted honestly: macOS has no drive letters, so
/// the Drive row explains where the drive appears instead (DEC-019). Finish connects asynchronously
/// (cancellable) and saves a mapping record with server + share + account identity (FE-187);
/// passwords are only ever handled by the system sign-in prompt and Keychain (FE-178).
final class MapNetworkDriveSheet: NSWindowController, NSComboBoxDelegate, NSComboBoxDataSource {
    private static var current: MapNetworkDriveSheet?
    private weak var browser: BrowserWindowController?
    let folderField = NSComboBox()
    let reconnect = NSButton(checkboxWithTitle: "Reconnect at sign-in", target: nil, action: nil)
    let differentCredentials = NSButton(checkboxWithTitle: "Connect using different credentials", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var finishButton: FluentButton!
    private var cancelButton: FluentButton!
    private var attempt: NetworkCancellable?
    private var suggestions: [String] = []
    private(set) var resultText = ""

    static func present(in browser: BrowserWindowController, folder: String? = nil) {
        guard let host = browser.window, host.attachedSheet == nil else { NSSound.beep(); return }
        let sheet = MapNetworkDriveSheet(browser: browser)
        if let folder { sheet.folderField.stringValue = folder }
        current = sheet
        host.beginSheet(sheet.window!) { _ in current = nil }
        sheet.window?.makeFirstResponder(sheet.folderField)
        if let editor = sheet.folderField.currentEditor() { editor.selectedRange = NSRange(location: (sheet.folderField.stringValue as NSString).length, length: 0) }
    }

    /// The open dialog, for scripted checks.
    static var open: MapNetworkDriveSheet? { current }

    init(browser: BrowserWindowController) {
        self.browser = browser
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        panel.title = "Map Network Drive"
        super.init(window: panel)
        build(in: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Theme.primaryText) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isSelectable = false
        return l
    }

    private func build(in panel: NSPanel) {
        let root = ThemeBackgroundView(Theme.contentBackground)
        panel.contentView = root

        let titleIcon = NSImageView(image: NetworkIcons.drive(32))
        let heading = label("What network folder would you like to map?", size: 17, weight: .regular, color: Theme.rgb(0x1A5FB4))
        heading.textColor = NSColor(name: nil) { Theme.isDark($0) ? Theme.rgb(0x8CC2FF) : Theme.rgb(0x1A5FB4) }
        let headRow = NSStackView(views: [titleIcon, heading])
        headRow.spacing = 10
        let intro = label("Specify the folder that you want to connect to:")

        let driveTitle = label("Drive:")
        let driveValue = label("Macs don't use drive letters. The drive appears under This Mac by its name, such as “Media (\\\\server)”.",
                               size: 12, color: Theme.secondaryText)

        let folderTitle = label("Folder:")
        folderField.usesDataSource = true
        folderField.dataSource = self
        folderField.delegate = self
        folderField.completes = false
        folderField.placeholderString = "\\\\server\\share"
        folderField.font = Theme.bodyFont
        folderField.translatesAutoresizingMaskIntoConstraints = false
        folderField.setAccessibilityLabel("Folder")
        suggestions = Self.suggestionList()
        let browse = FluentButton("Browse…") { [weak self] in self?.browse() }
        let folderRow = NSStackView(views: [folderField, browse])
        folderRow.spacing = 8
        let example = label("Example: \\\\server\\share  or  smb://server/share", size: 12, color: Theme.secondaryText)

        reconnect.state = .on
        reconnect.font = Theme.bodyFont
        differentCredentials.font = Theme.bodyFont
        differentCredentials.toolTip = "macOS asks for a user name and password. You can save them in your Keychain."

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.font = Theme.statusFont
        message.textColor = Theme.secondaryText
        message.isHidden = true
        let messageRow = NSStackView(views: [spinner, message])
        messageRow.spacing = 6

        let form = NSGridView(views: [
            [driveTitle, driveValue],
            [folderTitle, folderRow],
            [NSGridCell.emptyContentView, example],
            [NSGridCell.emptyContentView, reconnect],
            [NSGridCell.emptyContentView, differentCredentials],
            [NSGridCell.emptyContentView, messageRow],
        ])
        form.rowSpacing = 8
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.row(at: 0).yPlacement = .top
        form.row(at: 1).yPlacement = .center
        form.row(at: 2).topPadding = -4
        form.row(at: 3).topPadding = 6
        form.translatesAutoresizingMaskIntoConstraints = false

        finishButton = FluentButton("Finish", primary: true) { [weak self] in self?.finish() }
        finishButton.keyEquivalent = "\r"
        cancelButton = FluentButton("Cancel") { [weak self] in self?.cancel() }
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [finishButton, cancelButton])
        buttons.spacing = 8
        let footer = ThemeBackgroundView(Theme.navPaneBackground)
        footer.topLine = Theme.separator
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)

        let stack = NSStackView(views: [headRow, intro, form])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: headRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            titleIcon.widthAnchor.constraint(equalToConstant: 32),
            titleIcon.heightAnchor.constraint(equalToConstant: 32),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            folderField.widthAnchor.constraint(equalToConstant: 340),
            driveValue.widthAnchor.constraint(equalToConstant: 440),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),
            footer.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            finishButton.widthAnchor.constraint(equalToConstant: 100),
            cancelButton.widthAnchor.constraint(equalToConstant: 100),
        ])
    }

    /// Recently mapped drives and connected shares, most useful first.
    static func suggestionList() -> [String] {
        var list = NetworkCenter.shared.drives.drives.map(\.address.unc)
        list += NetworkCenter.shared.mountedShares().compactMap { $0.address?.shareRoot?.unc }
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { suggestions.count }
    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? { suggestions[index] }

    // MARK: Browse…

    /// Lists computers Arbor can see, then the chosen computer's shares (Explorer's Browse For Folder, as menus).
    private func browse() {
        let discovery = NetworkCenter.shared.services.makeDiscovery()
        browseDiscovery = discovery
        showMessage("Looking for computers…", busy: true)
        discovery.onChange = { [weak self, weak discovery] in
            guard let self, let discovery, discovery.state != .searching else { return }
            self.browseDiscovery = nil
            discovery.stop()
            self.showMessage(nil)
            let devices = NetworkDiscoveryModel.devices(from: discovery.services).filter { $0.preferredScheme != nil }
            let menu = NSMenu()
            if devices.isEmpty {
                let item = NSMenuItem(title: discovery.state == .needsPermission ? "Local Network access is off for Arbor" : "No computers found", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            for device in devices {
                menu.addItem(ClosureMenuItem(device.name, image: NetworkIcons.computer(16)) { [weak self] in self?.browseShares(of: device) })
            }
            self.popUp(menu)
        }
        discovery.start()
    }
    private var browseDiscovery: NetworkDiscovering?

    private func browseShares(of device: NetworkDevice) {
        showMessage("Looking for shared folders on \(device.name)…", busy: true)
        NetworkCenter.shared.services.resolve(device) { [weak self] address in
            guard let self else { return }
            guard let address else { self.showMessage("Arbor can't find the address of “\(device.name)”.", error: true); return }
            self.folderField.stringValue = address.unc + "\\"
            NetworkCenter.shared.services.listShares(on: address) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let shares):
                    self.showMessage(nil)
                    let menu = NSMenu()
                    for share in shares {
                        menu.addItem(ClosureMenuItem(share.name, image: NetworkIcons.share(16)) { [weak self] in
                            self?.folderField.stringValue = address.appending(share.name).unc
                        })
                    }
                    self.popUp(menu)
                case .failure(let error):
                    self.showMessage(error.localizedDescription + " Type the share name after the server name.", error: true)
                }
            }
        }
    }

    private func popUp(_ menu: NSMenu) {
        guard !AppDelegate.isHeadless else { browseMenuForTests = menu; return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: folderField.bounds.height + 2), in: folderField)
    }
    /// Headless runs can't track a menu; scripts read it from here.
    private(set) var browseMenuForTests: NSMenu?

    // MARK: Finish / Cancel

    func finish() {
        guard attempt == nil else { return }
        let text = folderField.stringValue
        guard let address = NetworkAddress.parse(text) else {
            showMessage("“\(text)” isn't a network folder. Type it like \\\\server\\share or smb://server/share.", error: true)
            return
        }
        guard address.share != nil else {
            showMessage("Add the shared folder's name after the server name, like \\\\\(address.hostDisplayName)\\share.", error: true)
            return
        }
        showMessage("Attempting to connect to \(address.unc)…", busy: true)
        finishButton.isEnabled = false
        folderField.isEnabled = false
        let wantsReconnect = reconnect.state == .on
        attempt = NetworkCenter.shared.map(address, reconnectAtSignIn: wantsReconnect, differentCredentials: differentCredentials.state == .on) { [weak self] result in
            guard let self else { return }
            self.attempt = nil
            self.finishButton.isEnabled = true
            self.folderField.isEnabled = true
            switch result {
            case .success(let (drive, folder)):
                self.resultText = "mapped \(drive.label)"
                self.close(navigateTo: folder)
            case .failure(.cancelled):
                self.showMessage(nil)
            case .failure(let error):
                self.showMessage(error.localizedDescription, error: true)
            }
        }
    }

    func cancel() {
        if let attempt {
            // First Cancel stops the connection attempt, like Explorer's "Attempting to connect" box.
            attempt.cancel()
            self.attempt = nil
            finishButton.isEnabled = true
            folderField.isEnabled = true
            showMessage("Cancelled.")
            return
        }
        close(navigateTo: nil)
    }

    private func close(navigateTo folder: URL?) {
        guard let sheet = window, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
        if let folder, let browser { browser.navigate(to: .folder(folder)) }
    }

    private func showMessage(_ text: String?, busy: Bool = false, error: Bool = false) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        message.textColor = error ? Theme.rgb(0xC42B1C) : Theme.secondaryText
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        resultText = text ?? resultText
    }

    var debugSummary: String {
        "map dialog: folder=\(folderField.stringValue) reconnect=\(reconnect.state == .on) differentCredentials=\(differentCredentials.state == .on)"
            + " message=\(message.isHidden ? "-" : message.stringValue) connecting=\(attempt != nil)"
            + " browse=[\(browseMenuForTests?.items.map(\.title).joined(separator: ", ") ?? "")]"
    }
}

// MARK: - Disconnect (FE-177)

enum NetworkDisconnect {
    /// Unmounts one share; a busy volume explains why and offers to force it, like Explorer.
    static func disconnect(_ share: MountedShare, window: BrowserWindowController, force: Bool = false) {
        let name = NetworkCenter.shared.mappedDrive(for: share)?.label ?? share.address?.driveLabel ?? share.volumeName
        window.statusBar.setMessage("Disconnecting “\(name)”…")
        NetworkCenter.shared.disconnect(share, force: force) { [weak window] result in
            guard let window else { return }
            switch result {
            case .success:
                window.statusBar.setMessage("“\(name)” was disconnected.")
            case .failure(.busy):
                window.statusBar.setMessage("“\(name)” is in use.", isError: true)
                let alert = NSAlert()
                alert.messageText = "There are open files on “\(name)”."
                alert.informativeText = "Close any files, folders or apps that use the drive, then try again. If you disconnect anyway, apps lose access and unsaved changes in open files may be lost."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Disconnect Anyway")
                alert.buttons[1].hasDestructiveAction = true
                let handle: (NSApplication.ModalResponse) -> Void = { response in
                    if response == .alertSecondButtonReturn { disconnect(share, window: window, force: true) }
                }
                if let host = window.window, host.attachedSheet == nil { alert.beginSheetModal(for: host, completionHandler: handle) } else { handle(alert.runModal()) }
            case .failure(let error):
                window.statusBar.setMessage(error.localizedDescription, isError: true)
            }
        }
    }
}

/// Explorer's "Disconnect Network Drives" list, shown when no drive is selected.
final class DisconnectDrivesSheet: NSWindowController {
    private static var current: DisconnectDrivesSheet?
    private weak var browser: BrowserWindowController?
    private var rows: [(button: NSButton, share: MountedShare?, drive: MappedDrive?)] = []

    static var open: DisconnectDrivesSheet? { current }

    static func present(in browser: BrowserWindowController) {
        guard let host = browser.window, host.attachedSheet == nil else { NSSound.beep(); return }
        let sheet = DisconnectDrivesSheet(browser: browser)
        current = sheet
        host.beginSheet(sheet.window!) { _ in current = nil }
    }

    init(browser: BrowserWindowController) {
        self.browser = browser
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        panel.title = "Disconnect Network Drives"
        super.init(window: panel)
        build(panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(_ panel: NSPanel) {
        let root = ThemeBackgroundView(Theme.contentBackground)
        panel.contentView = root
        let intro = NSTextField(wrappingLabelWithString: "Select the network drives you want to disconnect, then click OK.")
        intro.font = Theme.bodyFont
        intro.textColor = Theme.primaryText
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let center = NetworkCenter.shared
        var shownMounts = Set<String>()
        for drive in center.drives.drives {
            let status = center.status(of: drive)
            var share: MountedShare?
            if case .connected(let s) = status { share = s; shownMounts.insert(s.mountPoint.path) }
            let detail = share == nil ? "  —  not connected" : "  —  \(drive.address.unc)"
            let box = NSButton(checkboxWithTitle: drive.label + detail, target: nil, action: nil)
            box.toolTip = share?.mountPoint.path
            add(box, share: share, drive: drive, to: list)
        }
        for share in center.mountedShares() where !shownMounts.contains(share.mountPoint.path) {
            let title = (share.address?.driveLabel ?? share.volumeName) + "  —  \(share.address?.shareRoot?.unc ?? share.mountPoint.path)"
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.toolTip = share.mountPoint.path
            add(box, share: share, drive: nil, to: list)
        }
        if rows.isEmpty {
            let none = NSTextField(labelWithString: "There are no network drives to disconnect.")
            none.font = Theme.bodyFont
            none.textColor = Theme.secondaryText
            list.addArrangedSubview(none)
        }
        let ok = FluentButton("OK", primary: true) { [weak self] in self?.confirm() }
        ok.keyEquivalent = "\r"
        ok.isEnabled = !rows.isEmpty
        let cancel = FluentButton("Cancel") { [weak self] in self?.dismiss() }
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [ok, cancel])
        buttons.spacing = 8
        let stack = NSStackView(views: [intro, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            ok.widthAnchor.constraint(equalToConstant: 90),
            cancel.widthAnchor.constraint(equalToConstant: 90),
        ])
    }

    private func add(_ box: NSButton, share: MountedShare?, drive: MappedDrive?, to list: NSStackView) {
        box.font = Theme.bodyFont
        list.addArrangedSubview(box)
        rows.append((box, share, drive))
    }

    /// Ticks the row whose title starts with `prefix` (scripted checks).
    func check(_ prefix: String) {
        rows.first { $0.button.title.hasPrefix(prefix) }?.button.state = .on
    }

    var debugSummary: String { "disconnect dialog: " + rows.map { "\($0.button.title)\($0.button.state == .on ? " ✓" : "")" }.joined(separator: " | ") }

    private func confirm() {
        guard let browser else { dismiss(); return }
        let chosen = rows.filter { $0.button.state == .on }
        dismiss()
        for row in chosen {
            if let share = row.share { NetworkDisconnect.disconnect(share, window: browser) }
            else if let drive = row.drive { NetworkCenter.shared.disconnect(drive) }
        }
    }

    private func dismiss() {
        guard let sheet = window, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
    }
}
