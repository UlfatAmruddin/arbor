import AppKit
import ArborCore

/// Open, New, Rename, Delete, Share, Copy as path, Terminal, Finder, Pin, Eject (FE-083–FE-100).
enum FileCommands {
    static func register() {
        let r = CommandRegistry.shared
        let backspace = String(Character(UnicodeScalar(8)))

        r.register([
            ExplorerCommand(
                id: "file.open", title: "Open", shortcut: Shortcut("o"),
                placements: [.itemContextMenu(.open, 10), .mainMenu("File", .open, 10)],
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { $0.hasSelection },
                perform: { ctx in ctx.window?.open(ctx.selection, inNewTab: false) }),
            ExplorerCommand(
                id: "file.openInNewTab", title: "Open in New Tab",
                placements: [.itemContextMenu(.open, 20), .treeContextMenu(.open, 10), .mainMenu("File", .open, 20)],
                isAvailable: { ctx in ctx.surface != .itemContextMenu || ctx.selection.contains(where: \.isFolder) },
                isEnabled: { ctx in ctx.treeLocation != nil || ctx.selection.contains(where: \.isFolder) },
                perform: { ctx in
                    if ctx.surface == .treeContextMenu, let place = ctx.treeLocation { ctx.window?.openTab(place); return }
                    ctx.selection.compactMap(LocationRegistry.locationForOpening).forEach { ctx.window?.openTab($0) }
                }),
            ExplorerCommand(
                id: "file.openInNewWindow", title: "Open in New Window",
                placements: [.itemContextMenu(.open, 30), .treeContextMenu(.open, 20)],
                isAvailable: { ctx in ctx.surface != .itemContextMenu || ctx.selection.contains(where: \.isFolder) },
                isEnabled: { ctx in ctx.treeLocation != nil || ctx.selection.contains(where: \.isFolder) },
                perform: { ctx in
                    let app = NSApp.delegate as? AppDelegate
                    if ctx.surface == .treeContextMenu, let place = ctx.treeLocation { app?.openWindow(at: place); return }
                    ctx.selection.compactMap(LocationRegistry.locationForOpening).forEach { app?.openWindow(at: $0) }
                }),
            ExplorerCommand(
                id: "file.openWith", title: "Open With",
                placements: [.itemContextMenu(.open, 40)],
                isAvailable: { ctx in ctx.single.map { !$0.isFolder } ?? false },
                submenu: { ctx in
                    guard let file = ctx.single else { return [] }
                    let apps = NSWorkspace.shared.urlsForApplications(toOpen: file.url).prefix(12)
                    return apps.map { app in
                        let icon = NSWorkspace.shared.icon(forFile: app.path)
                        icon.size = NSSize(width: 16, height: 16)
                        return ClosureMenuItem(displayName(of: app).replacingOccurrences(of: ".app", with: ""), image: icon) {
                            SystemOpen.open(ctx.selection.map(\.url), withApplicationAt: app)
                        }
                    }
                }),
            ExplorerCommand(
                id: "file.showPackageContents", title: "Show Package Contents",
                placements: [.itemContextMenu(.open, 50), .mainMenu("File", .open, 30)],
                isAvailable: { $0.surface != .itemContextMenu || ($0.single?.isPackage ?? false) },
                isEnabled: { $0.single?.isPackage ?? false },
                perform: { ctx in if let item = ctx.single { ctx.window?.navigate(to: .folder(item.url)) } }),

            ExplorerCommand(
                id: "file.newFolder", title: "Folder", symbol: "folder.badge.plus",
                shortcut: Shortcut("n", [.command, .shift]),
                placements: [.newMenu(.main, 10), .mainMenu("File", .new, 20)],
                dynamicTitle: { $0.surface == .menuBar ? L10n.tr("New Folder") : L10n.tr("Folder") },
                isEnabled: { $0.targetFolder != nil && $0.allowsEditing },
                perform: newFolder),

            ExplorerCommand(
                id: "file.rename", title: "Rename", symbol: "character.cursor.ibeam", tooltip: "Rename",
                shortcut: .function(NSF2FunctionKey),
                keyBindings: [KeyBinding(120)],   // F2
                placements: [.commandBar(40), .itemContextMenu(.organize, 10), .mainMenu("Edit", .organize, 10)],
                isAvailable: { $0.surface != .itemContextMenu || $0.single != nil },
                isEnabled: { $0.single != nil && $0.allowsEditing },
                perform: { $0.window?.itemView?.beginRenameSelection() }),
            ExplorerCommand(
                id: "file.trash", title: "Move to Trash", symbol: "trash", tooltip: "Delete (move to the Trash)",
                shortcut: Shortcut(backspace),
                placements: [.commandBar(60), .itemContextMenu(.organize, 20), .mainMenu("File", .organize, 10)],
                yieldsToTextInput: true,
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { $0.hasSelection && $0.allowsEditing },
                perform: moveToTrash),
            ExplorerCommand(
                id: "file.deletePermanently", title: "Delete Permanently…",
                shortcut: Shortcut(backspace, [.command, .option]),
                placements: [.mainMenu("File", .organize, 20)],
                yieldsToTextInput: true,
                isEnabled: { $0.hasSelection && $0.allowsEditing },
                perform: { ctx in confirmPermanentDelete(ctx.selection, ctx: ctx) }),
            ExplorerCommand(
                id: "file.share", title: "Share…", symbol: "square.and.arrow.up", tooltip: "Share",
                placements: [.commandBar(50), .itemContextMenu(.share, 10), .mainMenu("File", .share, 10)],
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { $0.hasSelection },
                perform: { ctx in
                    guard let anchor = ctx.anchorView else { return }
                    SystemOpen.showSharePicker(ctx.selection.map(\.url), relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                }),
            ExplorerCommand(
                id: "file.copyPath", title: "Copy as Path", symbol: "link",
                shortcut: Shortcut("c", [.command, .option]),
                placements: [.itemContextMenu(.clipboard, 40), .backgroundContextMenu(.clipboard, 40), .mainMenu("Edit", .clipboard, 50),
                             .seeMore(.clipboard, 10), .treeContextMenu(.pin, 20)],
                isEnabled: { !$0.selection.isEmpty || $0.targetFolder != nil },
                perform: { ctx in
                    let paths = (ctx.selection.isEmpty ? ctx.targetFolder.map { [$0] } ?? [] : ctx.selection.map(\.url)).map(\.path)
                    FileClipboard.shared.writePaths(CopyAsPath.text(for: paths))
                    ctx.window?.statusBar.setMessage(paths.count == 1 ? "Copied path: \"\(paths[0])\"" : "Copied \(paths.count) paths.")
                }),
            ExplorerCommand(
                id: "file.openInTerminal", title: "Open in Terminal", symbol: "terminal",
                placements: [.itemContextMenu(.tools, 10), .backgroundContextMenu(.tools, 10), .treeContextMenu(.tools, 10),
                             .mainMenu("File", .tools, 20)],
                isAvailable: { ctx in ctx.surface != .itemContextMenu || ctx.selection.contains(where: \.isFolder) },
                isEnabled: { ctx in ctx.selection.contains(where: \.isFolder) || ctx.targetFolder != nil },
                perform: { ctx in
                    // The folder is passed as a document, never built into a shell command.
                    guard let folder = ctx.selection.first(where: \.isFolder)?.url ?? ctx.targetFolder,
                          SystemOpen.openTerminal(at: folder) else { NSSound.beep(); return }
                }),
            ExplorerCommand(
                id: "file.showInFinder", title: "Show in Finder", shortcut: Shortcut("r", [.command, .option]),
                placements: [.itemContextMenu(.tools, 20), .backgroundContextMenu(.tools, 20), .treeContextMenu(.tools, 20),
                             .mainMenu("File", .tools, 10)],
                isEnabled: { !$0.selection.isEmpty || $0.targetFolder != nil },
                perform: { ctx in
                    let urls = ctx.selection.map(\.url)
                    SystemOpen.reveal(urls.isEmpty ? ctx.targetFolder.map { [$0] } ?? [] : urls)
                }),
            ExplorerCommand(
                id: "file.pin", title: "Pin to Quick access", symbol: "pin",
                placements: [.itemContextMenu(.pin, 10), .treeContextMenu(.pin, 10), .seeMore(.pin, 10)],
                dynamicTitle: { ctx in pinTarget(ctx).map { QuickAccess.isPinned($0) } == true ? L10n.tr("Unpin from Quick access") : L10n.tr("Pin to Quick access") },
                isAvailable: { pinTarget($0) != nil },
                perform: { ctx in
                    guard let url = pinTarget(ctx) else { return }
                    if QuickAccess.isPinned(url) { QuickAccess.unpin(url) } else { QuickAccess.pin(url) }
                }),
            ExplorerCommand(
                id: "file.eject", title: "Eject", symbol: "eject",
                placements: [.treeContextMenu(.share, 90), .itemContextMenu(.share, 90)],
                dynamicTitle: { ctx in ctx.single.map { L10n.format("Eject “%@”", "\($0.name)") } ?? L10n.tr("Eject") },
                isAvailable: { ctx in ctx.single.map { isEjectable($0.url) } ?? false },
                perform: { ctx in
                    guard let url = ctx.single?.url else { return }
                    do {
                        try SystemOpen.eject(url)
                    } catch {
                        NSAlert.show(L10n.format("“%@” couldn't be ejected.", "\(displayName(of: url))"),
                                     L10n.format("%@\n\nClose any files or apps using it, then try again.", "\(error.localizedDescription)"),
                                     in: ctx.window?.window)
                    }
                }),
        ])
    }

    /// The selected or right-clicked folder, else the current one (from "…").
    static func pinTarget(_ ctx: CommandContext) -> URL? {
        if let item = ctx.single, item.isFolder, !Location.isVolumeRoot(item.url) { return item.url }
        if ctx.surface == .commandBar || ctx.surface == .script, ctx.selection.isEmpty { return ctx.location?.folderURL }
        return nil
    }

    static func isEjectable(_ url: URL) -> Bool {
        guard Location.isVolumeRoot(url), url.path != "/" else { return false }
        let v = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey])
        return (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false)
    }

    // MARK: Actions

    static func newFolder(_ ctx: CommandContext) {
        guard let folder = ctx.targetFolder, let window = ctx.window else { return }
        let name = NameRules.newFolderName { FileOps.exists(folder.appendingPathComponent($0)) }
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            NSAlert.show(L10n.format("Couldn't create a folder in “%@”.", "\(displayName(of: folder))"), error.localizedDescription, in: window.window)
            return
        }
        OperationCenter.shared.registerUndoNewFolder(url)
        if Location.folder(folder) == window.location { window.refreshSelecting([name], rename: name) }
    }

    static func moveToTrash(_ ctx: CommandContext) {
        let items = ctx.selection
        guard !items.isEmpty, let window = ctx.window else { NSSound.beep(); return }
        DeleteFlow.moveToTrash(items, window: window) { failed, reason in
            guard let host = window.window else { return }
            let alert = NSAlert()
            alert.messageText = DeleteFlow.cannotTrashTitle(failed)
            alert.informativeText = reason
            alert.addButton(withTitle: L10n.tr("Cancel"))
            alert.addButton(withTitle: L10n.tr("Delete Permanently…"))
            alert.beginSheetModal(for: host) { response in
                if response == .alertSecondButtonReturn {
                    DispatchQueue.main.async { confirmPermanentDelete(failed, ctx: ctx) }
                }
            }
        }
    }

    static func confirmPermanentDelete(_ items: [FileItem], ctx: CommandContext) {
        guard !items.isEmpty, let window = ctx.window, let host = window.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = items.count == 1 ? L10n.format("Permanently delete “%@”?", "\(items[0].name)") : L10n.format("Permanently delete %@ items?", "\(items.count)")
        alert.informativeText = L10n.tr("This can't be undone. The items won't go to the Trash.")
        let delete = alert.addButton(withTitle: L10n.tr("Delete Permanently"))
        let cancel = alert.addButton(withTitle: L10n.tr("Cancel"))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        let next = window.neighborURL(after: items)
        alert.beginSheetModal(for: host) { [weak window] response in
            guard response == .alertFirstButtonReturn else { return }
            DeleteFlow.deletePermanently(items, selecting: next, window: window)
        }
    }
}

/// Cut, Copy, Paste (with intent), Move Item Here, Undo/Redo, selection commands (FE-057, FE-084, FE-091).
enum ClipboardCommands {
    /// The right-clicked folder (item menu), else the current folder.
    static func pasteTarget(_ ctx: CommandContext) -> URL? {
        if ctx.surface == .itemContextMenu { return ctx.single.flatMap { $0.isFolder ? $0.url : nil } }
        return ctx.allowsEditing ? ctx.targetFolder : nil
    }

    static func register() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "edit.cut", title: "Cut", symbol: "scissors", shortcut: Shortcut("x"),
                placements: [.commandBar(10), .itemContextMenu(.clipboard, 10), .mainMenu("Edit", .clipboard, 10)],
                menuAction: #selector(NSText.cut(_:)),
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { $0.hasSelection && $0.allowsEditing },
                perform: { ctx in
                    let urls = ctx.selection.map(\.url)
                    FileClipboard.shared.write(urls, kind: .move)
                    ctx.window?.statusBar.setMessage((urls.count == 1 ? L10n.format("%@ cut. Paste to move it.", StatusText.items(urls.count)) : L10n.format("%@ cut. Paste to move them.", StatusText.items(urls.count))))
                }),
            ExplorerCommand(
                id: "edit.copy", title: "Copy", symbol: "doc.on.doc", shortcut: Shortcut("c"),
                placements: [.commandBar(20), .itemContextMenu(.clipboard, 20), .mainMenu("Edit", .clipboard, 20)],
                menuAction: #selector(NSText.copy(_:)),
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { ctx in ctx.hasSelection && !ctx.selection.contains { Location.isVolumeRoot($0.url) } },
                perform: { ctx in
                    let urls = ctx.selection.map(\.url)
                    FileClipboard.shared.write(urls, kind: .copy)
                    ctx.window?.statusBar.setMessage(L10n.format("%@ copied.", "\(StatusText.items(urls.count))"))
                }),
            ExplorerCommand(
                id: "edit.paste", title: "Paste", symbol: "doc.on.clipboard", shortcut: Shortcut("v"),
                placements: [.commandBar(30), .itemContextMenu(.clipboard, 30), .backgroundContextMenu(.clipboard, 10),
                             .mainMenu("Edit", .clipboard, 30)],
                menuAction: #selector(NSText.paste(_:)),
                dynamicTitle: { ctx in
                    ctx.surface == .itemContextMenu ? ctx.single.map { L10n.format("Paste into “%@”", "\($0.name)") } ?? L10n.tr("Paste") : L10n.tr("Paste")
                },
                isAvailable: { ctx in ctx.surface != .itemContextMenu || ctx.single?.isFolder == true },
                isEnabled: { ctx in FileClipboard.shared.canPaste && pasteTarget(ctx) != nil },
                perform: { ctx in paste(ctx, forceMove: false) }),
            ExplorerCommand(
                id: "edit.pasteMove", title: "Move Item Here", shortcut: Shortcut("v", [.command, .option]),
                placements: [.backgroundContextMenu(.clipboard, 20), .mainMenu("Edit", .clipboard, 40)],
                isEnabled: { ctx in FileClipboard.shared.canPaste && pasteTarget(ctx) != nil },
                perform: { ctx in paste(ctx, forceMove: true) }),
            ExplorerCommand(
                id: "edit.undo", title: "Undo", symbol: "arrow.uturn.backward", shortcut: Shortcut("z"),
                placements: [.mainMenu("Edit", .main, 10), .backgroundContextMenu(.clipboard, 30), .seeMore(.main, 10)],
                menuAction: Selector(("undo:")),
                dynamicTitle: { _ in OperationCenter.shared.undoManager.undoMenuItemTitle },
                isEnabled: { _ in OperationCenter.shared.undoManager.canUndo },
                perform: { _ in OperationCenter.shared.undoManager.undo() }),
            ExplorerCommand(
                id: "edit.redo", title: "Redo", shortcut: Shortcut("z", [.command, .shift]),
                placements: [.mainMenu("Edit", .main, 20)],
                menuAction: Selector(("redo:")),
                dynamicTitle: { _ in OperationCenter.shared.undoManager.redoMenuItemTitle },
                isEnabled: { _ in OperationCenter.shared.undoManager.canRedo },
                perform: { _ in OperationCenter.shared.undoManager.redo() }),
            ExplorerCommand(
                id: "edit.selectAll", title: "Select All", symbol: "checklist", shortcut: Shortcut("a"),
                placements: [.mainMenu("Edit", .selection, 10), .seeMore(.selection, 10)],
                menuAction: #selector(NSResponder.selectAll(_:)),
                isEnabled: { $0.window?.itemView != nil && !($0.window?.visibleItems.isEmpty ?? true) },
                perform: { ctx in
                    guard let window = ctx.window, let view = window.itemView else { return }
                    view.select(names: window.visibleItems.map(\.name))
                }),
            ExplorerCommand(
                id: "edit.selectNone", title: "Select None", symbol: "square.dashed",
                placements: [.mainMenu("Edit", .selection, 20), .seeMore(.selection, 20)],
                isEnabled: { $0.hasSelection },
                perform: { $0.window?.itemView?.select(names: []) }),
            ExplorerCommand(
                id: "edit.invertSelection", title: "Invert Selection", symbol: "arrow.left.arrow.right.square",
                placements: [.mainMenu("Edit", .selection, 30), .seeMore(.selection, 30)],
                isEnabled: { $0.window?.itemView != nil && !($0.window?.visibleItems.isEmpty ?? true) },
                perform: { ctx in
                    guard let window = ctx.window, let view = window.itemView else { return }
                    let selected = Set(ctx.selection.map(\.name))
                    view.select(names: window.visibleItems.map(\.name).filter { !selected.contains($0) })
                }),
        ])
    }

    static func paste(_ ctx: CommandContext, forceMove: Bool) {
        guard let folder = pasteTarget(ctx), let window = ctx.window else { NSSound.beep(); return }
        let urls = FileClipboard.shared.readURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let kind = forceMove ? .move : FileClipboard.shared.pasteKind(for: urls)
        window.startTransfer(kind, urls, to: folder) { report in
            if kind == .move, report.problems.isEmpty { FileClipboard.shared.finishedCut() }
        }
    }
}
