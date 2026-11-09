import AppKit
import ArborCore

/// Script steps and log line for the Tags section (TESTING.md):
///
///     tagcatalog:Work=4|Home=0    replace the whole list, so rows don't depend on this Mac's labels
///     treeexpand:Work             expand the tree row with that title
///     taglabels:Red=FF0000|Blue=  replace the system labels and colours, as a change in Finder's settings would
enum FinderTagsDebug {
    static func register() {
        DebugScript.registerStep("tagcatalog") { arg, _ in
            var catalog = TagCatalog(systemLabels: [])
            for entry in arg.split(separator: "|") {
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first else { continue }
                catalog.insert(FinderTag(name: name, colorIndex: parts.count > 1 ? Int(parts[1]) ?? 0 : 0))
            }
            FinderTagStore.shared.setCatalog(catalog)
            return 0.4
        }
        DebugScript.registerStep("treeexpand") { arg, window in
            if let pane = window?.navPane, let node = pane.visibleNode(where: { $0.title == arg }) { pane.outline.expandItem(node) }
            return 0.4
        }
        DebugScript.registerStep("taglabels") { arg, _ in
            let labels = arg.split(separator: "|").map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) }
            FinderTagStore.shared.updateLabels(names: labels.map { $0[0] }, colors: labels.map { $0.count > 1 ? UInt32($0[1], radix: 16) : nil })
            return 0.4
        }
        DebugScript.registerLogger("finder-tags.log") { window in
            let store = FinderTagStore.shared
            let rows = store.catalog.tags.map { "\($0.name):\($0.colorIndex)" }.joined(separator: ",")
            let outline = window.navPane.outline
            let root = window.navPane.visibleNode { $0.location == FinderTagsFeature.rootLocation }
            let state = root.map { outline.isItemExpanded($0) ? "expanded" : "collapsed" } ?? "absent"
            let selected = (outline.item(atRow: outline.selectedRow) as? NavNode)?.title ?? "-"
            return "finder-tags: \(state) rows=\(rows) discoveries=\(store.runCount) marked=\(selected) refreshes=\(store.refreshRequests) changes=\(store.changeCount)"
        }
    }
}
