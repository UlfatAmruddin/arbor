import AppKit
import ArborCore

/// Network: the Network page, servers and shares, Map/Disconnect network drive, network folders
/// that time out instead of hanging, and `\\server\share` in the address bar (FE-014, FE-078,
/// FE-176–FE-179, FE-187, FE-188). See docs/features/network.md.
enum NetworkFeature: ExplorerFeature {
    static let id = "network"
    /// This Mac lists mapped drives and its page reloads on network changes.
    static let requires = ["this-mac"]
    static let section = MenuSection(rank: 510, name: "network")

    static func register() {
        let center = NetworkCenter.shared
        LocationRegistry.register(NetworkPageProvider())
        LocationRegistry.register(ServerProvider())
        LocationRegistry.register(NetworkFolderProvider())
        NetworkThisMac.register()

        // A disconnected mapped drive's row in This Mac reconnects when opened.
        LocationRegistry.registerOpenHandler("network.disconnected-drive") { item in
            NetworkThisMac.drive(forPlaceholder: item.url).map { .server($0.address) }
        }

        // FE-014: typed `\\server\share` / `smb://…` connects and navigates after the mount.
        BrowserWindowController.networkAddressHandler.register("network.typed-address", handles: { window, url in
            guard let address = NetworkAddress(url: url) else { return false }
            window.navigate(to: .server(address))
            return true
        })

        // A tab inside a network share that went away stays put with "disconnected" + Reconnect (all tabs).
        BrowserWindowController.volumeUnmountHandler.register("network.keep-disconnected-tabs", handles: { window, tab, _ in
            NetworkCenter.shared.invalidateMounts()
            guard let url = tab.location.folderURL, NetworkCenter.shared.disconnectedShare(containing: url) != nil else { return false }
            if tab === window.activeTab { window.statusBar.setMessage(L10n.tr("The network share was disconnected."), isError: true) }
            window.request(.reload, tab: tab)
            return true
        })

        AddressBar.editTextProviders.register("network.unc-path") { location in
            switch location {
            case .server(let address): return address.unc
            case .folder(let url):
                let center = NetworkCenter.shared
                return (center.share(containing: url) ?? center.disconnectedShare(containing: url))?.address(of: url)?.unc
            default: return nil
            }
        }

        IconProvider.itemIconOverrides.register("network.drive-icons") { item, size in
            let key = Location.normalizedKey(item.url)
            if NetworkThisMac.snapshot.disconnected.contains(where: { Location.normalizedKey($0.url) == key }) {
                return NetworkIcons.drive(size, disconnected: true)
            }
            guard item.isFolder, key.hasPrefix("/") else { return nil }
            return NetworkCenter.shared.mountedShares().contains { Location.normalizedKey($0.mountPoint) == key } ? NetworkIcons.drive(size) : nil
        }
        IconProvider.locationIconOverrides.register("network.drive-icons") { location, size in
            if case .server(let address) = location, !address.isServer {
                return NetworkIcons.drive(size, disconnected: NetworkCenter.shared.existingMount(for: address) == nil)
            }
            guard let url = location.folderURL else { return nil }
            let key = Location.normalizedKey(url)
            if NetworkThisMac.snapshot.disconnected.contains(where: { Location.normalizedKey($0.url) == key }) {
                return NetworkIcons.drive(size, disconnected: true)
            }
            return NetworkCenter.shared.mountedShares().contains { Location.normalizedKey($0.mountPoint) == key } ? NetworkIcons.drive(size) : nil
        }

        Breadcrumbs.register("network.crumbs") { location in crumbs(for: location) }

        registerCommands()
        registerDebugSteps()

        // Redraw navigation panes when mapped drives change state.
        NotificationCenter.default.addObserver(forName: NetworkCenter.changed, object: nil, queue: .main) { _ in
            NetworkThisMac.refresh()
            NavigationPaneExtras.refreshAll()
        }
        DispatchQueue.main.async { center.reconnectAtLaunch() }
    }

    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            SystemOpen.open(url)
        }
    }

    // MARK: Breadcrumbs: Network › NAS-01 › Media › Movies

    static func crumbs(for location: Location) -> [Crumb]? {
        let network = Crumb(title: L10n.tr("Network"), location: .network, children: { [] })
        switch location {
        case .server(let address):
            var crumbs = [network, serverCrumb(address.server)]
            if let share = address.share {
                var current = address.server.appending(share)
                crumbs.append(Crumb(title: share, location: .server(current), children: { [] }))
                for part in address.path {
                    current = current.appending(part)
                    crumbs.append(Crumb(title: part, location: .server(current), children: { [] }))
                }
            }
            return crumbs
        case .folder(let url):
            let center = NetworkCenter.shared
            guard let share = center.share(containing: url) ?? center.disconnectedShare(containing: url),
                  let address = share.address else { return nil }
            var crumbs = [network, serverCrumb(address.server)]
            var folder = share.mountPoint
            crumbs.append(Crumb(title: address.share ?? share.volumeName, location: .folder(folder), children: { [folder] in childFolders(folder) }))
            for part in share.address(of: url)?.path.dropFirst(address.path.count) ?? [] {
                folder = folder.appendingPathComponent(part)
                crumbs.append(Crumb(title: part, location: .folder(folder), children: { [folder] in childFolders(folder) }))
            }
            return crumbs
        default:
            return nil
        }
    }

    private static func serverCrumb(_ server: NetworkAddress) -> Crumb {
        Crumb(title: server.hostDisplayName, location: .server(server), children: {
            NetworkCenter.shared.mountedShares().filter { $0.address?.sameServer(as: server) ?? false }.map {
                CrumbChild(title: $0.address?.share ?? $0.volumeName, location: .folder($0.mountPoint), icon: NetworkIcons.drive(16))
            }
        })
    }

    /// A chevron's subfolders on a share, read with a short deadline so a hung share can't freeze the menu.
    private static func childFolders(_ folder: URL) -> [CrumbChild] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let hidden = Prefs.showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = (try? DirectoryLister.subfolders(of: folder, includeHidden: hidden)) ?? []
            done.signal()
        }
        guard done.wait(timeout: .now() + 1) == .success else { return [] }
        return box.value.prefix(500).map { CrumbChild(title: $0.name, location: .folder($0.url), icon: IconProvider.shared.folderIcon(.plain, size: 16)) }
    }

    private final class ResultBox: @unchecked Sendable { var value: [FileItem] = [] }

    // MARK: Commands

    static func isNetworkPlace(_ location: Location?) -> Bool {
        switch location {
        case .thisMac?, .network?, .server?: return true
        case .folder(let url)?: return NetworkCenter.shared.share(containing: url) != nil
        default: return false
        }
    }

    /// The network drive a command acts on: the selected (or right-clicked) drive item.
    static func selectedShare(_ ctx: CommandContext) -> MountedShare? {
        guard let item = ctx.single else { return nil }
        let key = Location.normalizedKey(item.url)
        return NetworkCenter.shared.mountedShares().first { Location.normalizedKey($0.mountPoint) == key }
    }

    static func selectedDisconnectedDrive(_ ctx: CommandContext) -> MappedDrive? {
        if ctx.surface == .treeContextMenu, case .server(let address)? = ctx.treeLocation {
            return NetworkCenter.shared.drives.drives.first { $0.address == address }
        }
        if ctx.surface == .treeContextMenu, case .folder(let url)? = ctx.treeLocation { return NetworkThisMac.drive(forPlaceholder: url) }
        guard let item = ctx.single else { return nil }
        return NetworkThisMac.drive(forPlaceholder: item.url)
    }

    static var hasDrivesToDisconnect: Bool {
        !NetworkCenter.shared.mountedShares().isEmpty || !NetworkCenter.shared.drives.drives.isEmpty
    }

    private static func registerCommands() {
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "network.mapDrive", title: "Map network drive", symbol: "externaldrive.badge.plus",
                placements: [.seeMore(section, 10), .treeContextMenu(section, 10), .mainMenu("Go", .tools, 25)],
                dynamicTitle: { ctx in ctx.surface == .menuBar ? L10n.tr("Map Network Drive…") : L10n.tr("Map network drive") },
                isAvailable: { ctx in
                    switch ctx.surface {
                    case .treeContextMenu: return ctx.treeLocation == .thisMac || ctx.treeLocation == .network
                    case .menuBar, .keyboard, .script: return true
                    default: return isNetworkPlace(ctx.location)
                    }
                },
                isEnabled: { $0.window != nil },
                perform: { ctx in
                    guard let window = ctx.window else { return }
                    var folder: String?
                    if case .server(let address)? = ctx.location { folder = address.unc + (address.isServer ? "\\" : "") }
                    MapNetworkDriveSheet.present(in: window, folder: folder)
                }),
            ExplorerCommand(
                id: "network.disconnectDrive", title: "Disconnect network drive", symbol: "externaldrive.badge.minus",
                placements: [.seeMore(section, 20), .treeContextMenu(section, 20)],
                isAvailable: { ctx in
                    switch ctx.surface {
                    case .treeContextMenu: return ctx.treeLocation == .thisMac || ctx.treeLocation == .network
                    case .menuBar, .keyboard, .script: return true
                    default: return isNetworkPlace(ctx.location)
                    }
                },
                isEnabled: { ctx in ctx.window != nil && hasDrivesToDisconnect },
                perform: { ctx in
                    guard let window = ctx.window else { return }
                    if ctx.surface != .treeContextMenu, let share = selectedShare(ctx) {
                        NetworkDisconnect.disconnect(share, window: window)
                    } else {
                        DisconnectDrivesSheet.present(in: window)
                    }
                }),
            ExplorerCommand(
                id: "network.disconnect", title: "Disconnect", symbol: "eject",
                placements: [.itemContextMenu(.share, 85), .treeContextMenu(.share, 85)],
                isAvailable: { ctx in selectedShare(ctx) != nil || selectedDisconnectedDrive(ctx) != nil },
                perform: { ctx in
                    if let share = selectedShare(ctx), let window = ctx.window { NetworkDisconnect.disconnect(share, window: window) }
                    else if let drive = selectedDisconnectedDrive(ctx) { NetworkCenter.shared.disconnect(drive) }
                }),
            ExplorerCommand(
                id: "network.reconnect", title: "Reconnect", symbol: "arrow.clockwise",
                placements: [.itemContextMenu(.open, 15), .treeContextMenu(.open, 15)],
                isAvailable: { selectedDisconnectedDrive($0) != nil },
                perform: { ctx in
                    guard let drive = selectedDisconnectedDrive(ctx), let window = ctx.window else { return }
                    _ = NetworkConnectFlow.open(drive.address, in: window)
                }),
        ])
    }

    // MARK: Scripted checks (TESTING.md)

    private static func registerDebugSteps() {
        DebugScript.registerLogger("network.log") { window in debugLine(window) }
        DebugScript.registerStep("netlog") { path, window in
            append(debugLine(window) + "\n---\n", to: path)
            return 0.3
        }
        // Click a button by title anywhere in the window (pages) or its sheet.
        DebugScript.registerStep("press") { title, window in
            let roots = [window?.window?.attachedSheet?.contentView, window?.window?.contentView]
            if let button = roots.lazy.compactMap({ $0?.findButton(titled: title) }).first { button.performClick(nil) }
            else { NSLog("DebugScript: no button \(title)") }
            return 0.8
        }
        DebugScript.registerStep("mapdrive") { folder, window in
            if let window { MapNetworkDriveSheet.present(in: window, folder: folder.isEmpty ? nil : folder) }
            return 0.8
        }
        DebugScript.registerStep("mapfield") { text, _ in MapNetworkDriveSheet.open?.folderField.stringValue = text; return 0.3 }
        DebugScript.registerStep("mapoptions") { arg, _ in
            // mapoptions:reconnect=0,credentials=1
            for pair in arg.split(separator: ",") {
                let kv = pair.split(separator: "=").map(String.init)
                guard kv.count == 2, let sheet = MapNetworkDriveSheet.open else { continue }
                let state: NSControl.StateValue = kv[1] == "1" ? .on : .off
                if kv[0] == "reconnect" { sheet.reconnect.state = state }
                if kv[0] == "credentials" { sheet.differentCredentials.state = state }
            }
            return 0.3
        }
        DebugScript.registerStep("mapfinish") { _, _ in MapNetworkDriveSheet.open?.finish(); return 1.2 }
        DebugScript.registerStep("mapcancel") { _, _ in MapNetworkDriveSheet.open?.cancel(); return 0.6 }
        DebugScript.registerStep("mapbrowse") { _, window in
            MapNetworkDriveSheet.open?.window?.contentView?.findButton(titled: "Browse…")?.performClick(nil)
            return 1.0
        }
        DebugScript.registerStep("mapbrowsepick") { title, _ in
            if let item = MapNetworkDriveSheet.open?.browseMenuForTests?.items.first(where: { $0.title == title }),
               let action = item.action { _ = (item.target as AnyObject?)?.perform(action, with: item) }
            return 1.2
        }
        DebugScript.registerStep("disconnectcheck") { prefix, _ in DisconnectDrivesSheet.open?.check(prefix); return 0.3 }
        // Double-click (open) a tile on the current network page by title; "nettile:new:Title" opens it in a new tab.
        DebugScript.registerStep("nettile") { arg, window in
            var title = arg, newTab = false
            if arg.hasPrefix("new:") { title = String(arg.dropFirst(4)); newTab = true }
            guard let page = window?.activeTab.page as? NetworkTilesPage,
                  let tile = page.grid.allTiles.first(where: { $0.titleText == title }) else {
                NSLog("DebugScript: no tile \(title)"); return 0.5
            }
            page.grid.select(tile)
            if newTab { tile.onOpenInNewTab?() } else { tile.onOpen?() }
            return 1.2
        }
        DebugScript.registerStep("nettilemenu") { arg, window in
            guard let colon = arg.range(of: ":", options: .backwards) else { return 0.3 }
            let title = String(arg[..<colon.lowerBound]), path = String(arg[colon.upperBound...])
            let page = window?.activeTab.page as? NetworkTilesPage
            let menu = page?.grid.allTiles.first { $0.titleText == title }?.menuProvider?()
            append("tile menu \(title): " + (menu?.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: " | ") ?? "(none)") + "\n", to: path)
            return 0.3
        }
        // Fake network: the server drops a share without the user disconnecting it.
        DebugScript.registerStep("netdrop") { name, _ in
            guard let fake = NetworkCenter.shared.services as? FakeNetworkServices,
                  let share = fake.mountedShares().first(where: { $0.address?.share?.lowercased() == name.lowercased() || $0.mountPoint.path.hasSuffix(name) }) else { return 0.3 }
            fake.dropConnection(share.mountPoint)
            return 0.8
        }
        // Fake network: mark a share busy (open files), e.g. netbusy:NAS-01/Media.
        DebugScript.registerStep("netbusy") { path, _ in
            guard let fake = NetworkCenter.shared.services as? FakeNetworkServices else { return 0.3 }
            FileManager.default.createFile(atPath: fake.root.appendingPathComponent(path).appendingPathComponent(".arbor-busy").path, contents: Data())
            return 0.3
        }
        // `sheetsnapshot:` (the window's sheet as a PNG) is item-actions' step (ItemActionsDebug.swift).
        // Log the text of the sheet or alert on the window.
        DebugScript.registerStep("sheetlog") { path, window in
            let sheet = window?.window?.attachedSheet
            append("sheet: " + (sheet?.contentView?.collectLabels().joined(separator: " / ") ?? "(none)")
                   + " buttons: " + (sheet?.contentView.map(allButtonTitles) ?? []).joined(separator: ", ") + "\n---\n", to: path)
            return 0.3
        }
    }

    private static func allButtonTitles(_ view: NSView) -> [String] {
        ((view as? NSButton).map { [$0.title] } ?? []) + view.subviews.flatMap(allButtonTitles)
    }

    static func debugLine(_ window: BrowserWindowController?) -> String {
        let center = NetworkCenter.shared
        var parts: [String] = ["network: fake=\(center.isFake)"]
        parts.append("mounted=[" + center.mountedShares().map { "\($0.address?.unc ?? "?") at \($0.mountPoint.lastPathComponent)" }.joined(separator: ", ") + "]")
        parts.append("drives=[" + center.drives.drives.map { drive -> String in
            let status: String
            switch center.status(of: drive) {
            case .connected: status = "connected"
            case .connecting: status = "connecting"
            case .disconnected(let reason): status = "disconnected" + (reason.map { " (\($0))" } ?? "")
            }
            return "\(drive.label) user=\(drive.address.user ?? "-") reconnect=\(drive.reconnectAtSignIn) \(status)"
        }.joined(separator: ", ") + "]")
        if let page = window?.activeTab.page {
            if let p = page as? NetworkPageController { parts.append(p.debugSummary) }
            if let p = page as? ServerPageController { parts.append(p.debugSummary) }
            if let p = page as? NetworkMessagePage { parts.append("message page: \(p.titleText) [\(p.actions.map(\.title).joined(separator: ", "))]") }
        }
        if let sheet = MapNetworkDriveSheet.open { parts.append(sheet.debugSummary) }
        if let sheet = DisconnectDrivesSheet.open { parts.append(sheet.debugSummary) }
        return parts.joined(separator: "\n  ")
    }

    private static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
