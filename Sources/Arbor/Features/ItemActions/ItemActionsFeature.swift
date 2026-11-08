import AppKit
import ArborCore

extension MenuSection {
    /// New ▸ file types, after Folder and Shortcut. Explorer lists them alphabetically by display name.
    /// Orders: Bitmap image 10, Compressed (zipped) Folder 20 (archives feature), Rich Text Document 30,
    /// Text Document 40.
    static let newFileTypes = MenuSection(rank: 20, name: "newFileTypes")
    /// Item context menu: Send to ▸, Create shortcut (after Share, before the tools section).
    static let sendTo = MenuSection(rank: 650, name: "sendTo")
    /// Item context menu: image actions (Set as desktop background, Rotate right, Rotate left).
    static let imageActions = MenuSection(rank: 460, name: "imageActions")
}

/// Item actions (FE-057, FE-064, FE-088, FE-089, FE-092, FE-096, FE-097, FE-100, FE-103, FE-106,
/// FE-108, FE-109, FE-111): New ▸, shortcuts, Send to ▸, rename, selection, image actions and drag polish.
enum ItemActionsFeature: ExplorerFeature {
    static let id = "item-actions"
    /// Send to ▸ Compressed (zipped) folder runs the archives command.
    static let requires = ["archives"]
    static func register() {
        NewItemCommands.register()
        ShortcutCommands.register()
        SendToCommands.register()
        RenameCommands.register()
        SelectionCommands.register()
        ImageCommands.register()
        DragPolish.install()

        // Aliases resolve before anything looks at the file's type (an alias named "x.zip" is still an alias).
        LocationRegistry.registerOpenHandler("item-actions.shortcuts", order: .early, Shortcuts.locationForOpening)
        InteractionHooks.openFile.register("item-actions.shortcuts", handles: { window, file in Shortcuts.openFile(window, file) })
        InteractionHooks.decorateIcon.register("item-actions.shortcut-arrow") { item, icon, size in Shortcuts.decorate(item, icon, size: size) }
        IconProvider.shared.purgeFileIcons()
        ItemActionsDebug.register()
    }

    /// Where new items go: the current real folder, if it can be written to.
    static func writableFolder(_ ctx: CommandContext) -> URL? {
        guard ctx.allowsEditing, let folder = ctx.targetFolder else { return nil }
        return folder
    }

    /// Windows wording in context menus and the command bar, Mac title case in the menu bar.
    static func title(_ windows: String, mac: String) -> (CommandContext) -> String {
        { $0.surface == .menuBar ? mac : windows }
    }
}

// MARK: - New ▸ (FE-088)

enum NewItemCommands {
    static func register() {
        let r = CommandRegistry.shared
        let orders: [String: Double] = ["bmp": 10, "rtf": 30, "txt": 40]
        for template in NewItemTemplates.all {
            r.register(ExplorerCommand(
                id: "file.new.\(template.id)", title: template.menuTitle,
                symbol: symbol(for: template),
                placements: [.newMenu(.newFileTypes, orders[template.id] ?? 50)],
                dynamicTitle: ItemActionsFeature.title(template.menuTitle, mac: L10n.format("New %@", "\(template.menuTitle)")),
                isEnabled: { ItemActionsFeature.writableFolder($0) != nil },
                perform: { ctx in create(template, ctx) }))
        }
    }

    static func symbol(for template: NewItemTemplate) -> String {
        switch template.id {
        case "bmp": return "photo"
        case "rtf": return "doc.richtext"
        default: return "doc.text"
        }
    }

    /// Creates the file, selects it and starts inline rename with the base name selected (Explorer).
    static func create(_ template: NewItemTemplate, _ ctx: CommandContext) {
        guard let folder = ItemActionsFeature.writableFolder(ctx), let window = ctx.window else { NSSound.beep(); return }
        do {
            let url = try NewItemTemplates.create(template, in: folder)
            Shortcuts.registerUndoCreate([url], name: "New \(template.menuTitle)")
            if Location.folder(folder) == window.location {
                window.refreshSelecting([url.lastPathComponent], rename: url.lastPathComponent)
            }
        } catch {
            NSAlert.show(L10n.format("Couldn't create a %@ in “%@”.", "\(template.menuTitle.lowercased())", "\(displayName(of: folder))"),
                         error.localizedDescription, in: window.window)
        }
    }
}

// MARK: - Shortcuts (FE-092)

enum ShortcutCommands {
    static func register() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "file.newShortcut", title: "Shortcut", symbol: "arrow.up.forward.square",
                placements: [.newMenu(.main, 20), .mainMenu("File", .new, 25)],
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Shortcut"), mac: L10n.tr("New Shortcut…")),
                isEnabled: { ItemActionsFeature.writableFolder($0) != nil },
                perform: { ctx in
                    guard let folder = ItemActionsFeature.writableFolder(ctx), let window = ctx.window else { return }
                    CreateShortcutWizard.run(in: folder, window: window)
                }),
            ExplorerCommand(
                id: "file.createShortcut", title: "Create shortcut", symbol: "arrow.up.forward.square",
                placements: [.itemContextMenu(.sendTo, 20), .mainMenu("File", .new, 30)],
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Create shortcut"), mac: L10n.tr("Create Shortcut")),
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { ctx in ctx.hasSelection && ItemActionsFeature.writableFolder(ctx) != nil },
                perform: { ctx in
                    guard let folder = ItemActionsFeature.writableFolder(ctx), let window = ctx.window else { return }
                    let created = Shortcuts.createShortcuts(to: ctx.selection.map(\.url), in: folder, window: window)
                    if !created.isEmpty, Location.folder(folder) == window.location {
                        window.refreshSelecting(created.map(\.lastPathComponent),
                                                rename: created.count == 1 ? created[0].lastPathComponent : nil)
                    }
                }),
            ExplorerCommand(
                id: "edit.pasteShortcut", title: "Paste shortcut", symbol: "arrow.up.forward.app",
                placements: [.backgroundContextMenu(.clipboard, 15), .mainMenu("Edit", .clipboard, 35)],
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Paste shortcut"), mac: L10n.tr("Paste Shortcut")),
                isEnabled: { ctx in FileClipboard.shared.canPaste && ItemActionsFeature.writableFolder(ctx) != nil },
                perform: { ctx in
                    guard let folder = ItemActionsFeature.writableFolder(ctx), let window = ctx.window else { return }
                    let targets = FileClipboard.shared.readURLs()
                    guard !targets.isEmpty else { NSSound.beep(); return }
                    let created = Shortcuts.createShortcuts(to: targets, in: folder, window: window)
                    if !created.isEmpty, Location.folder(folder) == window.location {
                        window.refreshSelecting(created.map(\.lastPathComponent))
                    }
                }),
            // Advanced and clearly separate from shortcuts: a POSIX symbolic link (breaks if the target moves).
            ExplorerCommand(
                id: "file.createSymlink", title: "Create Symbolic Link",
                placements: [.mainMenu("File", .new, 40)],
                isEnabled: { ctx in ctx.hasSelection && ItemActionsFeature.writableFolder(ctx) != nil },
                perform: { ctx in
                    guard let folder = ItemActionsFeature.writableFolder(ctx), let window = ctx.window else { return }
                    var created: [URL] = []
                    for item in ctx.selection {
                        do { created.append(try Shortcuts.createSymbolicLink(to: item.url, in: folder)) } catch {
                            NSAlert.show(L10n.format("Couldn't create a symbolic link to “%@”.", "\(item.name)"), error.localizedDescription, in: window.window)
                            break
                        }
                    }
                    guard !created.isEmpty else { return }
                    Shortcuts.registerUndoCreate(created, name: "Create Symbolic Link")
                    window.refreshSelecting(created.map(\.lastPathComponent))
                    window.statusBar.setMessage(L10n.format("Created %@ as symbolic links. Unlike shortcuts, they stop working if the original moves.", "\(StatusText.items(created.count))"))
                }),
        ])
    }
}

// MARK: - Selection (FE-057)

/// Select all / Select none / Invert selection, with Explorer's wording in the "…" menu. They act on
/// the visible (filtered) items only; the status bar shows the resulting count.
enum SelectionCommands {
    static func register() {
        let r = CommandRegistry.shared
        // These replace the core selection commands.
        let upgraded = [
            ExplorerCommand(
                id: "edit.selectAll", title: "Select All", symbol: "checklist", shortcut: Shortcut("a"),
                placements: [.mainMenu("Edit", .selection, 10), .seeMore(.selection, 10)],
                menuAction: #selector(NSResponder.selectAll(_:)),
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Select all"), mac: L10n.tr("Select All")),
                isEnabled: { $0.window?.itemView != nil && !($0.window?.visibleItems.isEmpty ?? true) },
                perform: { ctx in
                    guard let window = ctx.window, let view = window.itemView else { return }
                    view.select(urls: window.visibleItems.map(\.url))
                }),
            ExplorerCommand(
                id: "edit.selectNone", title: "Select None", symbol: "square.dashed",
                placements: [.mainMenu("Edit", .selection, 20), .seeMore(.selection, 20)],
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Select none"), mac: L10n.tr("Select None")),
                isEnabled: { $0.hasSelection },
                perform: { $0.window?.itemView?.select(names: []) }),
            ExplorerCommand(
                id: "edit.invertSelection", title: "Invert Selection", symbol: "arrow.left.arrow.right.square",
                placements: [.mainMenu("Edit", .selection, 30), .seeMore(.selection, 30)],
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Invert selection"), mac: L10n.tr("Invert Selection")),
                isEnabled: { $0.window?.itemView != nil && !($0.window?.visibleItems.isEmpty ?? true) },
                perform: { ctx in
                    guard let window = ctx.window, let view = window.itemView else { return }
                    // By URL: search results can list several items with the same name.
                    let selected = Set(ctx.selection.map(\.url))
                    view.select(urls: window.visibleItems.map(\.url).filter { !selected.contains($0) })
                }),
        ]
        upgraded.forEach { r.replace($0, "item-actions.selection") }
    }
}
