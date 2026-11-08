import AppKit
import ArborCore

/// Folder Options › Navigation pane, plus protected files in the tree ("Hide empty drives" is This Mac's
/// `VolumeCatalog`, which the tree also uses):
/// - Always show availability status: a cloud mark on folders a sync provider owns.
/// - Expand to open folder: the tree opens down to the current folder.
/// - Show all folders: the user's home folder and Trash join the top level (the Mac stand-in for
///   Windows' Desktop root).
enum NavigationPaneOptions {
    static func install() {
        NavigationPaneHooks.adjustRoots.add("folder-options.navigation-roots") { roots in adjustRoots(roots) }
        NavigationPaneHooks.filterChildren.add("folder-options.hide-protected") { items in
            Prefs.hideProtectedSystemFiles ? ProtectedSystemItems.filter(items) : items
        }
        NavigationPaneHooks.willReveal.observe("folder-options.expand-to-open-folder") { pane, location in
            if Prefs.navExpandToOpenFolder { expand(pane.outline, to: location) }
        }
        NavigationPaneHooks.decorateCell.observe("folder-options.tree-cells") { cell, node in decorate(cell, node) }
    }

    // MARK: Roots

    private static func adjustRoots(_ roots: [NavNode]) -> [NavNode] {
        var roots = roots
        if Prefs.navShowAllFolders, let index = roots.firstIndex(where: { $0.kind == .thisMac }) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var extra = [NavNode(kind: .folder, title: displayName(of: home), location: .folder(home))]
            if !roots.contains(where: { $0.location == .trash }) { extra.append(NavNode(kind: .place, title: L10n.tr("Trash"), location: .trash)) }
            roots.insert(contentsOf: extra, at: index + 1)
        }
        return roots
    }

    // MARK: Expand to open folder

    /// Expands the deepest visible ancestor of `location` step by step until its row exists.
    /// Local volumes only, so a slow network share never blocks the tree.
    static func expand(_ outline: NSOutlineView, to location: Location) {
        guard let target = location.folderURL,
              (try? target.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true else { return }
        let targetPath = Location.folder(target).key
        for _ in 0..<64 {
            var best: (row: Int, depth: Int)?
            for r in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: r) as? NavNode, let url = node.url else { continue }
                let key = Location.folder(url).key
                if key == targetPath { return }
                let prefix = key == "folder:/" ? key : key + "/"
                guard targetPath.hasPrefix(prefix) else { continue }
                let depth = key.count
                if best == nil || depth > best!.depth || (depth == best!.depth && node.kind == .favorite) { best = (r, depth) }
            }
            guard let best, let node = outline.item(atRow: best.row) as? NavNode else { return }
            if outline.isItemExpanded(node) {
                // Already open but the child row is missing (hidden or filtered): stop.
                return
            }
            outline.expandItem(node)
        }
    }

    // MARK: Availability status

    private static func decorate(_ cell: NavCellView, _ node: NavNode) {
        let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: L10n.tr("Pinned"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        cell.pin.image = pinImage
        cell.pin.toolTip = nil
        guard node.kind != .favorite, Prefs.navShowAvailabilityStatus, let url = node.url,
              let provider = SyncProviderDetector.provider(forPath: url.path, home: NSHomeDirectory()) else { return }
        cell.pin.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.format("Synced by %@", "\(provider.name)"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        cell.pin.toolTip = L10n.format("Synced by %@", "\(provider.name)")
        cell.pin.isHidden = false
    }
}
