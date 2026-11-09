import AppKit
import ArborCore

/// Provider hand-off, account labels and what each provider really reports (FE-192, FE-195, FE-198). See docs/features/cloud.md.
enum CloudProvidersFeature: ExplorerFeature {
    static let id = "cloud-providers"
    static let requires = ["cloud"]

    static func register() {
        CommandRegistry.shared.register(ExplorerCommand(
            id: "cloud.openProvider", title: "Open provider", symbol: "arrow.up.forward.app",
            tooltip: "Open the provider's own app to fix this",
            // Not in the menu bar, which would list it greyed under a placeholder name whenever nothing is wrong.
            placements: [.itemContextMenu(CloudFeature.section, 30), .treeContextMenu(CloudFeature.section, 30)],
            dynamicTitle: { ctx in CloudProviderHandoff.target(ctx)?.title ?? L10n.tr("Open provider") },
            isAvailable: { ctx in CloudProviderHandoff.target(ctx) != nil },
            perform: CloudProviderHandoff.perform))
        NavigationPaneHooks.decorateCell.observe("cloud-providers.root-details") { cell, node in
            guard node.kind == .folder, let url = node.url?.standardizedFileURL,
                  let root = CloudEnvironment.roots.first(where: { $0.url == url }) else { return }
            cell.textField?.toolTip = CloudRootDescription.tooltip(root, probe: CloudCapabilityStore.shared.probe(for: root))
        }
        // Back from the provider's app, the sign-in may have happened.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            CloudCapabilityStore.shared.forgetSignInFailures()
        }
        DebugScript.registerLogger("cloud-providers.log", describe)
    }

    /// One line per fact, with the tooltips read from the real tree cells.
    private static func describe(_ window: BrowserWindowController) -> String {
        var lines: [String] = []
        let outline = window.navPane.outline
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? NavNode, let url = node.url?.standardizedFileURL,
                  let root = CloudEnvironment.roots.first(where: { $0.url == url }) else { continue }
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NavCellView
            lines.append("cloud node: \(node.title) | tooltip: \((cell?.textField?.toolTip ?? "-").replacingOccurrences(of: "\n", with: " / "))")
            lines.append("cloud icon: \(node.title) | \(cell?.imageView?.image === CloudGlyph.rootIcon(root, size: 16) ? "current" : "stale")")
            lines.append("cloud capability: \(root.displayName) | \(CloudCapabilityStore.shared.probe(for: root)?.logDescription ?? "not-checked")")
        }
        lines.append("cloud marked: \((outline.item(atRow: outline.selectedRow) as? NavNode)?.title ?? "-")")
        guard CloudEnvironment.root(for: window.location) != nil else { return lines.joined(separator: "\n") }
        lines.append("cloud status text: " + window.visibleItems.map {
            "\($0.name)=\(CloudStatusStore.shared.status(for: $0.url)?.title ?? "pending")"
        }.joined(separator: " | "))
        let context = window.context(surface: .menuBar, sender: nil)
        lines.append("cloud refusals: " + ["cloud.download", "cloud.freeUpSpace"].compactMap { id in
            guard let command = CommandRegistry.shared.command(id) else { return nil }
            let probe = NSMenuItem()
            let runs = CommandDispatcher.shared.validate(command, item: probe, context: context)
            return "\(id)=\(runs ? "runs" : probe.toolTip ?? "disabled")"
        }.joined(separator: " | "))
        return lines.joined(separator: "\n")
    }
}

/// The one way from a cloud item to its provider's app. It hands over a table row's constant, never a name or path.
enum CloudProviderHandoff {
    struct Target {
        let handoff: CloudHandoff
        let title: String
        let provider: String
    }

    /// Enough for any real menu; a huge selection must not schedule a read for every item.
    private static let itemsExamined = 64

    /// The first selected item the provider has to fix, if that provider's app (or settings pane) is there to open.
    static func target(_ ctx: CommandContext) -> Target? {
        for item in ctx.selection.prefix(itemsExamined) {
            guard let root = CloudEnvironment.root(containing: item.url), let entry = root.entry else { continue }
            let status = CloudStatusStore.shared.status(for: item.url)
            let needsSignIn: Bool
            if case .signInRequired? = status { needsSignIn = true } else { needsSignIn = CloudCapabilityStore.shared.probe(for: root)?.needsSignIn == true }
            guard needsSignIn || status?.needsProviderHandoff == true,
                  let handoff = entry.handoff(isInstalled: SystemOpen.isInstalled(bundleIdentifier:)) else { continue }
            return Target(handoff: handoff, title: entry.commandTitle(needsSignIn: needsSignIn), provider: entry.displayName)
        }
        return nil
    }

    static func perform(_ ctx: CommandContext) {
        guard let target = target(ctx) else { NSSound.beep(); return }
        let opened: Bool
        switch target.handoff {
        case .application(let identifier): opened = SystemOpen.openApplication(bundleIdentifier: identifier)
        case .settingsPane(let pane): opened = SystemOpen.open(pane)
        }
        if !opened { ctx.window?.statusBar.setMessage(L10n.format("%@ couldn't be opened.", target.provider), isError: true) }
    }
}

/// What each provider root has been seen to report, on the main thread. It only observes results others already read.
final class CloudCapabilityStore {
    static let shared = CloudCapabilityStore()

    private var cache = CloudCapabilityCache()

    func probe(for root: CloudRoot) -> CloudCapabilityProbe? { cache.probe(forRoot: root.url.path, at: Date()) }

    func observe(_ results: [(url: URL, info: UbiquityInfo?)]) {
        guard !CloudEnvironment.roots.isEmpty else { return }
        var changed = false
        let now = Date()
        for (url, info) in results {
            // The provider's own top folder is drawn in the tree; it isn't one of the items it holds.
            guard let root = CloudEnvironment.root(containing: url), url.standardizedFileURL != root.url else { continue }
            if cache.update(root: root.url.path, at: now, { $0.observe(info, item: url.path) }) { changed = true }
        }
        if changed { redrawRoots() }
    }

    func recordListing(_ outcome: CloudEnumeration, of root: CloudRoot) {
        if cache.update(root: root.url.path, at: Date(), { $0.recordListing(outcome) }) { redrawRoots() }
    }

    func forgetSignInFailures() {
        let roots = cache.rootsNeedingSignIn
        guard !roots.isEmpty else { return }
        roots.forEach { cache.invalidate(root: $0) }
        redrawRoots()
    }

    func invalidateAll() { cache.invalidateAll() }

    /// Browsing changes the probe all the time, so this must not rebuild the tree and collapse what the user opened.
    private func redrawRoots() {
        for root in CloudEnvironment.roots {
            NavigationPaneExtras.updateRoot(at: .folder(root.url)) { $0.icon = CloudGlyph.rootIcon(root, size: 16) }
        }
    }
}
