import AppKit
import ArborCore

/// View modes, panes, sorting, Quick Look, and the shared New ▸ / Sort by ▸ / View ▸ submenus.
enum ViewCommands {
    /// macOS virtual key codes for the digit keys 1…8 (⇧⌘1…8 = Explorer's Ctrl+Shift+1…8).
    static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]

    static func register() {
        let r = CommandRegistry.shared
        for mode in ViewMode.allCases {
            let n = mode.shortcutNumber
            var placements: [CommandPlacement] = [.viewMenu(.main, Double(n)), .mainMenu("View", .main, Double(n))]
            if mode == .details { placements.append(.statusBarTrailing(1)) }
            if mode == .largeIcons { placements.append(.statusBarTrailing(2)) }
            r.register(ExplorerCommand(
                id: "view.mode.\(mode.rawValue)", title: mode.title, symbol: mode.symbolName,
                tooltip: mode == .details ? L10n.tr("Display information about each item in the window") : mode.title,
                shortcut: Shortcut("\(n)", [.command, .shift]),
                keyBindings: [KeyBinding(digitKeyCodes[n - 1], [.command, .shift], scope: .window)],
                placements: placements,
                isEnabled: { ctx in ctx.window != nil && ViewModeRegistry.isRegistered(mode) },
                state: { ctx in ctx.tab.map { ViewModeRegistry.effective($0.viewMode) } == mode ? .on : .off },
                perform: { $0.window?.setViewMode(mode) }))
        }

        r.register([
            ExplorerCommand(
                id: "view.compact", title: "Compact View", symbol: "rectangle.compress.vertical",
                placements: [.viewMenu(.view, 10), .mainMenu("View", .view, 10)],
                state: { _ in Prefs.compactView ? .on : .off },
                perform: { _ in Prefs.compactView.toggle() }),
            submenuCommand(id: "menu.show", title: "Show", symbol: "checkmark.square", slot: .showMenu,
                           placements: [.viewMenu(.properties, 10), .mainMenu("View", .view, 20)]),
            ExplorerCommand(
                id: "view.navigationPane", title: "Navigation Pane", shortcut: Shortcut("s", [.command, .control]),
                placements: [.showMenu(.main, 10)],
                state: { _ in Prefs.navigationPaneVisible ? .on : .off },
                perform: { _ in Prefs.navigationPaneVisible.toggle() }),
            ExplorerCommand(
                id: "view.detailsPane", title: "Details", symbol: "sidebar.right", tooltip: "Details pane",
                shortcut: Shortcut("P", [.command, .option]),   // ⇧⌥⌘P = Alt+Shift+P
                placements: [.showMenu(.main, 20), .commandBarTrailing(10)],
                showsTitle: true,
                dynamicTitle: { $0.surface == .commandBar ? L10n.tr("Details") : L10n.tr("Details Pane") },
                isEnabled: { $0.window != nil },
                state: { _ in Prefs.sidePane == "details" ? .on : .off },
                perform: { $0.window?.toggleSidePane("details") }),
            ExplorerCommand(
                id: "view.previewPane", title: "Preview Pane", symbol: "eye",
                shortcut: Shortcut("p", [.command, .option]),   // ⌥⌘P = Alt+P
                placements: [.showMenu(.main, 30)],
                isEnabled: { $0.window != nil },
                state: { _ in Prefs.sidePane == "preview" ? .on : .off },
                perform: { $0.window?.toggleSidePane("preview") }),
            ExplorerCommand(
                id: "view.itemCheckBoxes", title: "Item Check Boxes",
                placements: [.showMenu(.items, 10)],
                state: { _ in Prefs.itemCheckBoxes ? .on : .off },
                perform: { _ in Prefs.itemCheckBoxes.toggle() }),
            ExplorerCommand(
                id: "view.extensions", title: "File Name Extensions",
                placements: [.showMenu(.items, 20)],
                state: { _ in Prefs.showExtensions ? .on : .off },
                perform: { _ in Prefs.showExtensions.toggle() }),
            ExplorerCommand(
                id: "view.hiddenItems", title: "Hidden Items", shortcut: Shortcut(".", [.command, .shift]),
                placements: [.showMenu(.items, 30)],
                state: { _ in Prefs.showHidden ? .on : .off },
                perform: { _ in Prefs.showHidden.toggle() }),
            ExplorerCommand(
                id: "view.sizeColumnsToFit", title: "Size All Columns to Fit",
                placements: [.mainMenu("View", .view, 40)],
                isEnabled: { $0.window?.itemView != nil },
                perform: { $0.window?.itemView?.sizeToFit() }),
            ExplorerCommand(
                id: "view.quickLook", title: "Quick Look", shortcut: Shortcut("y"),
                keyBindings: [KeyBinding(49)],   // Space
                placements: [.mainMenu("File", .share, 20)],
                isEnabled: { $0.hasSelection },
                perform: { $0.window?.toggleQuickLook() }),
        ])

        // Sort ▾
        for (i, key) in SortKey.allCases.enumerated() {
            r.register(ExplorerCommand(
                id: "sort.\(key.rawValue)", title: key.title,
                placements: [.sortMenu(.main, Double(i))],
                isEnabled: { $0.tab != nil },
                state: { ctx in ctx.tab?.sortOrder.key == key ? .on : .off },
                perform: { ctx in
                    guard let window = ctx.window, var order = ctx.tab?.sortOrder else { return }
                    if order.key == key { order.ascending.toggle() } else { order.key = key; order.ascending = true }
                    window.setSortOrder(order)
                }))
        }
        for ascending in [true, false] {
            r.register(ExplorerCommand(
                id: ascending ? "sort.ascending" : "sort.descending", title: ascending ? L10n.tr("Ascending") : L10n.tr("Descending"),
                placements: [.sortMenu(.view, ascending ? 10 : 20)],
                isEnabled: { $0.tab != nil },
                state: { ctx in ctx.tab?.sortOrder.ascending == ascending ? .on : .off },
                perform: { ctx in
                    guard let window = ctx.window, var order = ctx.tab?.sortOrder else { return }
                    order.ascending = ascending
                    window.setSortOrder(order)
                }))
        }
        r.register([
            ExplorerCommand(
                id: "sort.foldersFirst", title: "Folders First",
                placements: [.sortMenu(.properties, 10)],
                isEnabled: { $0.tab != nil },
                state: { ctx in ctx.tab?.sortOrder.foldersFirst == true ? .on : .off },
                perform: { ctx in
                    guard let window = ctx.window, var order = ctx.tab?.sortOrder else { return }
                    order.foldersFirst.toggle()
                    window.setSortOrder(order)
                }),
            // Context-menu and menu-bar mirrors of the command bar's drop-downs.
            submenuCommand(id: "menu.view", title: "View", symbol: "list.bullet.rectangle", slot: .viewMenu,
                           placements: [.backgroundContextMenu(.view, 10)]),
            submenuCommand(id: "menu.sortBy", title: "Sort By", symbol: "arrow.up.arrow.down", slot: .sortMenu,
                           placements: [.backgroundContextMenu(.view, 20), .mainMenu("View", .view, 30)]),
            submenuCommand(id: "menu.new", title: "New", symbol: "plus.circle", slot: .newMenu,
                           placements: [.backgroundContextMenu(.new, 10)]),
        ])
    }

    /// A command whose submenu lists another slot's commands (with the same frozen context).
    static func submenuCommand(id: String, title: String, symbol: String?, slot: CommandSlot,
                               placements: [CommandPlacement]) -> ExplorerCommand {
        ExplorerCommand(id: id, title: title, symbol: symbol, placements: placements,
                        submenu: { ctx in CommandDispatcher.shared.items(for: slot, context: ctx) })
    }
}

extension MenuSection {
    /// Show ▸ items that affect how items are drawn.
    static let items = MenuSection(rank: 820, name: "items")
}
