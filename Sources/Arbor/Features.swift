import AppKit
import ArborCore

/// What every feature declares (DEC-024, docs/ARCHITECTURE.md "Writing a feature").
protocol ExplorerFeature {
    /// Short, unique, lowercase with dashes ("file-operations"). Contribution ids start with it.
    static var id: String { get }
    /// Features this one builds on; they register first. "core" is always implied.
    static var requires: [String] { get }
    /// Registers providers, commands, extension contributions and script steps.
    static func register()
}

extension ExplorerFeature {
    static var requires: [String] { [] }
}

/// Every feature registers here once, at launch. To add one: an `enum MyFeature: ExplorerFeature` in
/// its own files plus ONE line in `all`, in a free slot (keep the blank lines so branches merge cleanly).
/// Registration order comes from `requires`, not line order.
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

        FinderTagsFeature.self,   // Tags section of the navigation pane

        FolderOptionsFeature.self,

        ItemActionsFeature.self,   // New menu, shortcuts and batch rename

        AccessibilityFeature.self,

        VisualParityFeature.self,   // visual parity and window chrome
        NameWrapFeature.self,   // long names on several lines in Details

        ConsistencyFeature.self,   // consistency across features

        FileOperationsExtras.self,   // history, queue, verification, Compress to ▸ Additional options

        PerformanceFeature.self,   // memory and responsiveness

        AddressEntryFeature.self,   // path suggestions and shell: names

        AddressHistoryFeature.self,   // addresses remembered across launches

        ServicesFeature.self,   // macOS Services

        PromisedFilesFeature.self,   // files promised by other apps

        ReliabilityFeature.self,   // behavior and safety checks (undo names, headless safety, alert queue)

        WorkspacesFeature.self,   // named tab sets, an Arbor addition

        AcceptanceScriptSteps.self,   // script steps and log lines for scripts/acceptance.sh

        SettingsTransferFeature.self,   // export and import of preferences
        WindowsShortcutsFeature.self,   // reads Windows .lnk and .url files
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

    /// Stops launch with a message if the feature list or a registration is wrong.
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

/// The foundation: commands, Details view, panes, folder browsing, and location placeholders.
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
