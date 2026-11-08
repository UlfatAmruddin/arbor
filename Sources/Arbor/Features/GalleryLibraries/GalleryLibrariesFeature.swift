import AppKit
import ArborCore

/// Gallery and Libraries (FE-075, FE-076, FE-238, FE-239). See docs/features/gallery-libraries.md.
enum GalleryLibrariesFeature: ExplorerFeature {
    static let id = "gallery-libraries"
    static func register() {
        LocationRegistry.register(GalleryProvider())
        LocationRegistry.register(LibraryProvider())

        // A library's Details view adds a "Folder" column (which included folder each item lives in).
        DetailsColumns.register("gallery-libraries.folder-column") { location in libraryName(location) == nil ? nil : libraryLayout }
        // After the Trash node (trash.navigation-node), which also follows Network.
        NavigationPaneExtras.register(.afterNetwork, "gallery-libraries.libraries-node", order: .late, librariesNodes)
        Breadcrumbs.register("gallery-libraries.crumbs", libraryCrumbs)
        registerCommands()
        registerDebugSteps()

        let nc = NotificationCenter.default
        nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            if note.userInfo?["key"] as? String == "showLibraries" { NavigationPaneExtras.refreshAll() }
        }
        nc.addObserver(forName: LibraryStore.changed, object: nil, queue: .main) { _ in NavigationPaneExtras.refreshAll() }

        registerOverrides()
    }

    static func isGallery(_ ctx: CommandContext) -> Bool { ctx.location == .gallery }

    static func libraryName(_ location: Location?) -> String? {
        if case .library(let name)? = location, name != LibraryLogic.rootName { return name }
        return nil
    }

    static func galleryPage(_ ctx: CommandContext) -> GalleryPageController? {
        guard ctx.location == .gallery else { return nil }
        return ctx.window?.activeTab.page as? GalleryPageController
    }

    // MARK: Navigation pane and breadcrumbs

    /// "Libraries" after Network when shown (off by default, like Windows 11); `.folder` nodes with preset children.
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
        items.append(ClosureMenuItem(L10n.tr("Manage collection…"), image: NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)) {
            LocationsDialog(mode: .gallery).present(in: BrowserWindowController.active?.window)
        })
        return items
    }

    // MARK: Location-specific behavior of core commands

    /// Gallery and library pages decide first (`.early`): their rules replace the commands' and other features' overrides.
    static func registerOverrides() {
        let r = CommandRegistry.shared
        let gallery: (CommandContext) -> Bool = { $0.location == .gallery }

        // View ▾ in Gallery: the four thumbnail sizes; list-style layouts don't apply.
        for mode in ViewMode.allCases {
            if GalleryPrefs.sizes.contains(mode) {
                r.override("view.mode.\(mode.rawValue)", "gallery-libraries.thumbnail-size", order: .early, when: gallery,
                           isEnabled: { _ in true },
                           state: { _ in GalleryPrefs.size == mode ? .on : .off },
                           perform: { _ in GalleryPrefs.size = mode })
            } else {
                r.override("view.mode.\(mode.rawValue)", "gallery-libraries.no-list-layout", order: .early, when: gallery,
                           isAvailable: { _ in false }, state: { _ in .off })
            }
        }
        r.hide("view.compact", "gallery-libraries.no-compact", order: .early, when: gallery)

        // Sort ▾ in Gallery: date taken only; other sort.* commands are hidden, including later features'.
        r.hide(prefix: "sort.", except: ["sort.ascending", "sort.descending"], "gallery-libraries.sort-by-date-taken",
               order: .early, when: gallery)
        for (id, newest) in [("sort.ascending", false), ("sort.descending", true)] {
            r.override(id, "gallery-libraries.sort-by-date-taken", order: .early, when: gallery, isEnabled: { _ in true },
                       state: { _ in GalleryPrefs.newestFirst == newest ? .on : .off },
                       perform: { _ in GalleryPrefs.newestFirst = newest })
        }

        // Selection commands act on the grid.
        r.override("edit.selectAll", "gallery-libraries.grid-selection", order: .early, when: gallery,
                   isEnabled: { galleryPage($0)?.grid.itemCount ?? 0 > 0 },
                   perform: { galleryPage($0)?.grid.selectAll() })
        r.override("edit.selectNone", "gallery-libraries.grid-selection", order: .early, when: gallery,
                   perform: { galleryPage($0)?.grid.select(keys: []) })
        r.override("edit.invertSelection", "gallery-libraries.grid-selection", order: .early, when: gallery,
                   isEnabled: { galleryPage($0)?.grid.itemCount ?? 0 > 0 },
                   perform: { ctx in
                       guard let grid = galleryPage(ctx)?.grid else { return }
                       grid.select(keys: Set(grid.allItems.map(\.key)).subtracting(grid.selection))
                   })

        // Rename in Gallery: names aren't shown on tiles, so it asks in a sheet.
        r.override("file.rename", "gallery-libraries.rename-in-sheet", order: .early, when: gallery, perform: renameInGallery)

        // Delete in Gallery: the file goes to the Trash; the tile disappears at once.
        r.override("file.trash", "gallery-libraries.forget-trashed-tiles", order: .early, when: gallery, perform: { ctx in
            let urls = ctx.selection.map(\.url)
            CommandRegistry.shared.command("file.trash")?.perform(ctx, after: "gallery-libraries.forget-trashed-tiles")
            GalleryStore.shared.forget(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
        })

        // New and Paste in a library go to its save location, or explain why they can't (FE-238).
        let library: (CommandContext) -> Bool = { libraryName($0.location) != nil && $0.surface != .itemContextMenu }
        r.override("file.newFolder", "gallery-libraries.library-save-location", order: .early, when: library,
                   isEnabled: { _ in true }, perform: { ctx in
            guard let folder = saveLocation(ctx), let window = ctx.window else { return }
            let name = NameRules.newFolderName { FileOps.exists(folder.appendingPathComponent($0)) }
            let url = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                NSAlert.show(L10n.format("Couldn't create a folder in “%@”.", "\(displayName(of: folder))"), error.localizedDescription, in: window.window)
                return
            }
            OperationCenter.shared.registerUndoNewFolder(url)
            window.refreshSelecting([name], rename: name)
        })
        for id in ["edit.paste", "edit.pasteMove"] {
            r.override(id, "gallery-libraries.library-save-location", order: .early, when: library,
                       isEnabled: { _ in FileClipboard.shared.canPaste }, perform: { ctx in
                guard let folder = saveLocation(ctx) else { return }
                var copy = ctx
                copy.targetFolder = folder
                CommandRegistry.shared.command(id)?.perform(copy, after: "gallery-libraries.library-save-location")
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
                ctx.window?.statusBar.setMessage(L10n.format("The save location isn't available, so “%@” is used instead.", "\(url.lastPathComponent)"))
            }
            return url
        case .unavailable(let reason):
            let alert = NSAlert()
            alert.messageText = L10n.tr("This library has no save location.")
            alert.informativeText = reason
            alert.addButton(withTitle: L10n.tr("Manage library"))
            alert.addButton(withTitle: L10n.tr("Cancel"))
            let open = { (response: NSApplication.ModalResponse) in
                if response == .alertFirstButtonReturn { LocationsDialog(mode: .library(name)).present(in: ctx.window?.window) }
            }
            AlertSheets.present(alert, in: ctx.window?.window) { response in DispatchQueue.main.async { open(response) } }
            return nil
        }
    }

    static func renameInGallery(_ ctx: CommandContext) {
        guard let item = ctx.single, let window = ctx.window, let host = window.window, host.attachedSheet == nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Rename")
        alert.informativeText = L10n.format("Enter a new name for “%@”. The file keeps its place in “%@”.", "\(item.name)", "\(item.url.deletingLastPathComponent().lastPathComponent)")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Rename"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
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
