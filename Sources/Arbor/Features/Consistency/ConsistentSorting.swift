import AppKit
import ArborCore

/// Every column sorts everywhere: features' extra columns get sort values and Sort ▾ entries, and
/// search results open in relevance order (FE-145). See docs/features/consistency.md.
enum ConsistentSorting {
    /// Sort values for columns that aren't in `ColumnCatalog`, by column id. nil = still loading.
    private static let values: [String: (FileItem) -> ColumnValue?] = makeValues()

    /// The search whose results are being ordered (the location a tab is about to display).
    static var searchLocation: Location?

    /// Sort ▾ entries for extra columns: id → fallback title (the layout's own title wins).
    static let extraColumns: [(id: String, title: String)] = [
        ("originalLocation", "Original Location"), ("dateDeleted", "Date Deleted"), ("cloudStatus", "Status"),
        ("search.folder", "Folder"), ("search.match", "Match"), ("archive.compressedSize", "Compressed size"),
        ("archive.passwordProtected", "Password protected"), ("archive.ratio", "Ratio"),
    ]

    static func register() {
        // Answers for the extra columns before the metadata cache (details-depth.metadata, order .late).
        FileSorter.columnValues.register("consistency.extra-columns") { item, column in
            values[column.rawValue].map { value in value(item) }
        }
        WindowHooks.willDisplay.observe("consistency.relevance-order") { _, tab, location, changed in
            adjustOrder(tab, location, changed)
        }
        WindowHooks.viewStateChanged.observe("consistency.relevance-memory") { window, tab in
            if case .search? = tab.displayedLocation { searchLocation = tab.displayedLocation }
            // The order picked for results is the tab's; the folder default stays untouched.
            if RelevanceMemory.isSearch(tab), SearchRelevance.isRelevance(Prefs.sortOrder) {
                Prefs.sortOrder = RelevanceMemory.folderOrder(tab)
            }
            _ = window
        }
        registerCommands()
    }

    // MARK: Values

    private static func makeValues() -> [String: (FileItem) -> ColumnValue?] {
        var values: [String: (FileItem) -> ColumnValue?] = [:]
        values["originalLocation"] = { item in
            TrashStore.entry(for: item.url)?.record.map { .text($0.originalFolder) } ?? .unknown
        }
        values["dateDeleted"] = { item in
            TrashStore.entry(for: item.url)?.dateDeleted.map(ColumnValue.date) ?? .unknown
        }
        values["cloudStatus"] = { item in
            guard let status = CloudStatusStore.shared.status(for: item.url) else { return nil }
            return cloudRank(status).map { .number(Double($0)) } ?? .unsupported
        }
        values["search.folder"] = { item in .text(SearchColumns.folderText(item, searchLocation)) }
        values["search.match"] = { item in
            guard let reasons = SearchSortContext.current?.reasons(item), !reasons.isEmpty else { return .empty }
            return .text(reasons.sorted().map(\.label).joined(separator: ", "))
        }
        values["archive.compressedSize"] = { item in
            guard !item.isFolder else { return .unsupported }
            return archiveEntry(item)?.compressedSize.map(ColumnValue.bytes) ?? .unknown
        }
        values["archive.passwordProtected"] = { item in
            guard !item.isFolder else { return .unsupported }
            return archiveEntry(item).map { .text($0.isEncrypted ? L10n.tr("Yes") : L10n.tr("No")) } ?? .unknown
        }
        values["archive.ratio"] = { item in
            guard !item.isFolder, let e = archiveEntry(item), let size = e.size, let packed = e.compressedSize else { return .unknown }
            return .number(size > 0 ? max(0, 100 - Double(packed) * 100 / Double(size)) : 0)
        }
        values[SearchRelevance.column.rawValue] = { item in
            SearchSortContext.current.map { .number($0.score(item)) }
        }
        return values
    }

    private static func archiveEntry(_ item: FileItem) -> ArchiveEntry? {
        ArchiveCatalog.shared.entry(for: item)?.node?.entry
    }

    /// Explorer's Status order: available, syncing, online-only, then problems.
    static func cloudRank(_ status: CloudStatus) -> Int? {
        switch status {
        case .availableOnDevice: return 0
        case .syncPending: return 1
        case .uploading: return 2
        case .downloading: return 3
        case .onlineOnly: return 4
        case .conflict: return 5
        case .error: return 6
        case .unknown: return nil
        }
    }

    // MARK: Relevance as the default order of search results

    private static func adjustOrder(_ tab: TabState, _ location: Location, _ changed: Bool) {
        let wasSearch = RelevanceMemory.isSearch(tab)
        if case .search = location {
            searchLocation = location
            RelevanceMemory.setSearch(tab, true)
            guard changed, !wasSearch else { return }      // refining keeps the order the user picked
            RelevanceMemory.rememberFolderOrder(tab, tab.sortOrder)
            tab.sortOrder = SearchRelevance.defaultOrder
            tab.invalidateVisibleItems()
            return
        }
        RelevanceMemory.setSearch(tab, false)
        // Leaving results restores the order from before the search.
        if SearchRelevance.isRelevance(tab.sortOrder) || (wasSearch && changed && location.folderURL == nil) {
            tab.sortOrder = RelevanceMemory.folderOrder(tab)
            tab.invalidateVisibleItems()
        }
    }

    // MARK: Sort ▾

    private static func registerCommands() {
        let r = CommandRegistry.shared
        r.register(ExplorerCommand(
            id: "sort.relevance", title: "Relevance",
            placements: [.sortMenu(.main, -2)],
            isAvailable: { ctx in if case .search? = ctx.location { return true }; return false },
            isEnabled: { $0.tab != nil },
            state: { ctx in ctx.tab.map { SearchRelevance.isRelevance($0.sortOrder) } == true ? .on : .off },
            perform: { ctx in
                guard let window = ctx.window else { return }
                let folderDefault = Prefs.sortOrder
                window.setSortOrder(SearchRelevance.defaultOrder)
                Prefs.sortOrder = folderDefault
            }))
        for (i, column) in extraColumns.enumerated() {
            let id = ColumnID(column.id)
            func spec(_ ctx: CommandContext) -> DetailsColumnSpec? {
                DetailsColumns.layout(for: ctx.location)?.extras.first { $0.id == column.id }
            }
            r.register(ExplorerCommand(
                id: "sort.extra.\(column.id)", title: column.title,
                placements: [.sortMenu(.main, 5 + Double(i) * 0.1)],
                dynamicTitle: { ctx in spec(ctx)?.title ?? column.title },
                isAvailable: { ctx in ctx.tab?.showsPage == false && spec(ctx) != nil },
                isEnabled: { $0.tab != nil },
                state: { ctx in ctx.tab?.sortOrder.primaryColumn == id ? .on : .off },
                perform: { ctx in
                    guard let window = ctx.window, var order = ctx.tab?.sortOrder else { return }
                    if order.primaryColumn == id { order.ascending.toggle() } else { order.setPrimary(id, ascending: true) }
                    window.setSortOrder(order)
                }))
        }
    }
}

/// Per-tab memory for relevance ordering.
enum RelevanceMemory {
    private static var searching = Set<UUID>()
    private static var folderOrders: [UUID: FileSortOrder] = [:]

    static func isSearch(_ tab: TabState) -> Bool { searching.contains(tab.id) }
    static func setSearch(_ tab: TabState, _ on: Bool) {
        if on { searching.insert(tab.id) } else { searching.remove(tab.id) }
    }

    static func rememberFolderOrder(_ tab: TabState, _ order: FileSortOrder) {
        guard !SearchRelevance.isRelevance(order) else { return }
        if folderOrders.count > 64 { folderOrders.removeAll() }
        folderOrders[tab.id] = order
    }

    static func folderOrder(_ tab: TabState) -> FileSortOrder {
        if let order = folderOrders[tab.id] { return order }
        let pref = Prefs.sortOrder
        return SearchRelevance.isRelevance(pref) ? FileSortOrder() : pref
    }
}

/// Looks the session up once per search, not per comparison; scores are kept until the count changes.
final class SearchSortContext {
    private static var cached: SearchSortContext?

    static var current: SearchSortContext? {
        guard case .search(let request)? = ConsistentSorting.searchLocation else { return nil }
        if let cached, cached.request == request, cached.session != nil { return cached }
        let context = SearchSortContext(request: request)
        cached = context
        return context
    }

    /// Forgets the session (Refresh replaced it).
    static func reset() { cached = nil }

    let request: SearchRequest
    private(set) weak var session: SearchSession?
    let words: [String]
    private var scores: [String: Double] = [:]
    private var scoredCount = -1

    init(request: SearchRequest) {
        self.request = request
        session = SearchProvider.session(for: .search(request))
        words = SearchRelevance.nameWords(request.query)
    }

    func reasons(_ item: FileItem) -> Set<SearchReason>? { session?.reasons(forPath: item.url.path) }

    func score(_ item: FileItem) -> Double {
        let count = session?.count ?? 0
        if count != scoredCount { scores = [:]; scoredCount = count }
        if let score = scores[item.url.path] { return score }
        let score = SearchRelevance.score(name: item.name, words: words, reasons: reasons(item))
        scores[item.url.path] = score
        return score
    }
}
