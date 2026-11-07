import AppKit
import ArborCore

/// Trash (Explorer's Recycle Bin): FE-077, FE-090 (Trash side). See docs/features/trash.md.
enum TrashFeature {
    static func register() {
        // Every move to Trash through SystemTrash is journaled, so Original Location and Date Deleted are known.
        SystemTrash.addObserver { original, trashed in
            TrashJournal.shared.record(original: original, trashed: trashed)
            TrashStore.noteChanged()
        }

        LocationRegistry.register(TrashProvider())
        DetailsColumns.register { $0 == .trash ? layout : nil }
        NavigationPaneExtras.register(.afterNetwork) {
            let node = NavNode(kind: .place, title: "Trash", location: .trash)
            node.icon = TrashIcon.image(full: TrashStore.isFull == true, size: 16)
            return [node]
        }
        registerCommands()
        adaptCoreCommands()
        registerDebugHooks()
        TrashStore.refreshState()
    }

    // MARK: Details columns: Name · Original Location · Date Deleted · Size · Item type · Date Modified

    static let layout = DetailsLayout(
        id: "trash",
        order: ["name", "originalLocation", "dateDeleted", "size", "type", "dateModified"],
        titles: ["type": "Item type", "dateModified": "Date Modified"],
        widths: ["name": 200],
        extras: [
            DetailsColumnSpec(id: "originalLocation", title: "Original Location", width: 210, minWidth: 80) { table, item in
                let cell = DetailsTextCell.make(table, id: "originalLocation", truncation: .byTruncatingMiddle)
                if let record = TrashStore.entry(for: item.url)?.record {
                    cell.label.stringValue = record.originalFolder
                    cell.label.toolTip = record.originalFolder
                    cell.label.textColor = Theme.secondaryText
                } else {
                    cell.label.stringValue = "Unknown"
                    cell.label.toolTip = "Arbor didn't move this item to the Trash, so its original location isn't known."
                    cell.label.textColor = Theme.disabledText
                }
                return cell
            },
            DetailsColumnSpec(id: "dateDeleted", title: "Date Deleted", width: 165, minWidth: 80) { table, item in
                let cell = DetailsTextCell.make(table, id: "dateDeleted")
                if let date = TrashStore.entry(for: item.url)?.dateDeleted {
                    cell.label.stringValue = TrashActions.dates.string(from: date)
                    cell.label.textColor = Theme.secondaryText
                    cell.label.toolTip = nil
                } else {
                    cell.label.stringValue = "Unknown"
                    cell.label.textColor = Theme.disabledText
                    cell.label.toolTip = "The deletion date isn't available for this item."
                }
                return cell
            },
        ])

    // MARK: Commands

    private static func inTrash(_ ctx: CommandContext) -> Bool { ctx.location == .trash }

    private static func registerCommands() {
        let backspace = String(Character(UnicodeScalar(8)))
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "trash.empty", title: "Empty Trash", symbol: "xmark.bin", tooltip: "Permanently delete everything in the Trash",
                shortcut: Shortcut(backspace, [.command, .shift]),
                placements: [.commandBarContextual(10), .backgroundContextMenu(.organize, 10), .treeContextMenu(.organize, 10),
                             .mainMenu("File", .organize, 40)],
                yieldsToTextInput: true, showsTitle: true,
                isAvailable: { ctx in
                    switch ctx.surface {
                    case .menuBar, .keyboard: return true
                    case .treeContextMenu: return ctx.treeLocation == .trash
                    default: return inTrash(ctx)
                    }
                },
                // Unknown (access denied) stays enabled: performing it explains what's needed.
                isEnabled: { _ in TrashStore.isFull != false },
                perform: { ctx in TrashActions.emptyTrash(window: ctx.window) }),
            ExplorerCommand(
                id: "trash.restoreSelected", title: "Restore the selected items", symbol: "arrow.uturn.backward",
                tooltip: "Put the selected items back where they were",
                placements: [.commandBarContextual(20), .itemContextMenu(.main, 5)],
                showsTitle: true,
                dynamicTitle: { $0.surface == .itemContextMenu ? "Restore" : "Restore the selected items" },
                isAvailable: { inTrash($0) && $0.hasSelection },
                isEnabled: { TrashActions.canRestore($0.selection) },
                perform: { ctx in TrashActions.restore(ctx.selection, window: ctx.window) }),
            ExplorerCommand(
                id: "trash.restoreAll", title: "Restore all items", symbol: "arrow.uturn.backward",
                tooltip: "Put every item back where it was (items Arbor moved to the Trash)",
                placements: [.commandBarContextual(20)],
                showsTitle: true,
                isAvailable: { inTrash($0) && !$0.hasSelection },
                isEnabled: { ctx in TrashActions.canRestore(ctx.window?.visibleItems ?? []) },
                perform: { ctx in TrashActions.restore(ctx.window?.visibleItems ?? [], window: ctx.window) }),
            ExplorerCommand(
                id: "trash.itemProperties", title: "Properties", symbol: "info.circle",
                placements: [.itemContextMenu(.properties, 10)],
                isAvailable: { inTrash($0) && $0.hasSelection },
                perform: { ctx in TrashActions.showItemProperties(ctx.selection, window: ctx.window) }),
            ExplorerCommand(
                id: "trash.properties", title: "Trash properties", symbol: "info.circle",
                placements: [.seeMore(.properties, 10), .treeContextMenu(.properties, 10), .backgroundContextMenu(.properties, 10)],
                dynamicTitle: { $0.surface == .commandBar ? "Trash properties" : "Properties" },
                isAvailable: { ctx in ctx.surface == .treeContextMenu ? ctx.treeLocation == .trash : inTrash(ctx) },
                perform: { ctx in TrashActions.showTrashProperties(window: ctx.window) }),
        ])
    }

    /// In the Trash, Delete means delete permanently (with Explorer's confirmation), and Cut is allowed
    /// (paste then moves the item out, like dragging it out). Elsewhere the core commands are unchanged.
    private static func adaptCoreCommands() {
        let registry = CommandRegistry.shared
        for id in ["file.trash", "file.deletePermanently"] {
            guard let command = registry.command(id) else { continue }
            let enabled = command.isEnabled, perform = command.perform
            let title = command.title, dynamic = command.dynamicTitle
            command.isEnabled = { ctx in inTrash(ctx) ? ctx.hasSelection : enabled(ctx) }
            command.perform = { ctx in
                if inTrash(ctx) { TrashActions.deletePermanently(ctx.selection, window: ctx.window) } else { perform(ctx) }
            }
            if id == "file.trash" {
                command.dynamicTitle = { ctx in inTrash(ctx) ? "Delete" : (dynamic?(ctx) ?? title) }
            }
        }
        if let cut = registry.command("edit.cut") {
            let enabled = cut.isEnabled
            cut.isEnabled = { ctx in inTrash(ctx) ? ctx.hasSelection : enabled(ctx) }
        }
    }

    // MARK: Scripted checks

    private static func registerDebugHooks() {
        // sheetshot:/path.png draws the window's attached sheet (alerts aren't part of `snapshot:`).
        DebugScript.registerStep("sheetshot") { path, window in
            guard let frame = (window?.window?.attachedSheet ?? NSApp.modalWindow)?.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return 0.3 }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return 0.3
        }
        DebugScript.registerLogger { window in
            guard let sheet = window.window?.attachedSheet ?? NSApp.modalWindow, let root = sheet.contentView else { return "sheet text: -" }
            func texts(_ view: NSView) -> [String] {
                var out: [String] = []
                if let button = view as? NSButton, !button.title.isEmpty { out.append("[\(button.title)]") }
                else if let field = view as? NSTextField, !field.stringValue.isEmpty { out.append(field.stringValue) }
                return out + view.subviews.flatMap(texts)
            }
            return "sheet text: " + texts(root).joined(separator: " / ").replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        DebugScript.registerLogger { window in
            guard window.location == .trash else { return "trash: (not shown) full=\(String(describing: TrashStore.isFull))" }
            var text = "trash: full=\(String(describing: TrashStore.isFull)) denied=\(TrashStore.lastListingDenied)"
            if let details = window.itemView as? DetailsViewController {
                text += " layout=\(DetailsColumns.activeLayoutID(of: details.table) ?? "-")"
                text += " columns=" + details.table.tableColumns.filter { !$0.isHidden }.map(\.title).joined(separator: "|")
            }
            for item in window.visibleItems {
                let entry = TrashStore.entry(for: item.url)
                text += "\n  \(item.name) ← \(entry?.record?.originalFolder ?? "Unknown")"
                    + " · deleted \(entry?.dateDeleted.map { TrashActions.dates.string(from: $0) } ?? "Unknown")"
            }
            return text
        }
    }
}
