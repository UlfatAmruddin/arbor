import AppKit
import ArborCore

/// Details view depth: Group by, column header filters, more columns with lazily loaded metadata,
/// Choose Details, column sets per folder kind, and sorting by any column
/// (FE-035, FE-036, FE-038, FE-039, FE-040, FE-051, FE-235). See docs/features/grouping.md.
enum DetailsDepth: ExplorerFeature {
    static let id = "details-depth"
    static func register() {
        FileSorter.columnValues.register("details-depth.metadata", order: .late) { item, column in .some(lookup(item, column)) }
        TabState.visibleItemsFilter.add("details-depth.column-filters") { items, tab in filter(tab, items) }
        registerSortCommands()
        registerGroupCommands()
        registerDebugSteps()
    }

    /// Metadata cache lookup (nil = still loading).
    static let lookup: ColumnValueLookup = { item, column in ColumnValueStore.shared.value(item, column) }

    static func allValuesOwner(_ tab: TabState) -> String { "all-\(tab.id.uuidString)" }

    // MARK: Pipeline hook

    /// Applies the tab's column filters and makes sure columns used for sorting, grouping and
    /// filtering are loaded for every item (they're needed to order the whole folder).
    static func filter(_ tab: TabState, _ items: [FileItem]) -> [FileItem] {
        let options = ViewOptions.options(for: tab)
        let needed = options.columnsNeedingAllValues(sort: tab.sortOrder)
        if !needed.isEmpty, let all = tab.items {
            ColumnValueStore.shared.request(all, columns: needed, owner: allValuesOwner(tab), batchSize: 32) { [weak tab] _ in
                if let tab { scheduleRefresh(tab) }
            }
        }
        return options.filters.apply(items, lookup: lookup)
    }

    private static var pendingRefresh = Set<UUID>()

    static func scheduleRefresh(_ tab: TabState) {
        guard pendingRefresh.insert(tab.id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak tab] in
            guard let tab else { return }
            pendingRefresh.remove(tab.id)
            refresh(tab)
        }
    }

    /// Re-runs filter, sort and grouping for a tab and redraws it if it's on screen.
    static func refresh(_ tab: TabState?) {
        guard let tab else { return }
        tab.invalidateVisibleItems()
        guard let window = window(of: tab), window.activeTab === tab, !tab.showsPage, tab.items != nil else { return }
        window.setSortOrder(tab.sortOrder)   // redisplays the active tab with its current order
    }

    static func window(of tab: TabState) -> BrowserWindowController? {
        (NSApp.delegate as? AppDelegate)?.controllers.first { $0.tabs.contains { $0 === tab } }
    }

    static func clearFilters(_ tab: TabState?) {
        guard let tab else { return }
        ViewOptions.options(for: tab).filters.clear()
        refresh(tab)
        (window(of: tab)?.itemView as? DetailsViewController)?.headerOverlay?.needsDisplay = true
    }

    private static var saveWork: DispatchWorkItem?

    /// Saves a resized/reordered column set after the drag settles.
    static func saveLater(_ options: TabViewOptions) {
        saveWork?.cancel()
        let work = DispatchWorkItem { ViewOptions.saveEditedColumns(options) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Context helpers

    static func options(_ ctx: CommandContext) -> TabViewOptions? {
        guard let tab = ctx.tab, !tab.showsPage else { return nil }
        return ViewOptions.options(for: tab)
    }

    static func details(_ ctx: CommandContext) -> DetailsViewController? { ctx.window?.itemView as? DetailsViewController }

    /// Columns of the tab's Details set (the Sort ▾ list follows them, like Explorer).
    static func visibleColumns(_ ctx: CommandContext) -> [ColumnID] { options(ctx)?.columns.ids ?? [] }

    static let coreColumns: [ColumnID] = [.name, .dateModified, .type, .size]

    // MARK: Sort ▾ (FE-235)

    static func sortBy(_ ctx: CommandContext, _ column: ColumnID) {
        guard let window = ctx.window, var order = ctx.tab?.sortOrder else { return }
        if order.primaryColumn == column { order.ascending.toggle() } else { order.setPrimary(column, ascending: true) }
        window.setSortOrder(order)
    }

    private static func registerSortCommands() {
        let r = CommandRegistry.shared
        // Replace the core Name/Date modified/Type/Size items so they know about column sorts.
        for (i, key) in SortKey.allCases.enumerated() {
            let column = ColumnID(key.rawValue)
            r.replace(ExplorerCommand(
                id: "sort.\(key.rawValue)", title: key.title,
                placements: [.sortMenu(.main, Double(i))],
                isEnabled: { $0.tab != nil },
                state: { ctx in ctx.tab?.sortOrder.primaryColumn == column ? .on : .off },
                perform: { sortBy($0, column) }), "details-depth.column-sorts")
        }
        // Other columns appear while they are shown in Details.
        for (i, d) in ColumnCatalog.builtIn.enumerated() where !coreColumns.contains(d.id) {
            r.register(ExplorerCommand(
                id: "sort.column.\(d.id.rawValue)", title: d.title,
                placements: [.sortMenu(.main, 10 + Double(i))],
                isAvailable: { visibleColumns($0).contains(d.id) },
                isEnabled: { $0.tab != nil },
                state: { ctx in ctx.tab?.sortOrder.primaryColumn == d.id ? .on : .off },
                perform: { sortBy($0, d.id) }))
        }
        r.register(ExplorerCommand(
            id: "sort.more", title: "More…", tooltip: "Choose which details (columns) to show",
            placements: [.sortMenu(.main, 100)],
            isAvailable: { options($0) != nil },
            isEnabled: { details($0) != nil },
            perform: { details($0)?.presentChooseDetails() }))
        r.register(ExplorerCommand(
            id: "filters.clear", title: "Clear Filters", symbol: "line.3.horizontal.decrease.circle",
            placements: [.backgroundContextMenu(.view, 27)],
            isAvailable: { options($0)?.filters.isEmpty == false },
            perform: { clearFilters($0.tab) }))
    }

    // MARK: Group by (FE-038)

    static let groupSection = MenuSection(rank: 860, name: "groupBy")
    static let groupColumns: [ColumnID] = [.name, .dateModified, .type, .size, .dateCreated]

    static func setGroup(_ ctx: CommandContext, _ column: ColumnID?) {
        guard let tab = ctx.tab, let o = options(ctx) else { return }
        o.groupBy = column
        o.collapsed = []
        ViewOptions.rememberGroup(o)
        refresh(tab)
        details(ctx)?.scrollToTop()
    }

    static func setGroupAscending(_ ctx: CommandContext, _ ascending: Bool) {
        guard let tab = ctx.tab, let o = options(ctx) else { return }
        o.groupAscending = ascending
        ViewOptions.rememberGroup(o)
        refresh(tab)
        details(ctx)?.scrollToTop()
    }

    /// Group by ▸ entries: the usual columns, then other shown columns, (None), More…, direction.
    static func groupMenuItems(_ ctx: CommandContext) -> [NSMenuItem] {
        let r = CommandRegistry.shared
        var ids = groupColumns
        ids += visibleColumns(ctx).filter { !ids.contains($0) }
        var items = ids.compactMap { r.command("group.\($0.rawValue)") }.map { CommandDispatcher.shared.menuItem($0, context: ctx) }
        for id in ["group.none", "group.more"] { if let c = r.command(id) { items.append(CommandDispatcher.shared.menuItem(c, context: ctx)) } }
        items.append(.separator())
        for id in ["group.ascending", "group.descending"] { if let c = r.command(id) { items.append(CommandDispatcher.shared.menuItem(c, context: ctx)) } }
        return items
    }

    private static func registerGroupCommands() {
        let r = CommandRegistry.shared
        for d in ColumnCatalog.builtIn {
            r.register(ExplorerCommand(
                id: "group.\(d.id.rawValue)", title: d.title,
                isEnabled: { options($0) != nil },
                state: { options($0)?.groupBy == d.id ? .on : .off },
                perform: { setGroup($0, d.id) }))
        }
        r.register([
            ExplorerCommand(id: "group.none", title: "(None)",
                            isEnabled: { options($0) != nil },
                            state: { options($0).map { $0.groupBy == nil ? .on : .off } ?? .off },
                            perform: { setGroup($0, nil) }),
            ExplorerCommand(id: "group.more", title: "More…",
                            isEnabled: { details($0) != nil },
                            perform: { details($0)?.presentChooseDetails() }),
            ExplorerCommand(id: "group.ascending", title: "Ascending",
                            isEnabled: { options($0)?.groupBy != nil },
                            state: { ctx in options(ctx).map { $0.groupBy != nil && $0.groupAscending ? .on : .off } ?? .off },
                            perform: { setGroupAscending($0, true) }),
            ExplorerCommand(id: "group.descending", title: "Descending",
                            isEnabled: { options($0)?.groupBy != nil },
                            state: { ctx in options(ctx).map { $0.groupBy != nil && !$0.groupAscending ? .on : .off } ?? .off },
                            perform: { setGroupAscending($0, false) }),
            // Sort ▾ → Group by ▸ (command bar only; context menus get their own entry, not nested in Sort by ▸).
            ExplorerCommand(id: "menu.groupBy", title: "Group By", symbol: "rectangle.grid.1x2",
                            placements: [.sortMenu(groupSection, 10)],
                            isAvailable: { ($0.surface == .commandBar || $0.surface == .script) && options($0) != nil },
                            submenu: { groupMenuItems($0) }),
            ExplorerCommand(id: "menu.groupByContext", title: "Group By", symbol: "rectangle.grid.1x2",
                            placements: [.backgroundContextMenu(.view, 25), .mainMenu("View", .view, 31)],
                            isAvailable: { $0.surface == .menuBar || options($0) != nil },
                            submenu: { groupMenuItems($0) }),
        ])
    }
}
