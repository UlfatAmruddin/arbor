import AppKit
import ArborCore

/// Cloud status (FE-189–FE-198, FE-162, FE-113, FE-244). See docs/features/cloud.md.
enum CloudFeature: ExplorerFeature {
    static let id = "cloud"
    static let section = MenuSection(rank: 550, name: "cloud")

    static func register() {
        NavigationPaneExtras.register(.afterGallery, "cloud.roots") {
            CloudEnvironment.roots.map { root in
                let node = NavNode(kind: .folder, title: root.navigationTitle, location: .folder(root.url))
                node.icon = CloudGlyph.rootIcon(root, size: 16)
                return node
            }
        }
        if let sample = CloudEnvironment.roots.first {
            // Root folders get the provider's name and icon (tab, address bar); listing stays with the folder provider.
            LocationRegistry.register(CloudRootProvider(base: LocationRegistry.provider(for: .folder(sample.url))))
        }
        // Early, so a cloud folder inside a mounted network share still gets cloud crumbs.
        Breadcrumbs.register("cloud.crumbs", order: .early) { location in
            guard let url = location.folderURL, let root = CloudEnvironment.root(containing: url) else { return nil }
            return crumbs(for: url, in: root)
        }
        DetailsColumns.register("cloud.status-column") { location in CloudEnvironment.root(for: location) != nil ? layout : nil }
        ItemBadges.register("cloud.status-badge") { item in
            guard CloudEnvironment.root(containing: item.url) != nil,
                  let status = CloudStatusStore.shared.status(for: item.url), status != .unknown else { return nil }
            return CloudGlyph.image(status, size: 16)
        }
        TransferPreflight.register("cloud.download-first", hydrationPrompt)
        SidePaneRegistry.wrappers.add("cloud.preview-gate") { pane, id in
            id == "preview" ? CloudAwarePreviewPane(wrapping: pane) : pane
        }
        registerCommands()
        registerDebugHooks()

        NotificationCenter.default.addObserver(forName: CloudStatusStore.changed, object: nil, queue: .main) { _ in
            for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] where CloudEnvironment.root(for: controller.location) != nil {
                controller.itemView?.reloadRows()
                controller.updateChrome()
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                if CloudEnvironment.refresh() { NavigationPaneExtras.refreshAll() }
            }
        }
    }

    // MARK: Details: Name · Status · Date modified · Type · Size (windows11-reference.md §5.1)

    static let layout = DetailsLayout(
        id: "cloud",
        order: ["name", "cloudStatus", "dateModified", "type", "size"],
        extras: [
            DetailsColumnSpec(id: "cloudStatus", title: "Status", width: 64, minWidth: 44, alignment: .left) { table, item in
                let cell = CloudStatusCell.make(table)
                cell.show(CloudStatusStore.shared.status(for: item.url))
                return cell
            },
        ])

    // MARK: Breadcrumbs: "iCloud Drive › Folder" instead of the Library path

    static func crumbs(for url: URL, in root: CloudRoot) -> [Crumb] {
        var chain: [URL] = []
        var current = url.standardizedFileURL
        while root.contains(current) {
            chain.insert(current, at: 0)
            if current == root.url { break }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return chain.map { folder in
            let location = Location.folder(folder)
            let title = folder == root.url ? root.displayName : LocationRegistry.provider(for: location).title(for: location)
            return Crumb(title: title, location: location, children: { Breadcrumbs.subfolderChildren(of: folder) })
        }
    }

    // MARK: Copying out of the cloud (FE-113)

    /// Copying out downloads online-only content: ask first for folders (unchecked) or online-only files.
    /// Moves within the same provider folder are renames and never ask.
    static func hydrationPrompt(_ kind: TransferKind, _ sources: [URL], _ destination: URL) -> TransferPreflight.Prompt? {
        let cloudSources = sources.prefix(200).filter { CloudEnvironment.root(containing: $0) != nil }
        guard let first = cloudSources.first, let root = CloudEnvironment.root(containing: first) else { return nil }
        if kind == .move, cloudSources.allSatisfy({ CloudEnvironment.root(containing: $0) == CloudEnvironment.root(containing: destination) }) {
            return nil
        }
        let folders = cloudSources.filter { FileOps.isPlainFolder($0) }
        let onlineOnly = cloudSources.filter { !folders.contains($0) && CloudStatusStore.shared.status(for: $0) == .onlineOnly }
        guard !folders.isEmpty || !onlineOnly.isEmpty else { return nil }
        let verb = kind == .move ? "move" : "copy"
        let subject: String
        if folders.count + onlineOnly.count == 1 {
            subject = "“\((folders.first ?? onlineOnly[0]).lastPathComponent)” is"
        } else {
            subject = "\(folders.count + onlineOnly.count) of these items are"
        }
        let what = folders.isEmpty ? "available only online, so \(onlineOnly.count == 1 ? "it" : "they") must be downloaded"
                                   : "in \(root.displayName). Any files in \(folders.count == 1 ? "it" : "them") that are only available online will be downloaded"
        return TransferPreflight.Prompt(
            message: L10n.format("Download from %@ to %@ %@?", "\(root.displayName)", "\(verb)", "\(cloudSources.count == 1 ? "this item" : "these items")"),
            info: "\(subject) \(what) to this Mac before they're \(kind == .move ? "moved" : "copied"). This can take a while and use storage space.",
            confirmTitle: kind == .move ? L10n.tr("Download and Move") : L10n.tr("Download and Copy"))
    }

    // MARK: Commands (FE-191): only what the system lets a third-party app request

    static func cloudItems(_ ctx: CommandContext) -> [FileItem] {
        ctx.selection.filter { CloudEnvironment.root(containing: $0.url) != nil }
    }

    /// Items the system reports as ubiquitous (provider actions apply to them).
    static func providerItems(_ ctx: CommandContext) -> [FileItem] {
        cloudItems(ctx).filter { CloudStatusStore.shared.entry(for: $0.url)?.ubiquitous == true }
    }

    /// What the provider has been seen not to support, for Download and Free up space (FE-198).
    static func providerLimitation(_ ctx: CommandContext) -> String? {
        guard let first = cloudItems(ctx).first, let root = CloudEnvironment.root(containing: first.url) else { return nil }
        return CloudCapabilityStore.shared.probe(for: root)?.commandLimitation(provider: root.provider)
    }

    private static func registerCommands() {
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "cloud.download", title: "Download to this device", symbol: "icloud.and.arrow.down",
                tooltip: "Download the selected items' content to this Mac",
                placements: [.itemContextMenu(section, 10), .mainMenu("File", section, 10)],
                isAvailable: { ctx in ctx.surface == .menuBar ? !cloudItems(ctx).isEmpty : !providerItems(ctx).isEmpty },
                isEnabled: { ctx in providerLimitation(ctx) == nil && providerItems(ctx).contains { $0.isFolder || CloudStatusStore.shared.status(for: $0.url)?.isLocal != true } },
                limitation: providerLimitation,
                perform: { ctx in run(.download, providerItems(ctx), window: ctx.window) }),
            ExplorerCommand(
                id: "cloud.freeUpSpace", title: "Free up space", symbol: "icloud.and.arrow.up",
                tooltip: "Remove the downloaded copies; the items stay available when online",
                placements: [.itemContextMenu(section, 20), .mainMenu("File", section, 20)],
                isAvailable: { ctx in ctx.surface == .menuBar ? !cloudItems(ctx).isEmpty : !providerItems(ctx).isEmpty },
                isEnabled: { ctx in providerLimitation(ctx) == nil && providerItems(ctx).contains { $0.isFolder || CloudStatusStore.shared.status(for: $0.url) != .onlineOnly } },
                limitation: providerLimitation,
                perform: { ctx in run(.evict, providerItems(ctx), window: ctx.window) }),
            ExplorerCommand(
                id: "go.iCloudDrive", title: "iCloud Drive", shortcut: Shortcut("i", [.command, .shift]),
                placements: [.mainMenu("Go", .places, 65)],
                isAvailable: { _ in CloudEnvironment.iCloudRoot != nil },
                perform: { ctx in
                    guard let root = CloudEnvironment.iCloudRoot else { return }
                    if let window = ctx.window { window.navigate(to: .folder(root.url)) }
                    else { (NSApp.delegate as? AppDelegate)?.openWindow(at: .folder(root.url)) }
                }),
        ])
    }

    enum Action { case download, evict }

    /// Reports request errors at once, then polls (bounded) for the state the items actually reach.
    static func run(_ action: Action, _ items: [FileItem], window: BrowserWindowController?) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let urls = items.map(\.url)
        let provider = CloudEnvironment.root(containing: urls[0])?.displayName ?? "the provider"
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var accepted: [URL] = []
            for url in urls {
                do {
                    switch action {
                    case .download: try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    case .evict: try FileManager.default.evictUbiquitousItem(at: url)
                    }
                    accepted.append(url)
                } catch {
                    failures.append("• \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                CloudStatusStore.shared.invalidate(urls)
                if !failures.isEmpty {
                    NSAlert.show(action == .download ? "\(provider) couldn't download \(failures.count == 1 ? "1 item" : "\(failures.count) items")."
                                                     : "\(provider) couldn't free up space for \(failures.count == 1 ? "1 item" : "\(failures.count) items").",
                                 failures.prefix(10).joined(separator: "\n"), in: window?.window)
                }
                guard !accepted.isEmpty else { return }
                window?.statusBar.setMessage(action == .download
                    ? "Downloading \(StatusText.items(accepted.count)) from \(provider)…"
                    : "Asked \(provider) to free up space for \(StatusText.items(accepted.count))…")
                follow(action, accepted, provider: provider, window: window, started: Date())
            }
        }
    }

    private static func follow(_ action: Action, _ urls: [URL], provider: String, window: BrowserWindowController?, started: Date) {
        CloudStatusStore.shared.read(urls) { [weak window] statuses in
            CloudStatusStore.shared.invalidate(urls)
            let done = statuses.filter { action == .download ? $0.isLocal == true : $0 == .onlineOnly }.count
            let errors = statuses.filter(\.isFailure).count
            if done == urls.count {
                window?.statusBar.setMessage(action == .download
                    ? "\(StatusText.items(done)) now available on this device."
                    : "Freed up space: \(StatusText.items(done)) now available when online.")
            } else if errors > 0 {
                window?.statusBar.setMessage(L10n.format("%@ reported a problem with %@. See the Status column.", "\(provider)", "\(StatusText.items(errors))"), isError: true)
            } else if Date().timeIntervalSince(started) > (action == .download ? 120 : 20) {
                window?.statusBar.setMessage(L10n.format("%@ of %@ done so far. The Status column shows the current state.", "\(StatusText.items(done))", "\(urls.count)"))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { follow(action, urls, provider: provider, window: window, started: started) }
            }
        }
    }

    // MARK: Scripted checks

    private static func registerDebugHooks() {
        DebugScript.registerLogger("cloud.log") { window in
            var text = "cloud roots: " + CloudEnvironment.roots.map { "\($0.displayName) [\($0.kind.rawValue)]" }.joined(separator: ", ")
            guard let root = CloudEnvironment.root(for: window.location) else { return text }
            text += "\ncloud folder: \(root.displayName)"
            if let details = window.itemView as? DetailsViewController {
                text += " layout=\(DetailsColumns.activeLayoutID(of: details.table) ?? "-")"
                text += " columns=" + details.table.tableColumns.filter { !$0.isHidden }.map(\.title).joined(separator: "|")
            }
            text += "\ncloud statuses: " + window.visibleItems.map {
                "\($0.name)=\(CloudStatusStore.shared.status(for: $0.url)?.shortTitle ?? "pending")"
            }.joined(separator: ", ")
            return text
        }
        // iconpng:<row name>:<path.png> renders that row's 64 pt icon with its status badge.
        DebugScript.registerStep("iconpng") { argument, window in
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let item = window?.visibleItems.first(where: { $0.name == parts[0] }) else { return 0.3 }
            let image = IconProvider.shared.icon(for: item, size: 64)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            }
            return 0.3
        }
    }
}

/// A cloud root under its provider name and icon; the rest goes to the previously registered provider.
final class CloudRootProvider: LocationProvider {
    private let base: LocationProvider
    init(base: LocationProvider) { self.base = base }

    private func root(_ location: Location) -> CloudRoot? {
        guard let url = location.folderURL else { return nil }
        return CloudEnvironment.roots.first { $0.url == url.standardizedFileURL }
    }

    func handles(_ location: Location) -> Bool { root(location) != nil }
    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard let root = root(location) else { return base.load(location, context: context, completion: completion) }
        if let failure = CloudEnvironment.simulatedListingFailure(of: root) {
            let handle = LoadHandle()
            DispatchQueue.main.async { if !handle.isCancelled { self.finish(.failure(failure), root, completion) } }
            return handle
        }
        return base.load(location, context: context) { [self] in finish($0, root, completion) }
    }

    /// The listing the window asked for doubles as the enumeration check, so the provider is never asked twice.
    private func finish(_ result: Result<LocationContent, Error>, _ root: CloudRoot, _ completion: (Result<LocationContent, Error>) -> Void) {
        guard case .failure(let error) = result else {
            CloudCapabilityStore.shared.recordListing(.succeeded, of: root)
            return completion(result)
        }
        let outcome = CloudEnumeration(listingError: error)
        CloudCapabilityStore.shared.recordListing(outcome, of: root)
        if case .signInRequired(let detail) = outcome {
            completion(.failure(CloudSignInNeeded(provider: root.provider, detail: detail)))
        } else {
            completion(result)
        }
    }
    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? { base.watch(location, onChange: onChange) }
    func title(for location: Location) -> String { root(location)?.displayName ?? base.title(for: location) }
    func icon(for location: Location, size: CGFloat) -> NSImage {
        root(location).map { CloudGlyph.rootIcon($0, size: size) } ?? base.icon(for: location, size: size)
    }
    func targetFolder(for location: Location) -> URL? { base.targetFolder(for: location) }
    func allowsItemEditing(in location: Location) -> Bool { base.allowsItemEditing(in: location) }
    func limitation(of action: LocationAction, in location: Location) -> String? { base.limitation(of: action, in: location) }
    func emptyText(for location: Location) -> String { base.emptyText(for: location) }
}
