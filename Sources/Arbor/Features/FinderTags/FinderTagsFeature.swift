import AppKit
import ArborCore

extension Prefs {
    static var navShowTags: Bool { bool("navShowTags", default: true) }
}

/// Tags section of the navigation pane (FE-081); a tag is an ordinary search location. See docs/features/finder-tags.md.
enum FinderTagsFeature: ExplorerFeature {
    static let id = "finder-tags"
    static let requires = ["search"]   // a tag row opens a search location

    static let rootLocation = Location.search(TagCollectionQuery.allTagged)

    private enum Icon {
        static let root: UInt32 = 0x6E6E6E
        static let colorless: UInt32 = 0x8E8E93
    }

    static func register() {
        // After the Libraries node (gallery-libraries.libraries-node, .late).
        NavigationPaneExtras.register(.afterNetwork, "finder-tags.section", order: .last, sectionNodes)
        IconProvider.locationIconOverrides.register("finder-tags.icons") { location, size in icon(for: location, size: size) }
        NavigationPaneHooks.didExpand.observe("finder-tags.refresh-on-expand") { _, node in
            if node.location == rootLocation { FinderTagStore.shared.refreshIfStale() }
        }
        NavigationPaneHooks.willReveal.observe("finder-tags.expand-to-open-collection") { pane, location in
            if Prefs.navExpandToOpenFolder { expandRoot(in: pane, toShow: location) }
        }
        NavigationPaneHooks.decorateCell.observe("finder-tags.cell-label") { cell, node in
            if let name = tagName(of: node.location) { cell.setAccessibilityLabel(L10n.format("%@, tag", "\(name)")) }
        }
        FinderTagStore.shared.onChange = { NavigationPaneExtras.updateChildren(ofRootAt: rootLocation, tagNodes) }
        FinderTagsDebug.register()

        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            guard note.userInfo?["key"] as? String == "navShowTags" else { return }
            if !Prefs.navShowTags { FinderTagStore.shared.cancelDiscovery() }
            NavigationPaneExtras.refreshAll()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didChangeFileLabelsNotification, object: nil, queue: .main) { _ in
            FinderTagStore.shared.labelsChanged()
        }
    }

    // MARK: Nodes

    /// Runs on every rebuild: memory only, so no Spotlight query or disk read until the row is expanded (spec §15.3).
    private static func sectionNodes() -> [NavNode] {
        guard Prefs.navShowTags else { return [] }
        return [NavNode(kind: .folder, title: L10n.tr("Tags"), location: rootLocation, children: tagNodes())]
    }

    private static func tagNodes() -> [NavNode] {
        FinderTagStore.shared.catalog.tags.compactMap { tag in
            TagCollectionQuery.request(for: tag.name).map { NavNode(kind: .place, title: tag.name, location: .search($0)) }
        }
    }

    private static func tagName(of location: Location?) -> String? {
        guard case .search(let request)? = location else { return nil }
        return TagCollectionQuery.tagName(in: request)
    }

    private static func expandRoot(in pane: NavigationPaneController, toShow location: Location) {
        guard tagName(of: location) != nil, let root = pane.visibleNode(where: { $0.location == rootLocation }) else { return }
        pane.outline.expandItem(root)
    }

    // MARK: Icons

    /// No I/O. The cache is keyed by colour, so it can't grow with the number of tag names.
    private static func icon(for location: Location, size: CGFloat) -> NSImage? {
        guard case .search(let request) = location else { return nil }
        let icons = IconProvider.shared
        if request == TagCollectionQuery.allTagged { return icons.symbolIcon("tag.fill", color: Icon.root, size: size) }
        guard let name = TagCollectionQuery.tagName(in: request) else { return nil }
        let store = FinderTagStore.shared
        guard let color = store.catalog.tag(named: name).flatMap(store.colorHex) else {
            return icons.symbolIcon("circle", color: Icon.colorless, size: size)
        }
        return icons.symbolIcon("circle.fill", color: color, size: size)
    }
}
