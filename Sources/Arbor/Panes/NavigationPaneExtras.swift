import AppKit
import ArborCore

/// Extra top-level nodes features add to the navigation pane, e.g. cloud roots after Gallery (where
/// Explorer shows OneDrive) and the Trash after Network. Builders run on every rebuild, so keep them cheap.
///
///     NavigationPaneExtras.register(.afterNetwork) { [NavNode(kind: .place, title: "Trash", location: .trash)] }
enum NavigationPaneExtras {
    enum Position { case afterGallery, afterNetwork }

    private static var builders: [(Position, () -> [NavNode])] = []

    static func register(_ position: Position, _ builder: @escaping () -> [NavNode]) {
        builders.append((position, builder))
    }

    static func nodes(_ position: Position) -> [NavNode] {
        builders.filter { $0.0 == position }.flatMap { $0.1() }
    }

    /// Rebuilds the pane in every window (after a node's icon or the set of nodes changed).
    /// Coalesced: a disk image mount posts several changes, and each rebuild reads names on the main thread.
    static func refreshAll() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { refreshAllNow() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private static var pendingRefresh: DispatchWorkItem?

    private static func refreshAllNow() {
        for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] {
            controller.navPane.rebuild()
            controller.navPane.reveal(controller.activeTab.displayedLocation ?? controller.location)
        }
    }
}
