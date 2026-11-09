import AppKit
import ArborCore

/// Library commands (FE-076), and what core commands mean in a library (FE-238, FE-239).
extension GalleryLibrariesFeature {
    static func isLibrariesPage(_ ctx: CommandContext) -> Bool { ctx.location == .library(LibraryLogic.rootName) }

    /// The one tile selected on the Libraries page.
    static func selectedLibrary(_ ctx: CommandContext) -> String? {
        guard isLibrariesPage(ctx) else { return nil }
        return (ctx.window?.activeTab.page as? LibrariesPageController)?.selectedLibrary
    }

    /// The library a command acts on: the right-clicked node or tile, else the one open or selected.
    static func commandLibrary(_ ctx: CommandContext) -> String? {
        if ctx.surface == .treeContextMenu { return libraryName(ctx.treeLocation) }
        return libraryName(ctx.location) ?? selectedLibrary(ctx)
    }

    private static func isTreeLibrary(_ ctx: CommandContext) -> Bool {
        ctx.surface == .treeContextMenu && libraryName(ctx.treeLocation) != nil
    }

    private static func isLibrariesRoot(_ ctx: CommandContext) -> Bool {
        ctx.surface == .treeContextMenu ? ctx.treeLocation == .library(LibraryLogic.rootName) : isLibrariesPage(ctx)
    }

    static func registerLibraryCommands() {
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "library.new", title: "Library", symbol: "books.vertical",
                placements: [.newMenu(.main, 5), .mainMenu("File", .new, 15), .backgroundContextMenu(.new, 5), .treeContextMenu(.new, 5)],
                dynamicTitle: { ctx in
                    switch ctx.surface {
                    case .menuBar: return L10n.tr("New Library")
                    case .commandBar: return L10n.tr("Library")
                    default: return L10n.tr("New library")
                    }
                },
                isAvailable: { $0.surface == .menuBar || isLibrariesRoot($0) },
                perform: { LibraryActions.create(in: $0.window) }),
            ExplorerCommand(
                id: "library.rename", title: "Rename library", symbol: "character.cursor.ibeam",
                placements: [.treeContextMenu(.organize, 20)],
                isAvailable: isTreeLibrary,
                perform: { ctx in if let name = commandLibrary(ctx) { LibraryActions.rename(name, in: ctx.window) } }),
            ExplorerCommand(
                id: "library.delete", title: "Delete library", symbol: "trash",
                tooltip: "Remove this library. Its folders and files stay where they are",
                placements: [.treeContextMenu(.organize, 30)],
                isAvailable: isTreeLibrary,
                perform: { ctx in if let name = commandLibrary(ctx) { LibraryActions.confirmDelete(name, in: ctx.window) } }),
            ExplorerCommand(
                id: "library.manage", title: "Manage library", symbol: "folder.badge.gearshape",
                tooltip: "Choose the folders this library includes and where new items are saved",
                placements: [.commandBarContextual(10), .seeMore(.properties, 10), .treeContextMenu(.properties, 5),
                             .backgroundContextMenu(.properties, 5)],
                showsTitle: true,
                isAvailable: { commandLibrary($0) != nil },
                perform: { ctx in
                    guard let name = commandLibrary(ctx) else { return }
                    LocationsDialog(mode: .library(name)).present(in: ctx.window?.window)
                }),
            ExplorerCommand(
                id: "library.restoreDefaults", title: "Restore default libraries", symbol: "arrow.counterclockwise",
                tooltip: "Bring back any of the default libraries that were deleted",
                placements: [.seeMore(.properties, 12), .treeContextMenu(.properties, 7), .backgroundContextMenu(.properties, 7)],
                isAvailable: isLibrariesRoot,
                perform: { LibraryActions.restoreDefaults(in: $0.window) }),
        ])
    }

    /// Libraries decide first (`.early`): their rules replace the commands' and other features' overrides.
    static func registerLibraryOverrides() {
        let r = CommandRegistry.shared
        let oneTile: (CommandContext) -> Bool = { $0.surface != .treeContextMenu && selectedLibrary($0) != nil }

        // On the Libraries page, Rename and Delete act on the library and never reach a file operation (FE-239).
        r.override("file.rename", "gallery-libraries.rename-library", order: .early, when: oneTile, isEnabled: { _ in true },
                   perform: { ctx in if let name = selectedLibrary(ctx) { LibraryActions.rename(name, in: ctx.window) } })
        r.override("file.trash", "gallery-libraries.delete-library", order: .early, when: oneTile, isEnabled: { _ in true },
                   title: { _ in L10n.tr("Delete library") },
                   perform: { ctx in if let name = selectedLibrary(ctx) { LibraryActions.confirmDelete(name, in: ctx.window) } })
        r.hide(prefix: "file.new", "gallery-libraries.only-libraries-are-new", order: .early, when: isLibrariesPage)
        r.hide("archive.newZip", "gallery-libraries.only-libraries-are-new", order: .early, when: isLibrariesPage)

        // New and Paste in a library go to its save location, or explain why they can't (FE-238).
        let insideLibrary: (CommandContext) -> Bool = { libraryName($0.location) != nil && $0.surface != .itemContextMenu }
        r.override("file.newFolder", "gallery-libraries.library-save-location", order: .early, when: insideLibrary,
                   isEnabled: { _ in true }, perform: newFolderInLibrary)
        for id in ["edit.paste", "edit.pasteMove"] {
            r.override(id, "gallery-libraries.library-save-location", order: .early, when: insideLibrary,
                       isEnabled: { _ in FileClipboard.shared.canPaste }, perform: { ctx in
                withSaveLocation(ctx) { folder, _, finished in
                    var copy = ctx
                    copy.targetFolder = folder
                    CommandRegistry.shared.command(id)?.perform(copy, after: "gallery-libraries.library-save-location")
                    finished()
                }
            })
        }
    }

    // MARK: Save location (FE-238)

    /// Windows with a resolve or write under way; a repeat press on a slow volume must not act twice.
    private static var writing = Set<ObjectIdentifier>()

    /// Resolves the library's save location off the main thread, then calls `use` on main. `use` calls `finished` when its work ends.
    static func withSaveLocation(_ ctx: CommandContext,
                                 _ use: @escaping (URL, BrowserWindowController, _ finished: @escaping () -> Void) -> Void) {
        guard let window = ctx.window, let name = libraryName(ctx.location), let library = LibraryStore.definition(name) else { return }
        let id = ObjectIdentifier(window)
        guard writing.insert(id).inserted else { return }
        let finished = { _ = writing.remove(id) }
        DispatchQueue.global(qos: .userInitiated).async { [weak window] in
            let resolution = LibraryStore.resolve(library)
            DispatchQueue.main.async {
                guard let window else { finished(); return }
                guard LibraryStore.definition(name) == library else {
                    finished()
                    window.statusBar.setMessage(L10n.tr("The library changed in the meantime, so nothing was saved. Try again."), isError: true)
                    return
                }
                LibraryStore.remember(resolution, for: library)
                switch resolution {
                case .folder(let url, _):
                    use(url, window, finished)   // the reload that follows says when it's a fallback
                case .unavailable(let reason):
                    finished()
                    explainNoSaveLocation(reason, library: name, in: window)
                }
            }
        }
    }

    private static func explainNoSaveLocation(_ reason: String, library name: String, in window: BrowserWindowController) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("This library has no save location.")
        alert.informativeText = reason
        alert.addButton(withTitle: L10n.tr("Manage library"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        AlertSheets.present(alert, in: window.window) { [weak window] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { LocationsDialog(mode: .library(name)).present(in: window?.window) }
        }
    }

    /// The name pick and the create happen off the main thread; an existing name fails instead of being reused.
    private static func newFolderInLibrary(_ ctx: CommandContext) {
        withSaveLocation(ctx) { folder, window, finished in
            DispatchQueue.global(qos: .userInitiated).async { [weak window] in
                let name = NameRules.newFolderName { FileOps.exists(folder.appendingPathComponent($0)) }
                let url = folder.appendingPathComponent(name)
                let result = Result { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
                // Another of the library's folders can hold the same name, so the new row is identified by URL.
                let listed = LibraryMerge.listedFolder(folder).appendingPathComponent(name)
                DispatchQueue.main.async {
                    finished()
                    switch result {
                    case .success:
                        OperationCenter.shared.registerUndoNewFolder(url)
                        if let window, window.location == ctx.location { window.refreshSelecting(urls: [listed], rename: listed) }
                    case .failure(let error):
                        NSAlert.show(L10n.format("Couldn't create a folder in “%@”.", folder.lastPathComponent), error.localizedDescription, in: window?.window)
                    }
                }
            }
        }
    }
}
