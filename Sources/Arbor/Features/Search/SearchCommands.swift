import AppKit
import UniformTypeIdentifiers
import ArborCore

/// Search results commands: "Search options ▾" and "Close search" in the command bar (Explorer shows
/// them while searching), "Open file location" for results, and "Save search" (FE-136, FE-137, FE-138).
enum SearchCommands {
    static func isSearch(_ location: Location?) -> Bool {
        if case .search? = location { return true }
        return false
    }

    static func register() {
        let r = CommandRegistry.shared
        r.register([
            ExplorerCommand(
                id: "search.options", title: "Search options", symbol: "slider.horizontal.3",
                tooltip: "Refine this search",
                placements: [.commandBarContextual(10)],
                showsTitle: true,
                isAvailable: { isSearch($0.location) },
                submenu: { optionsMenu($0) }),
            ExplorerCommand(
                id: "search.close", title: "Close search", symbol: "xmark", tooltip: "Close search and go back",
                placements: [.commandBarContextual(20), .mainMenu("Edit", .tools, 20)],
                showsTitle: true,
                isAvailable: { $0.surface == .menuBar || isSearch($0.location) },
                isEnabled: { isSearch($0.location) },
                perform: { ExplorerSearchController.controller(for: $0.window)?.closeSearch() }),
            ExplorerCommand(
                id: "search.openFileLocation", title: "Open file location", symbol: "folder",
                placements: [.itemContextMenu(.open, 25), .mainMenu("File", .open, 25)],
                isAvailable: { ctx in ctx.surface == .menuBar || (isSearch(ctx.location) && ctx.single != nil) },
                isEnabled: { ctx in isSearch(ctx.location) && ctx.single != nil },
                perform: { ctx in
                    guard let item = ctx.single else { return }
                    ctx.window?.navigate(to: .folder(item.url.deletingLastPathComponent()), select: [item.name])
                }),
            ExplorerCommand(
                id: "search.save", title: "Save Search…", symbol: "square.and.arrow.down",
                placements: [.mainMenu("File", .share, 30)],
                isEnabled: { isSearch($0.location) },
                perform: { save($0) }),
            ExplorerCommand(
                id: "search.coverage", title: "Why Might Results Be Missing?",
                placements: [.mainMenu("Edit", .tools, 30)],
                isEnabled: { isSearch($0.location) },
                perform: { showCoverage($0) }),
        ])
    }

    // MARK: Search options ▾ (Explorer §12.1)

    static func optionsMenu(_ ctx: CommandContext) -> [NSMenuItem] {
        guard case .search(let request)? = ctx.location,
              let controller = ExplorerSearchController.controller(for: ctx.window) else { return [] }

        func apply(_ new: SearchRequest) { controller.open(new) }
        func setQuery(_ query: String) {
            var new = request
            new.query = query
            ctx.window?.searchBox.text = query
            SearchHistoryStore.update { $0.record(query, refining: true) }
            apply(new)
        }
        func activeValue(_ property: SearchProperty) -> String? {
            guard let text = AQSQueryEditor.restrictions(property, in: request.query).last,
                  let colon = text.firstIndex(of: ":") else { return nil }
            return text[text.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")).lowercased()
        }
        func toggle(_ property: SearchProperty, _ value: String) -> () -> Void {
            {
                let on = activeValue(property) == value.lowercased()
                    || (property == .kind && activeValue(property).flatMap(SearchKind.lookup) == SearchKind.lookup(value))
                setQuery(AQSQueryEditor.setting(property, to: on ? nil : value, in: request.query))
            }
        }

        var items: [NSMenuItem] = []
        if request.scope == nil {
            items += [disabled("Current folder", "Searching This Mac uses the Spotlight index; choose a folder to limit the scope."),
                      disabled("All subfolders", "Searching This Mac uses the Spotlight index; choose a folder to limit the scope."),
                      .separator()]
        } else {
            let current = ClosureMenuItem("Current folder") { var n = request; n.recursive = false; apply(n) }
            current.state = request.recursive ? .off : .on
            current.toolTip = "Search only the items directly in “\(scopeName(request))”"
            let all = ClosureMenuItem("All subfolders") { var n = request; n.recursive = true; apply(n) }
            all.state = request.recursive ? .on : .off
            all.toolTip = "Search “\(scopeName(request))” and every folder inside it"
            items += [current, all, .separator()]
        }

        // Date modified ▸
        let dateActive = activeValue(.dateModified)
        items.append(submenu("Date modified", AQSParser.dateKeywords.map { entry in
            let item = ClosureMenuItem(entry.title, handler: toggle(.dateModified, entry.keyword))
            item.state = dateActive == entry.keyword ? .on : .off
            return item
        }))

        // Kind ▸ — Explorer's list; Windows-only kinds are shown disabled with the reason (DEC-019).
        let kindActive = activeValue(.kind).flatMap(SearchKind.lookup)
        let kinds: [(String, String?)] = [
            ("Calendar", "calendar"), ("Communication", "communication"), ("Contact", "contact"), ("Document", "document"),
            ("E-mail", "email"), ("Feed", nil), ("Folder", "folder"), ("Game", nil), ("Instant Message", nil),
            ("Journal", nil), ("Link", "link"), ("Movie", "movie"), ("Music", "music"), ("Note", nil),
            ("Picture", "picture"), ("Playlist", "playlist"), ("Program", "program"), ("Recorded TV", nil),
            ("Saved search", "savedsearch"), ("Task", nil), ("Video", "video"), ("Web history", nil), ("Unknown", "unknown"),
        ]
        items.append(submenu("Kind", kinds.map { title, keyword in
            guard let keyword else { return disabled(title, "“\(title)” is a Windows kind with no macOS equivalent.") }
            let item = ClosureMenuItem(title, handler: toggle(.kind, keyword))
            item.state = kindActive != nil && kindActive == SearchKind.lookup(keyword) ? .on : .off
            return item
        }))

        // Size ▸
        let sizeActive = activeValue(.size)
        items.append(submenu("Size", AQSParser.sizeNames.map { entry in
            let item = ClosureMenuItem(entry.title, handler: toggle(.size, entry.name))
            item.state = sizeActive == entry.name ? .on : .off
            return item
        }))

        // Other properties ▸ — inserts the property into the box, like Explorer.
        items.append(submenu("Other properties", [("Type", "type:"), ("Name", "name:"), ("Folder path", "folderpath:"), ("Tags", "tags:")].map { title, text in
            ClosureMenuItem(title) { controller.insertIntoBox(text) }
        }))

        // Advanced options ▸
        func optionItem(_ title: String, _ option: SearchOptions, _ tip: String) -> NSMenuItem {
            if request.scope == nil, option != .contents {
                return disabled(title, "Only for folder searches: searching This Mac uses the Spotlight index.")
            }
            let item = ClosureMenuItem(title) {
                var n = request
                if n.options.contains(option) { n.options.remove(option) } else { n.options.insert(option) }
                apply(n)
            }
            item.state = request.options.contains(option) ? .on : .off
            item.toolTip = tip
            return item
        }
        let indexed = ClosureMenuItem("Change indexed locations…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension") { SystemOpen.open(url) }
        }
        indexed.toolTip = "Opens System Settings ▸ Spotlight, where macOS decides what's indexed."
        items.append(submenu("Advanced options", [
            indexed, .separator(),
            optionItem("File contents", .contents, "Also match words inside files: text files directly, other documents through the Spotlight index."),
            optionItem("System files", .systemFiles, "Include hidden items and the contents of apps and other packages."),
            optionItem("Zipped (compressed) folders", .zipped, "Look inside .zip archives; a match shows the archive."),
        ]))

        items.append(.separator())
        items.append(ClosureMenuItem("Why might results be missing?") { showCoverage(ctx) })
        items.append(ClosureMenuItem("Save search") { save(ctx) })
        return items
    }

    /// A greyed-out entry with the reason in its tooltip (no action, so menus never enable it).
    private static func disabled(_ title: String, _ reason: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = reason
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    static func scopeName(_ request: SearchRequest) -> String {
        request.scope.map { Location.folder($0).displayName } ?? "This Mac"
    }

    // MARK: Coverage (FE-144)

    static func showCoverage(_ ctx: CommandContext) {
        guard let location = ctx.location, let session = SearchProvider.session(for: location) else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = session.coverage.isComplete ? "This search covered everything in its location."
                                                        : "Why might some results be missing?"
        alert.informativeText = coverageText(session)
        alert.addButton(withTitle: "OK")
        AlertSheets.present(alert, in: ctx.window?.window)
    }

    static func coverageText(_ session: SearchSession) -> String {
        var lines = ["Searched: “\(scopeName(session.request))”" + (session.request.recursive ? " and its subfolders." : " only (not subfolders).")]
        lines.append("Status: \(session.coverage.statusLine).")
        lines.append("")
        lines += session.coverage.details
        return lines.joined(separator: "\n")
    }

    // MARK: Saved searches (FE-138)

    static let savedSearchType = UTType(filenameExtension: SavedSearch.fileExtension) ?? .json

    static func save(_ ctx: CommandContext) {
        guard case .search(let request)? = ctx.location, let host = ctx.window?.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SavedSearch.suggestedFileName(for: request.query)
        panel.allowedContentTypes = [savedSearchType]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.message = "Save this search. Opening the file in Arbor runs it again."
        panel.beginSheetModal(for: host) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(request, to: url)
                ctx.window?.statusBar.setMessage("Search saved as “\(url.lastPathComponent)”.")
            } catch {
                NSAlert.show("Couldn't save the search.", error.localizedDescription, in: host)
            }
        }
    }

    static func write(_ request: SearchRequest, to url: URL) throws {
        let uuid = request.scope.flatMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
        let bookmark = request.scope.flatMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        try SavedSearch(request: request, volumeUUID: uuid, bookmark: bookmark).encoded().write(to: url, options: .atomic)
    }

    /// The search a saved file describes. The scope is found by bookmark first (it follows moves), then by
    /// path, and a path on a different disk than the one saved is not used.
    static func location(forSavedSearch url: URL) throws -> Location {
        let saved = try SavedSearch.decode(Data(contentsOf: url))
        var scope: URL?
        if let bookmark = saved.scopeBookmark {
            var stale = false
            scope = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if scope == nil, let path = saved.scopePath {
            let candidate = URL(fileURLWithPath: path)
            let uuid = try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            if saved.scopeVolumeUUID == nil || uuid == nil || uuid == saved.scopeVolumeUUID { scope = candidate }
            else { scope = candidate.appendingPathComponent(".arbor-missing-volume") }   // shows as unavailable, never another disk
        }
        return .search(saved.request(resolvedScope: scope))
    }
}
