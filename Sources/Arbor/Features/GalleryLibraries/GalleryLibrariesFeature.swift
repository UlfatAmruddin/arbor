import AppKit
import ArborCore

/// Gallery and Libraries (FE-075, FE-076, FE-238, FE-239). See docs/features/gallery-libraries.md.
enum GalleryLibrariesFeature {
    static func register() {
        LocationRegistry.register(GalleryProvider())
        LocationRegistry.register(LibraryProvider())

        // A library's Details view adds a "Folder" column (which included folder each item lives in).
        DetailsColumns.register { location in libraryName(location) == nil ? nil : libraryLayout }
        NavigationPaneExtras.register(.afterNetwork, librariesNodes)
        Breadcrumbs.register(libraryCrumbs)
        registerCommands()
        registerDebugSteps()

        let nc = NotificationCenter.default
        nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            if note.userInfo?["key"] as? String == "showLibraries" { NavigationPaneExtras.refreshAll() }
        }
        nc.addObserver(forName: LibraryStore.changed, object: nil, queue: .main) { _ in NavigationPaneExtras.refreshAll() }

        // Runs after every feature has registered, so the location-specific behavior below wraps the
        // final versions of the core commands (see `CommandOverride`).
        DispatchQueue.main.async { installOverrides() }
    }

    static var isGallery: (CommandContext) -> Bool { { $0.location == .gallery } }

    static func libraryName(_ location: Location?) -> String? {
        if case .library(let name)? = location, name != LibraryLogic.rootName { return name }
        return nil
    }

    static func galleryPage(_ ctx: CommandContext) -> GalleryPageController? {
        guard ctx.location == .gallery else { return nil }
        return ctx.window?.activeTab.page as? GalleryPageController
    }

    // MARK: Navigation pane and breadcrumbs

    /// "Libraries" after Network when Show libraries is on (hidden by default, like Windows 11). The nodes
    /// use the `.folder` kind with preset children so they expand: Libraries → each library → its folders.
    static func librariesNodes() -> [NavNode] {
        guard Prefs.showLibraries else { return [] }
        let children = LibraryStore.all.map { library -> NavNode in
            let folders = library.folderURLs.map { NavNode(kind: .folder, title: displayName(of: $0), location: .folder($0)) }
            let node = NavNode(kind: .folder, title: library.name, location: .library(library.name), children: folders)
            node.icon = LibraryStore.icon(for: library.name, size: 16)
            return node
        }
        let node = NavNode(kind: .folder, title: LibraryLogic.rootName, location: .library(LibraryLogic.rootName), children: children)
        node.icon = LibraryStore.icon(for: LibraryLogic.rootName, size: 16)
        return [node]
    }

    static let libraryLayout = DetailsLayout(
        id: "library", order: ["name", "dateModified", "type", "size", "folder"], widths: ["name": 280],
        extras: [DetailsColumnSpec(id: "folder", title: "Folder", width: 280, minWidth: 80, cell: { table, item in
            let cell = DetailsTextCell.make(table, id: "folder", truncation: .byTruncatingMiddle)
            cell.label.stringValue = LibraryMerge.folderColumnText(for: item.url)
            cell.toolTip = item.url.deletingLastPathComponent().path
            return cell
        })])

    static func libraryCrumbs(_ location: Location) -> [Crumb]? {
        guard case .library(let name) = location else { return nil }
        let root = Crumb(title: LibraryLogic.rootName, location: .library(LibraryLogic.rootName), children: {
            LibraryStore.all.map { CrumbChild(title: $0.name, location: .library($0.name), icon: LibraryStore.icon(for: $0.name, size: 16)) }
        })
        guard name != LibraryLogic.rootName else { return [root] }
        return [root, Crumb(title: name, location: location, children: {
            (LibraryStore.definition(name)?.folderURLs ?? []).map {
                CrumbChild(title: displayName(of: $0), location: .folder($0),
                           icon: IconProvider.shared.folderIcon(IconProvider.shared.folderKind(for: $0), size: 16))
            }
        })]
    }

    // MARK: Commands

    static func registerCommands() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "gallery.collection", title: "Collection", symbol: "photo.stack", tooltip: "Choose the folders Gallery shows",
                placements: [.commandBarContextual(10)],
                showsTitle: true,
                isAvailable: isGallery,
                submenu: { _ in collectionMenuItems() }),
            ExplorerCommand(
                id: "gallery.manageCollection", title: "Manage collection…", symbol: "folder.badge.gearshape",
                placements: [.seeMore(.properties, 10)],
                isAvailable: isGallery,
                perform: { ctx in LocationsDialog(mode: .gallery).present(in: ctx.window?.window) }),
            ExplorerCommand(
                id: "gallery.sort.date", title: "Date taken",
                placements: [.sortMenu(.main, -1)],
                isAvailable: isGallery,
                state: { _ in .on }),
            ExplorerCommand(
                id: "library.manage", title: "Manage library", symbol: "folder.badge.gearshape",
                tooltip: "Choose the folders this library includes and where new items are saved",
                placements: [.commandBarContextual(10), .seeMore(.properties, 10), .treeContextMenu(.properties, 5),
                             .backgroundContextMenu(.properties, 5)],
                showsTitle: true,
                isAvailable: { ctx in libraryName(ctx.surface == .treeContextMenu ? ctx.treeLocation : ctx.location) != nil },
                perform: { ctx in
                    guard let name = libraryName(ctx.surface == .treeContextMenu ? ctx.treeLocation : ctx.location) else { return }
                    LocationsDialog(mode: .library(name)).present(in: ctx.window?.window)
                }),
            ExplorerCommand(
                id: "collection.openFileLocation", title: "Open file location", symbol: "folder",
                placements: [.itemContextMenu(.open, 35)],
                isAvailable: { ctx in
                    guard ctx.single != nil else { return false }
                    return ctx.location == .gallery || libraryName(ctx.location) != nil
                },
                perform: { ctx in
                    guard let item = ctx.single else { return }
                    ctx.window?.navigate(to: .folder(item.url.deletingLastPathComponent()), select: [item.url.lastPathComponent])
                }),
        ])
    }

    static func collectionMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = GalleryPrefs.collection.sources.map { source in
            let item = ClosureMenuItem(source.url.lastPathComponent,
                                       image: IconProvider.shared.folderIcon(IconProvider.shared.folderKind(for: source.url), size: 16)) {
                var collection = GalleryPrefs.collection
                collection.setIncluded(source.url, !source.included)
                GalleryPrefs.collection = collection
            }
            item.state = source.included ? .on : .off
            item.toolTip = source.path
            return item
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem("Manage collection…", image: NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)) {
            LocationsDialog(mode: .gallery).present(in: BrowserWindowController.active?.window)
        })
        return items
    }

    // MARK: Location-specific behavior of core commands

    static func installOverrides() {
        let gallery: (CommandContext) -> Bool = { $0.location == .gallery }

        // View ▾ in Gallery: the four thumbnail sizes; list-style layouts don't apply.
        for mode in ViewMode.allCases {
            if GalleryPrefs.sizes.contains(mode) {
                CommandOverride.apply("view.mode.\(mode.rawValue)", when: gallery,
                                      isEnabled: { _ in true },
                                      state: { _ in GalleryPrefs.size == mode ? .on : .off },
                                      perform: { _ in GalleryPrefs.size = mode })
            } else {
                CommandOverride.apply("view.mode.\(mode.rawValue)", when: gallery, isAvailable: { _ in false },
                                      state: { _ in .off })
            }
        }
        CommandOverride.apply("view.compact", when: gallery, isAvailable: { _ in false })

        // Sort ▾ in Gallery: by date taken, newest or oldest first.
        for id in CommandRegistry.shared.all.map(\.id) where id.hasPrefix("sort.") && id != "sort.ascending" && id != "sort.descending" {
            CommandOverride.apply(id, when: gallery, isAvailable: { _ in false })
        }
        for (id, newest) in [("sort.ascending", false), ("sort.descending", true)] {
            CommandOverride.apply(id, when: gallery, isEnabled: { _ in true },
                                  state: { _ in GalleryPrefs.newestFirst == newest ? .on : .off },
                                  perform: { _ in GalleryPrefs.newestFirst = newest })
        }

        // Selection commands act on the grid.
        CommandOverride.apply("edit.selectAll", when: gallery, isEnabled: { galleryPage($0)?.grid.itemCount ?? 0 > 0 },
                              perform: { galleryPage($0)?.grid.selectAll() })
        CommandOverride.apply("edit.selectNone", when: gallery, perform: { galleryPage($0)?.grid.select(keys: []) })
        CommandOverride.apply("edit.invertSelection", when: gallery, isEnabled: { galleryPage($0)?.grid.itemCount ?? 0 > 0 },
                              perform: { ctx in
                                  guard let grid = galleryPage(ctx)?.grid else { return }
                                  grid.select(keys: Set(grid.allItems.map(\.key)).subtracting(grid.selection))
                              })

        // Rename in Gallery: names aren't shown on tiles, so it asks in a sheet.
        CommandOverride.apply("file.rename", when: gallery, perform: renameInGallery)

        // Delete in Gallery: the real file goes to the Trash; the tile disappears at once.
        CommandOverride.apply("file.trash", when: gallery, perform: { ctx in
            let urls = ctx.selection.map(\.url)
            CommandOverride.original("file.trash")?.perform(ctx)
            GalleryStore.shared.forget(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
        })

        // New and Paste in a library go to its save location, or explain why they can't (FE-238).
        let library: (CommandContext) -> Bool = { libraryName($0.location) != nil && $0.surface != .itemContextMenu }
        CommandOverride.apply("file.newFolder", when: library, isEnabled: { _ in true }, perform: { ctx in
            guard let folder = saveLocation(ctx), let window = ctx.window else { return }
            let name = NameRules.newFolderName { FileOps.exists(folder.appendingPathComponent($0)) }
            let url = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                NSAlert.show("Couldn't create a folder in “\(displayName(of: folder))”.", error.localizedDescription, in: window.window)
                return
            }
            OperationCenter.shared.registerUndoNewFolder(url)
            window.refreshSelecting([name], rename: name)
        })
        for id in ["edit.paste", "edit.pasteMove"] {
            CommandOverride.apply(id, when: library, isEnabled: { _ in FileClipboard.shared.canPaste }, perform: { ctx in
                guard let folder = saveLocation(ctx) else { return }
                var copy = ctx
                copy.targetFolder = folder
                CommandOverride.original(id)?.perform(copy)
            })
        }
    }

    /// The library's save location, resolved now; shows why there is none (FE-238).
    static func saveLocation(_ ctx: CommandContext) -> URL? {
        guard let name = libraryName(ctx.location), let library = LibraryStore.definition(name) else { return nil }
        let resolution = LibraryStore.resolve(library)
        LibraryStore.remember(resolution, for: name)
        switch resolution {
        case .folder(let url, let isFallback):
            if isFallback {
                ctx.window?.statusBar.setMessage("The save location isn't available, so “\(url.lastPathComponent)” is used instead.")
            }
            return url
        case .unavailable(let reason):
            let alert = NSAlert()
            alert.messageText = "This library has no save location."
            alert.informativeText = reason
            alert.addButton(withTitle: "Manage library")
            alert.addButton(withTitle: "Cancel")
            let open = { (response: NSApplication.ModalResponse) in
                if response == .alertFirstButtonReturn { LocationsDialog(mode: .library(name)).present(in: ctx.window?.window) }
            }
            if let host = ctx.window?.window, host.attachedSheet == nil {
                alert.beginSheetModal(for: host) { response in DispatchQueue.main.async { open(response) } }
            } else {
                open(alert.runModal())
            }
            return nil
        }
    }

    static func renameInGallery(_ ctx: CommandContext) {
        guard let item = ctx.single, let window = ctx.window, let host = window.window, host.attachedSheet == nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for “\(item.name)”. The file keeps its place in “\(item.url.deletingLastPathComponent().lastPathComponent)”."
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: host) { [weak window] response in
            guard response == .alertFirstButtonReturn, let window else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, newName != item.name else { return }
            DispatchQueue.main.async {
                let page = window.activeTab.page as? GalleryPageController
                if window.itemViewRename(item, to: newName) {
                    GalleryStore.shared.forget([item.url])
                    page?.selectAfterReload(item.url.deletingLastPathComponent().appendingPathComponent(newName))
                }
            }
        }
        DispatchQueue.main.async {
            if let editor = field.currentEditor() {
                editor.selectedRange = NameRules.basenameSelection(item.name, treatAsFolder: false)
            }
        }
    }
}

/// Wraps an existing command so that, where `when` is true, it behaves differently (a location
/// such as Gallery replacing what View ▾ sizes, Sort ▾ or Rename do). Elsewhere the original
/// closures run unchanged. Installed once, after all features registered.
enum CommandOverride {
    private static var originals: [String: ExplorerCommand] = [:]

    /// The command's behavior before any override (to call from an override).
    static func original(_ id: String) -> ExplorerCommand? { originals[id] ?? CommandRegistry.shared.command(id) }

    static func apply(_ id: String, when: @escaping (CommandContext) -> Bool,
                      isAvailable: ((CommandContext) -> Bool)? = nil,
                      isEnabled: ((CommandContext) -> Bool)? = nil,
                      state: ((CommandContext) -> NSControl.StateValue)? = nil,
                      perform: ((CommandContext) -> Void)? = nil) {
        guard let command = CommandRegistry.shared.command(id) else { return }
        if originals[id] == nil {
            originals[id] = ExplorerCommand(id: id, title: command.title, isAvailable: command.isAvailable,
                                            isEnabled: command.isEnabled, state: command.state, perform: command.perform)
        }
        if let isAvailable {
            let base = command.isAvailable
            command.isAvailable = { when($0) ? isAvailable($0) : base($0) }
        }
        if let isEnabled {
            let base = command.isEnabled
            command.isEnabled = { when($0) ? isEnabled($0) : base($0) }
        }
        if let state {
            let base = command.state
            command.state = { when($0) ? state($0) : base($0) }
        }
        if let perform {
            let base = command.perform
            command.perform = { when($0) ? perform($0) : base($0) }
        }
    }
}
