import AppKit
import ArborCore

/// Context menus only list commands that can act on what was right-clicked, in every location
/// (docs/features/consistency.md). Each rule hides a registered command in context menus where it
/// can't apply; the command bar and the menu bar keep showing it greyed, like Explorer.
enum MenuAudit {
    /// Commands that, in a context menu, are left out rather than greyed when they're disabled:
    /// they're disabled only because the place or the item doesn't support them (This Mac's drives
    /// can't be cut or trashed, search results have no folder to create shortcuts in…).
    static let hiddenWhenDisabled = ["edit.cut", "edit.copy", "file.rename",
                                     "file.trash", "file.share", "file.createShortcut", "file.openInTerminal", "file.copyPath",
                                     "file.showInFinder"]

    /// Everything that needs the selection to be files on disk.
    static let fileCommands = ["edit.cut", "edit.copy", "edit.paste", "edit.pasteShortcut", "edit.pasteMove", "file.copyPath",
                               "file.share", "file.openWith", "file.showInFinder", "file.openInTerminal", "file.pin", "home.favorite",
                               "file.sendTo", "file.createShortcut", "file.rename", "file.trash", "file.deletePermanently",
                               "file.properties", "archive.compressTo", "image.setBackground", "image.rotateLeft", "image.rotateRight",
                               "file.showPackageContents"]

    /// Not offered for items in the Trash (Explorer's Recycle Bin: Restore, Cut, Delete, Properties).
    static let notInTrash = ["file.openWith", "file.copyPath", "file.share", "home.favorite", "file.sendTo", "file.createShortcut",
                             "file.rename", "file.pin", "archive.compressTo", "image.setBackground", "image.rotateLeft",
                             "image.rotateRight", "file.openInTerminal", "menu.new", "edit.pasteShortcut", "edit.pasteMove",
                             "file.properties"]   // the Trash has its own Properties (trash.itemProperties / trash.properties)

    /// Not offered inside archives (members are read-only and not on disk).
    static let notInArchive = ["edit.cut", "file.rename", "file.trash", "file.share", "file.createShortcut", "file.copyPath",
                               "file.openInTerminal", "menu.new", "edit.paste", "edit.pasteShortcut", "edit.pasteMove",
                               "file.deletePermanently", "image.setBackground", "image.rotateLeft", "image.rotateRight"]

    static func register() {
        for id in hiddenWhenDisabled {
            hide(id, "consistency.hide-when-disabled") { ctx in CommandRegistry.shared.command(id)?.isEnabled(ctx) == false }
        }
        for id in fileCommands { hide(id, "consistency.disconnected-drive", when: involvesDisconnectedDrive) }
        for id in notInTrash { hide(id, "consistency.not-in-trash") { $0.location == .trash && $0.surface != .treeContextMenu } }
        for id in notInArchive {
            hide(id, "consistency.not-in-archive") { $0.location?.archiveFile != nil && $0.surface != .treeContextMenu }
        }
        // New and Paste on the background need a folder to put items in (search results, Home, Gallery
        // have none); in folders they stay, greyed while the clipboard is empty, like Explorer.
        for id in ["menu.new", "edit.paste", "edit.pasteShortcut", "edit.pasteMove"] {
            hide(id, "consistency.background-needs-folder") { ctx in
                ctx.surface == .backgroundContextMenu && (ctx.targetFolder == nil || !ctx.allowsEditing)
            }
        }
        // A page without a folder has no path to copy.
        hide("file.copyPath", "consistency.no-path-to-copy") { ctx in
            ctx.surface == .backgroundContextMenu && [.gallery, .home, .thisMac, .network].contains(ctx.location)
        }
    }

    static func isContextMenu(_ ctx: CommandContext) -> Bool {
        [.itemContextMenu, .backgroundContextMenu, .treeContextMenu].contains(ctx.surface)
    }

    /// Hides a command in context menus while `rule` holds; it stays available elsewhere. These rules
    /// only ever hide, so their order among other overrides doesn't change the result.
    static func hide(_ commandID: String, _ id: String, when rule: @escaping (CommandContext) -> Bool) {
        CommandRegistry.shared.hide(commandID, id) { ctx in isContextMenu(ctx) && rule(ctx) }
    }

    /// A disconnected mapped drive (its row stands for a share that isn't mounted): only opening,
    /// reconnecting and disconnecting apply.
    static func involvesDisconnectedDrive(_ ctx: CommandContext) -> Bool {
        let urls = ctx.surface == .treeContextMenu ? [ctx.treeLocation?.folderURL ?? ctx.targetFolder].compactMap { $0 } : ctx.selection.map(\.url)
        return urls.contains { NetworkThisMac.drive(forPlaceholder: $0) != nil }
    }
}
