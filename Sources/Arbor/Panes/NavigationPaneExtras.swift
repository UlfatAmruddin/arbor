import AppKit
import ArborCore

/// Extra top-level nodes from features (cloud roots after Gallery, Trash after Network).
/// Builders run on every rebuild, so keep them cheap.
///
///     NavigationPaneExtras.register(.afterNetwork, "trash.navigation-node") { [NavNode(kind: .place, title: "Trash", location: .trash)] }
enum NavigationPaneExtras {
    enum Position { case afterGallery, afterNetwork }

    /// Each contribution appends its nodes for its position, in run order.
    static let builders = Pipeline<[NavNode], Position>(
        "NavigationPaneExtras.builders", "Extra top-level tree nodes after Gallery or after Network.",
        signature: "(nodes, position) -> nodes")

    static func register(_ position: Position, _ id: String, order: ExtensionOrder = .normal,
                         _ builder: @escaping () -> [NavNode]) {
        builders.add(id, order: order) { nodes, asked in asked == position ? nodes + builder() : nodes }
    }

    static func nodes(_ position: Position) -> [NavNode] { builders.apply([], position) }

    /// Rebuilds the pane in every window. Coalesced: one disk image mount posts several changes.
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
