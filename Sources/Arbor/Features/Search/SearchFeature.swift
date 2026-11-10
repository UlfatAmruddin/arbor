import AppKit
import ArborCore

/// Explorer-style search (spec §10, FE-131–FE-146, FE-236, FE-237). See docs/features/search.md.
enum SearchFeature: ExplorerFeature {
    static let id = "search"
    static func register() {
        LocationRegistry.register(SearchProvider())
        SearchRegistry.factory.provide("search.explorer") { window in ExplorerSearchController(window: window) }
        SearchColumns.register()
        SearchCommands.register()
        // Layouts without columns show where a result lives.
        InteractionHooks.itemDetail.register("search.result-folder") { item, location in
            guard case .search? = location else { return nil }
            return (L10n.tr("Folder:"), SearchColumns.folderText(item, location))
        }

        // Opening a saved .arborsearch file reruns its search (FE-138).
        LocationRegistry.registerOpenHandler("search.saved-search") { item in
            guard item.url.pathExtension.lowercased() == SavedSearch.fileExtension else { return nil }
            return try? SearchCommands.location(forSavedSearch: item.url)
        }

        // Refresh reruns a search instead of re-showing cached results.
        CommandRegistry.shared.beforePerform("nav.refresh", "search.rerun-on-refresh") { ctx in
            if case .search(let request)? = ctx.location { SearchSessions.restart(request, showHidden: Prefs.showHidden) }
        }

        NotificationCenter.default.addObserver(forName: HomeStore.historyCleared, object: nil, queue: .main) { _ in
            SearchHistoryStore.update { $0.clear() }
        }

        registerDebugSteps()
    }

    // MARK: Scripted checks (TESTING.md)

    private static func registerDebugSteps() {
        DebugScript.registerLogger("search.log") { window in
            let shown = window.activeTab.displayedLocation ?? window.location
            var lines = ["search box: “\(window.searchBox.text)”"]
            if let session = SearchProvider.session(for: shown) {
                lines.append("search: query=“\(session.request.query)” scope=\(session.request.scope?.path ?? "This Mac") recursive=\(session.request.recursive) options=\(session.request.options.rawValue) results=\(session.count) status=\(session.coverage.statusLine)")
            }
            lines.append("details columns: " + ((window.itemView as? DetailsViewController)?.table.tableColumns.map(\.title).joined(separator: " | ") ?? "-"))
            if let controller = ExplorerSearchController.controller(for: window) {
                lines.append("search \(controller.debugDropdown) progress: \(controller.debugProgress)")
            }
            lines.append("search history: " + SearchHistoryStore.history.entries.joined(separator: " | "))
            lines.append("search back: " + (window.activeTab.history.backStack.map(\.location.key).joined(separator: " , ")))
            return lines.joined(separator: "\n")
        }

        // searchopt:Date modified/Today — chooses an entry in Search options ▾.
        DebugScript.registerStep("searchopt") { path, window in
            guard let window else { return nil }
            let items = SearchCommands.optionsMenu(window.context(surface: .commandBar, sender: nil))
            let menu = NSMenu()
            items.forEach(menu.addItem)
            var current: NSMenu? = menu
            let parts = path.components(separatedBy: "/")
            for (i, title) in parts.enumerated() {
                guard let m = current, let index = m.items.firstIndex(where: { $0.title == title }) else {
                    NSLog("DebugScript: no search option \(path)"); return nil
                }
                if i == parts.count - 1 { m.performActionForItem(at: index) } else { current = m.items[index].submenu }
            }
            return 1.0
        }

        // searchmenu:/out.txt — Search options ▾ with checks, disabled states, tooltips.
        DebugScript.registerStep("searchmenu") { path, window in
            guard let window else { return nil }
            let items = SearchCommands.optionsMenu(window.context(surface: .commandBar, sender: nil))
            func dump(_ items: [NSMenuItem], _ indent: String) -> [String] {
                items.flatMap { item -> [String] in
                    if item.isSeparatorItem { return [indent + "---"] }
                    var line = indent + item.title
                    if item.state == .on { line += " ✓" }
                    if !item.isEnabled || (item.action == nil && item.submenu == nil) { line += " (disabled: \(item.toolTip ?? ""))" }
                    return [line] + dump(item.submenu?.items ?? [], indent + "    ")
                }
            }
            append(("search options:\n" + dump(items, "").joined(separator: "\n")) + "\n---\n", to: path)
            return 0.3
        }

        // searchrows:/out.txt — rows with the Folder and Match columns.
        DebugScript.registerStep("searchrows") { path, window in
            guard let window else { return nil }
            let shown = window.activeTab.displayedLocation ?? window.location
            let rows = window.visibleItems.map { item in
                "\(item.name) | \(item.url.deletingLastPathComponent().lastPathComponent) | \(SearchColumns.reasonText(item, shown))"
            }
            append("search rows (\(rows.count)):\n" + rows.joined(separator: "\n") + "\n---\n", to: path)
            return 0.3
        }

        // searchdetails:/out.txt — the coverage explanation (FE-144).
        DebugScript.registerStep("searchdetails") { path, window in
            guard let window, let session = SearchProvider.session(for: window.activeTab.displayedLocation ?? window.location) else { return nil }
            append("search details:\n" + SearchCommands.coverageText(session) + "\n---\n", to: path)
            return 0.3
        }

        // searchcoverageax:/out.txt — the open coverage dialog as VoiceOver sees it (FE-132).
        DebugScript.registerStep("searchcoverageax") { path, window in
            guard let sheet = window?.window?.attachedSheet else { return nil }
            append(AXDump.dump(sheet) + "---\n", to: path)
            return 0.3
        }

        DebugScript.registerStep("searchsave") { path, window in
            guard let window, case .search(let request) = window.activeTab.displayedLocation ?? window.location else { return nil }
            do { try SearchCommands.write(request, to: URL(fileURLWithPath: path)) } catch { NSLog("DebugScript: save failed \(error)") }
            return 0.3
        }

        // searchopenfile:/path/x.arborsearch — opens a saved search as if double-clicked.
        DebugScript.registerStep("searchopenfile") { path, window in
            guard let window, let item = FileItem(url: URL(fileURLWithPath: path)) else { return nil }
            window.open([item], inNewTab: false)
            return 1.0
        }

        DebugScript.registerStep("searchclose") { _, window in
            ExplorerSearchController.controller(for: window)?.closeSearch()
            return 1.0
        }

        DebugScript.registerStep("searchfocus") { _, window in
            window?.focusSearch()
            return 0.6
        }

        // dropdownsnap:/out.png — renders the recent-searches dropdown.
        DebugScript.registerStep("dropdownsnap") { path, window in
            ExplorerSearchController.controller(for: window)?.dropdownPanel.writeSnapshot(to: path) == true ? 0.3 : nil
        }
    }

    private static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
