import AppKit
import ArborCore

/// Base for the tile pages: scrollable grouped tiles, an optional info bar, and a status line.
class NetworkTilesPage: NSViewController, LocationPageStatus {
    weak var host: LocationHost?
    let grid = TileSectionsView()
    let banner = NSStackView()
    private var observers: [NSObjectProtocol] = []

    init(host: LocationHost?) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    var statusSummary: String {
        let count = grid.allTiles.count
        let selected = grid.selected.map { _ in "1 item selected  |" } ?? ""
        return StatusText.items(count) + "  |" + (selected.isEmpty ? "" : "  " + selected)
    }

    var window: BrowserWindowController? { host as? BrowserWindowController }

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        grid.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        grid.autoresizingMask = [.width]
        scroll.documentView = grid
        banner.orientation = .vertical
        banner.alignment = .leading
        banner.spacing = 8
        banner.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        banner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(banner)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        grid.onSelectionChange = { [weak self] in self?.window?.updateChrome() }
        view = root
        observers.append(NotificationCenter.default.addObserver(forName: NetworkCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.networkChanged()
        })
    }

    func networkChanged() {}

    func setBanner(_ views: [NSView]) {
        banner.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views {
            banner.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: banner.widthAnchor, constant: -32).isActive = true
        }
    }

    func emptyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.bodyFont
        label.textColor = Theme.secondaryText
        return label
    }

    func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        items.forEach(menu.addItem)
        return menu
    }

    /// "Network locations" tiles: mounted shares and mapped drives.
    func driveTiles() -> [NetworkTileView] {
        guard let window else { return [] }
        let center = NetworkCenter.shared
        var tiles: [NetworkTileView] = []
        var shown = Set<String>()
        for drive in center.drives.drives {
            let status = center.status(of: drive)
            let tile: NetworkTileView
            switch status {
            case .connected(let share):
                shown.insert(share.mountPoint.path)
                tile = Self.connectedTile(id: "drive/\(drive.id)", title: drive.label, share: share)
                tile.onOpen = { [weak window] in window.map { _ = NetworkConnectFlow.open(drive.address, in: $0) } }
                tile.onOpenInNewTab = { [weak window] in window.map { _ = NetworkConnectFlow.open(drive.address, in: $0, newTab: true) } }
                tile.menuProvider = { [weak self] in self?.menu(NetworkMenus.connectedDriveItems(share, drive: drive, window: window)) }
            case .connecting:
                tile = NetworkTileView(id: "drive/\(drive.id)", icon: NetworkIcons.drive(48, disconnected: true), title: drive.label,
                                       caption: L10n.tr("Connecting…"))
            case .disconnected(let reason):
                let link = LinkButton(L10n.tr("Reconnect")) { [weak window] in
                    guard let window else { return }
                    _ = NetworkConnectFlow.open(drive.address, in: window)
                }
                tile = NetworkTileView(id: "drive/\(drive.id)", icon: NetworkIcons.drive(48, disconnected: true), title: drive.label,
                                       caption: reason == nil ? L10n.tr("Disconnected") : L10n.tr("Unavailable"), link: link)
                tile.toolTip = reason
                tile.onOpen = { [weak window] in window.map { _ = NetworkConnectFlow.open(drive.address, in: $0) } }
                tile.menuProvider = { [weak self] in self?.menu(NetworkMenus.disconnectedDriveItems(drive, window: window)) }
            }
            tiles.append(tile)
        }
        for share in center.mountedShares() where !shown.contains(share.mountPoint.path) {
            let name = share.address?.driveLabel ?? share.volumeName
            let tile = Self.connectedTile(id: "share/\(share.mountPoint.path)", title: name, share: share)
            tile.onOpen = { [weak window] in window?.navigate(to: .folder(share.mountPoint)) }
            tile.onOpenInNewTab = { [weak window] in window?.openTab(.folder(share.mountPoint)) }
            tile.menuProvider = { [weak self] in self?.menu(NetworkMenus.connectedDriveItems(share, drive: nil, window: window)) }
            tiles.append(tile)
        }
        return tiles
    }
}

extension NetworkTilesPage {
    /// Explorer's drive tile: name, capacity bar, "X free of Y" (capacity read off the main thread).
    static func connectedTile(id: String, title: String, share: MountedShare) -> NetworkTileView {
        let tile: NetworkTileView
        if let cap = NetworkCenter.shared.capacity(of: share) {
            tile = NetworkTileView(id: id, icon: NetworkIcons.drive(48), title: title,
                                   caption: L10n.format("%@ free of %@", "\(StatusText.bytes(cap.free))", "\(StatusText.bytes(cap.total))"),
                                   capacity: Double(cap.total - cap.free) / Double(cap.total))
        } else {
            tile = NetworkTileView(id: id, icon: NetworkIcons.drive(48), title: title, caption: L10n.tr("Network drive"))
        }
        tile.toolTip = share.mountPoint.path
        return tile
    }
}

// MARK: - Network (FE-078)

/// Bonjour devices grouped like Explorer, plus connected shares and mapped drives. Discovers only while shown.
final class NetworkPageController: NetworkTilesPage {
    private let discovery: NetworkDiscovering
    private var resolving: String?

    override init(host: LocationHost?) {
        discovery = NetworkCenter.shared.services.makeDiscovery()
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { discovery.stop() }

    override func loadView() {
        super.loadView()
        discovery.onChange = { [weak self] in self?.rebuild() }
        discovery.start()
        rebuild()
    }

    override func networkChanged() { rebuild() }

    var devices: [NetworkDevice] { NetworkDiscoveryModel.devices(from: discovery.services) }

    func rebuild() {
        guard isViewLoaded else { return }
        let devices = self.devices
        var sections: [TileSection] = []
        for category in NetworkCategory.allCases {
            let tiles = devices.filter { $0.category == category }.map(tile)
            sections.append(TileSection(id: category.rawValue, title: category.rawValue, tiles: tiles))
        }
        sections.append(TileSection(id: "locations", title: "Network locations", tiles: driveTiles()))
        grid.setSections(sections)

        var bannerViews: [NSView] = []
        switch discovery.state {
        case .needsPermission:
            bannerViews.append(InfoBarView(
                severity: .warning, title: L10n.tr("Network discovery is turned off."),
                message: L10n.tr("Arbor can't see computers on this network until you allow Local Network access in System Settings › Privacy & Security › Local Network. You can still type \\\\server\\share in the address bar."),
                actions: [FluentButton(L10n.tr("Open Settings")) { NetworkFeature.openLocalNetworkSettings() }]))
        case .failed(let message):
            bannerViews.append(InfoBarView(severity: .error, title: L10n.tr("Looking for computers failed."), message: message,
                                           actions: [FluentButton(L10n.tr("Try Again")) { [weak self] in self?.restartDiscovery() }]))
        default:
            break
        }
        setBanner(bannerViews)
        if grid.allTiles.isEmpty || devices.isEmpty {
            switch discovery.state {
            case .searching, .idle:
                grid.emptyView = searchingView()
            case .ready:
                grid.emptyView = emptyLabel(L10n.tr("No computers were found on this network. Type \\\\server\\share in the address bar, or use Map network drive in the “…” menu."))
            default:
                grid.emptyView = nil
            }
        } else {
            grid.emptyView = nil
        }
        window?.updateChrome()
    }

    private func searchingView() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, emptyLabel(L10n.tr("Looking for computers and devices on this network…"))])
        row.spacing = 8
        return row
    }

    private func restartDiscovery() {
        discovery.stop()
        discovery.start()
        rebuild()
    }

    private func tile(_ device: NetworkDevice) -> NetworkTileView {
        let tile = NetworkTileView(id: device.id, icon: NetworkIcons.icon(for: device, size: 48), title: device.name, caption: device.subtitle)
        if device.preferredScheme != nil {
            tile.onOpen = { [weak self] in self?.open(device, newTab: false) }
            tile.onOpenInNewTab = { [weak self] in self?.open(device, newTab: true) }
            tile.menuProvider = { [weak self] in
                guard let self else { return nil }
                return self.menu([
                    ClosureMenuItem(L10n.tr("Open")) { [weak self] in self?.open(device, newTab: false) },
                    ClosureMenuItem(L10n.tr("Open in new tab")) { [weak self] in self?.open(device, newTab: true) },
                    .separator(),
                    ClosureMenuItem(L10n.tr("Map network drive…")) { [weak self] in
                        guard let self, let window = self.window else { return }
                        NetworkCenter.shared.services.resolve(device) { address in
                            MapNetworkDriveSheet.present(in: window, folder: address.map { $0.unc + "\\" })
                        }
                    },
                ])
            }
        } else {
            tile.toolTip = L10n.format("%@ is a network device without shared folders.", "\(device.name)")
            tile.onOpen = { [weak self] in self?.host?.showStatusMessage(L10n.format("“%@” doesn't share folders.", "\(device.name)"), isError: false) }
        }
        return tile
    }

    /// Resolves the Bonjour name to a host, then shows its shared folders.
    func open(_ device: NetworkDevice, newTab: Bool) {
        resolving = device.id
        host?.showStatusMessage(L10n.format("Connecting to %@…", "\(device.name)"), isError: false)
        NetworkCenter.shared.services.resolve(device) { [weak self] address in
            guard let self, self.resolving == device.id else { return }
            self.resolving = nil
            guard let address else {
                self.host?.showStatusMessage(L10n.format("Arbor can't find the address of “%@”. It may have left the network.", "\(device.name)"), isError: true)
                return
            }
            self.host?.showStatusMessage(nil, isError: false)
            if newTab { self.host?.openInNewTab(.server(address)) } else { self.host?.navigate(to: .server(address), select: []) }
        }
    }

    /// For scripted checks.
    var debugSummary: String {
        let sections = grid.sections.map { s in "\(s.title)[\(s.tiles.map(\.titleText).joined(separator: ", "))]" }
        return "network page: state=\(discovery.state) " + sections.joined(separator: " ")
            + " banner=\(banner.arrangedSubviews.count) empty=\(grid.emptyView.map { $0.collectLabels().joined() } ?? "-")"
    }
}

// MARK: - A server's shared folders (FE-176)

final class ServerPageController: NetworkTilesPage {
    let server: NetworkAddress
    private var request: NetworkCancellable?
    private(set) var state = "loading"
    private var shares: [NetworkShareInfo] = []
    private var timeout: DispatchWorkItem?

    init(server: NetworkAddress, host: LocationHost?) {
        self.server = server
        super.init(host: host)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        request?.cancel()
        timeout?.cancel()
    }

    override func loadView() {
        super.loadView()
        load()
    }

    override func networkChanged() { if state == "ready" { rebuild() } }

    func load() {
        request?.cancel()
        timeout?.cancel()
        state = "loading"
        grid.setSections([])
        setBanner([])
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, emptyLabel(L10n.format("Looking for shared folders on %@…", "\(server.hostDisplayName)"))])
        row.spacing = 8
        grid.emptyView = row
        // FE-179: an unresponsive server times out with Retry; the UI stays usable.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == "loading" else { return }
            self.request?.cancel()
            self.fail(.timedOut(self.server.unc))
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NetworkCenter.shared.listingTimeout, execute: work)
        request = NetworkCenter.shared.services.listShares(on: server) { [weak self] result in
            guard let self, self.state == "loading" else { return }
            self.timeout?.cancel()
            switch result {
            case .success(let shares):
                self.shares = shares
                self.state = "ready"
                self.rebuild()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func fail(_ error: NetworkError) {
        state = "error: \(error.localizedDescription)"
        grid.setSections([])
        grid.emptyView = nil
        var actions: [NSView] = [FluentButton(L10n.tr("Retry"), primary: true) { [weak self] in self?.load() }]
        switch error {
        case .authenticationFailed, .listingUnsupported, .noShares:
            // System sign-in and share chooser (NetFS); credentials stay in the Keychain.
            actions.insert(FluentButton(L10n.tr("Connect…")) { [weak self] in self?.connectWithSystemChooser() }, at: 0)
        default:
            break
        }
        let title: String
        switch error {
        case .timedOut: title = "\(server.hostDisplayName) isn't responding."
        case .authenticationFailed: title = L10n.format("Sign in to see the shared folders on %@.", "\(server.hostDisplayName)")
        case .listingUnsupported: title = L10n.format("Shared folders on %@ can't be listed.", "\(server.hostDisplayName)")
        default: title = L10n.format("Arbor can't access %@.", "\(server.unc)")
        }
        setBanner([InfoBarView(severity: error == .listingUnsupported(server.unc) ? .informational : .error,
                               title: title, message: error.localizedDescription, actions: actions)])
        window?.updateChrome()
    }

    /// Mounts via the system UI, which asks for credentials and the share.
    private func connectWithSystemChooser() {
        guard let window else { return }
        _ = NetworkConnectFlow.open(server, in: window)
    }

    func rebuild() {
        guard let window else { return }
        let center = NetworkCenter.shared
        let tiles = shares.map { share -> NetworkTileView in
            let address = server.appending(share.name)
            let mounted = center.existingMount(for: address)
            let tile = NetworkTileView(id: "share/\(share.name)", icon: NetworkIcons.share(48), title: share.name,
                                       caption: mounted != nil ? L10n.tr("Connected") : L10n.tr("Shared folder"),
                                       caption2: share.comment.isEmpty ? nil : share.comment)
            tile.onOpen = { [weak window] in window.map { _ = NetworkConnectFlow.open(address, in: $0) } }
            tile.onOpenInNewTab = { [weak window] in window.map { _ = NetworkConnectFlow.open(address, in: $0, newTab: true) } }
            tile.menuProvider = { [weak self] in
                guard let self else { return nil }
                var items: [NSMenuItem] = [
                    ClosureMenuItem(L10n.tr("Open")) { [weak window] in window.map { _ = NetworkConnectFlow.open(address, in: $0) } },
                    ClosureMenuItem(L10n.tr("Open in new tab")) { [weak window] in window.map { _ = NetworkConnectFlow.open(address, in: $0, newTab: true) } },
                    .separator(),
                    ClosureMenuItem(L10n.tr("Map network drive…")) { [weak window] in window.map { MapNetworkDriveSheet.present(in: $0, folder: address.unc) } },
                    ClosureMenuItem(L10n.tr("Copy network path")) {
                        FileClipboard.shared.writePaths(address.unc)
                        window.statusBar.setMessage(L10n.format("Copied path: \"%@\"", "\(address.unc)"))
                    },
                ]
                if let mounted { items += NetworkMenus.disconnectItems(mounted, window: window) }
                return self.menu(items)
            }
            return tile
        }
        grid.setSections([TileSection(id: "shares", title: "Shared folders", tiles: tiles)])
        grid.emptyView = tiles.isEmpty ? emptyLabel(L10n.format("%@ has no shared folders you can see.", "\(server.hostDisplayName)")) : nil
        window.updateChrome()
    }

    var debugSummary: String {
        "server page \(server.unc): state=\(state) shares=[\(grid.allTiles.map { "\($0.titleText) (\($0.captionText))" }.joined(separator: ", "))]"
            + " banner=\(banner.collectLabels().joined(separator: " / "))"
    }
}

// MARK: - Shared menu items

enum NetworkMenus {
    static func connectedDriveItems(_ share: MountedShare, drive: MappedDrive?, window: BrowserWindowController) -> [NSMenuItem] {
        [ClosureMenuItem(L10n.tr("Open")) { [weak window] in window?.navigate(to: .folder(share.mountPoint)) },
         ClosureMenuItem(L10n.tr("Open in new tab")) { [weak window] in window?.openTab(.folder(share.mountPoint)) },
         .separator()] + disconnectItems(share, window: window)
    }

    static func disconnectItems(_ share: MountedShare, window: BrowserWindowController) -> [NSMenuItem] {
        [ClosureMenuItem(L10n.tr("Disconnect")) { [weak window] in window.map { NetworkDisconnect.disconnect(share, window: $0) } }]
    }

    static func disconnectedDriveItems(_ drive: MappedDrive, window: BrowserWindowController) -> [NSMenuItem] {
        [ClosureMenuItem(L10n.tr("Reconnect")) { [weak window] in window.map { _ = NetworkConnectFlow.open(drive.address, in: $0) } },
         ClosureMenuItem(L10n.tr("Reconnect using different credentials…")) { [weak window] in
             window.map { _ = NetworkConnectFlow.open(drive.address, in: $0, differentCredentials: true) }
         },
         .separator(),
         ClosureMenuItem(L10n.tr("Disconnect")) { NetworkCenter.shared.disconnect(drive) }]
    }
}
