import AppKit
import ArborCore

/// Every feature registers here, once, at launch (before the menu bar and first window are built).
///
/// To add a feature: put its code in its own files, give it `enum MyFeature { static func register() }`,
/// and replace ITS slot comment below with that one call. Keep the blank lines between slots so parallel
/// branches merge without conflicts. See docs/ARCHITECTURE.md.
enum Features {
    static func registerAll() {
        CoreFeature.register()

        IconViewsFeature.register()

        DetailsDepth.register()

        HomeFeature.register()

        ThisMacFeature.register()

        SearchFeature.register()

        FileOperationsFeature.register()

        PropertiesFeature.register()   // slot: Properties and Details pane

        ArchiveFeature.register()

        NetworkFeature.register()

        TrashFeature.register()

        CloudFeature.register()

        GalleryLibrariesFeature.register()   // slot: Gallery and Libraries

        FolderOptionsFeature.register()

        ItemActionsFeature.register()   // slot: New menu, shortcuts and batch rename

        AccessibilityFeature.register()   // slot: accessibility

        VisualParityFeature.register()   // slot: visual parity and window chrome
        ConsistencyFeature.register()   // slot: consistency across features
        FileOperationsExtras.register()   // file-operation extras (after Archives and Properties, whose commands they extend)

        // slot: (spare 2)
    }
}

/// Everything the foundation ships: commands, the Details view, Preview/Details panes, folder
/// browsing, and placeholder pages for locations that later features implement.
enum CoreFeature {
    static func register() {
        NavigationCommands.register()
        TabCommands.register()
        FileCommands.register()
        ClipboardCommands.register()
        ViewCommands.register()

        ViewModeRegistry.register([.details]) { DetailsViewController() }

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
