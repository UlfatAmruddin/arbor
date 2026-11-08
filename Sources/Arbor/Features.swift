import AppKit
import ArborCore

/// What every feature declares (DEC-024, docs/ARCHITECTURE.md "Writing a feature").
protocol ExplorerFeature {
    /// Short, unique, lowercase with dashes ("file-operations"). Contribution ids start with it.
    static var id: String { get }
    /// Features whose registrations this one builds on (it overrides their commands, adds to or wraps
    /// what they register). They register first. Every feature implicitly requires "core".
    static var requires: [String] { get }
    /// Adds the feature's contributions: providers, commands, extension point contributions, script steps.
    static func register()
}

extension ExplorerFeature {
    static var requires: [String] { [] }
}

/// Every feature registers here, once, at launch (before the menu bar and first window are built).
///
/// To add a feature: put its code in its own files, make it `enum MyFeature: ExplorerFeature` with an
/// `id`, its `requires` and `register()`, and add ONE line for it in `all` below (in a free slot, keeping
/// the blank lines so parallel branches merge without conflicts). The order features register in comes
/// from `requires` (a stable sort: otherwise the listed order), never from line order alone.
enum Features {
    static let all: [ExplorerFeature.Type] = [
        CoreFeature.self,

        IconViewsFeature.self,

        DetailsDepth.self,

        HomeFeature.self,

        ThisMacFeature.self,

        SearchFeature.self,

        FileOperationsFeature.self,

        PropertiesFeature.self,   // Properties and Details pane

        ArchiveFeature.self,

        NetworkFeature.self,

        TrashFeature.self,

        CloudFeature.self,

        GalleryLibrariesFeature.self,   // Gallery and Libraries

        FolderOptionsFeature.self,

        ItemActionsFeature.self,   // New menu, shortcuts and batch rename

        AccessibilityFeature.self,

        VisualParityFeature.self,   // visual parity and window chrome

        ConsistencyFeature.self,   // consistency across features

        FileOperationsExtras.self,   // history, queue, verification, Compress to ▸ Additional options

        PerformanceFeature.self,   // memory and responsiveness

        ReliabilityFeature.self,   // behavior and safety checks (undo names, headless safety, alert queue)

        AcceptanceScriptSteps.self,   // script steps and log lines for scripts/acceptance.sh
    ]

    /// The dependency graph of `all` ("core" is added to every other feature's requirements).
    static var graph: [FeatureGraph.Node] {
        all.map { feature in
            let requires = feature.id == CoreFeature.id ? feature.requires : [CoreFeature.id] + feature.requires
            return FeatureGraph.Node(feature.id, requires: requires)
        }
    }

    /// The registration order, or the problem with the list (missing dependency, duplicate id, cycle).
    static func order() throws -> [ExplorerFeature.Type] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return try FeatureGraph.order(graph).compactMap { byID[$0] }
    }

    /// The ids in registration order (empty when the list has a problem).
    private(set) static var registeredOrder: [String] = []

    /// Registers every feature; stops launch with a message naming the problem when the feature list or
    /// a registration is wrong (debug builds already stop at the first extension error).
    static func registerAll() {
        if let problem = registerFeatures() { fatalError("Arbor can't start: \(problem)") }
    }

    /// Registers every feature in dependency order. Returns what went wrong, or nil.
    static func registerFeatures() -> String? {
        let ordered: [ExplorerFeature.Type]
        do {
            ordered = try order()
        } catch {
            return "\(error)"
        }
        let registry = ExtensionRegistry.shared
        for feature in ordered {
            registry.currentFeature = feature.id
            feature.register()
        }
        registry.currentFeature = nil
        registeredOrder = ordered.map { $0.id }
        CommandRegistry.shared.checkOverrides()
        return registry.failureMessage
    }
}

/// Everything the foundation ships: commands, the Details view, Preview/Details panes, folder
/// browsing, and placeholder pages for locations that later features implement.
enum CoreFeature: ExplorerFeature {
    static let id = "core"

    static func register() {
        NavigationCommands.register()
        TabCommands.register()
        FileCommands.register()
        ClipboardCommands.register()
        ViewCommands.register()

        ViewModeRegistry.register([.details]) { DetailsViewController() }
        ExtensionCatalog.registerScriptStep()

        SidePaneRegistry.register(SidePaneDescriptor(id: "preview", title: "Preview pane") { PreviewPane() })
        SidePaneRegistry.register(SidePaneDescriptor(id: "details", title: "Details pane") { DetailsPane() })

        // Placeholders first; real providers registered later win.
        LocationRegistry.register(PlaceholderProvider(locations: { location in
            switch location {
            case .gallery, .network, .trash, .library, .archive, .search: return true
            default: return false
            }
        }))
        LocationRegistry.register(HomeProvider())
        LocationRegistry.register(ThisMacProvider())
        LocationRegistry.register(FolderProvider())
    }
}
