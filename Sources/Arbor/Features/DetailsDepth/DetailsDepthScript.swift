import AppKit
import ArborCore

/// Script steps for headless checks of grouping, filters and columns (TESTING.md).
///
///     groupby:type | groupby:none | groupdir:desc        Group by ▸ (column id), direction
///     collapse:Today | expand:Today | groupclick:Today   toggle / select a group by title
///     key:126 | key:123                                   send a key (key code) to the file list
///     filter:size:Tiny (0 – 16 KB)                        toggle a header filter bucket by title
///     clearfilters                                        clear all filters
///     filtermenu:size:/path                               log a column's filter choices
///     filterdates:dateModified:2026-03-03[:2026-03-09]    pick days in the dropdown's calendar
///     filterfields:dateModified:2026-03-03:2026-03-09     type days into the dropdown's From and To
///     removefilter:size                                   remove one column's filter
///     addressfilters:/path                                log the address bar's Filtered menu
///     openfilter:size  /  snapshotpopover:/path.png       open the ▾ popover, draw it (click:filter.size is the menu route)
///     headerhover:size                                    show the hover ▾ on a header (snapshots)
///     columns:name,dateModified,dimensions                set the Details columns
///     showcolumn:tags | hidecolumn:type                   header checklist toggles
///     sortcol:dimensions[:desc]                           sort like clicking a header
///     headermenu:/path                                    log the header right-click menu
///     choosedetails | cdsearch:dur | cdselect:Length | cdwidth:120 | cdup | cddown | cdshow | cdhide
///     snapshotsheet:/path.png                             draw the attached sheet
extension DetailsDepth {
    static func registerDebugSteps() {
        func details(_ w: BrowserWindowController?) -> DetailsViewController? { w?.itemView as? DetailsViewController }
        func ctx(_ w: BrowserWindowController?) -> CommandContext? { w?.context(surface: .script, sender: nil) }
        func group(named title: String, in d: DetailsViewController) -> Int? {
            d.groups.firstIndex { $0.bucket.title == title }
        }

        DebugScript.registerStep("groupby") { arg, w in
            if let c = ctx(w) { setGroup(c, arg == "none" ? nil : ColumnID(arg)) }
            return 1.0
        }
        DebugScript.registerStep("groupdir") { arg, w in
            if let c = ctx(w) { setGroupAscending(c, arg != "desc") }
            return 0.8
        }
        DebugScript.registerStep("collapse") { arg, w in
            if let d = details(w), let g = group(named: arg, in: d) { d.setGroup(g, collapsed: true) }
            return 0.5
        }
        DebugScript.registerStep("expand") { arg, w in
            if let d = details(w), let g = group(named: arg, in: d) { d.setGroup(g, collapsed: false) }
            return 0.5
        }
        DebugScript.registerStep("groupclick") { arg, w in
            if let d = details(w), let g = group(named: arg, in: d) { d.selectGroup(g); d.focus() }
            return 0.5
        }
        // `key:` is handled in AccessibilityDebug.swift.
        DebugScript.registerStep("filter") { arg, w in
            guard let tab = w?.activeTab, let colon = arg.firstIndex(of: ":") else { return 0.5 }
            let column = ColumnID(String(arg[..<colon]))
            let title = String(arg[arg.index(after: colon)...])
            let choices = ColumnFilters.options(for: column, items: tab.items ?? [], lookup: lookup)
            if let bucket = choices.first(where: { $0.title == title }) {
                ViewOptions.options(for: tab).filters.toggle(column, bucket: bucket.id)
                refresh(tab)
                details(w)?.headerOverlay?.needsDisplay = true
            } else {
                NSLog("DetailsDepth: no filter choice %@ in %@", title, choices.map(\.title).description)
            }
            return 1.0
        }
        DebugScript.registerStep("clearfilters") { _, w in clearFilters(w?.activeTab); return 0.8 }
        DebugScript.registerStep("removefilter") { arg, w in clearFilters(w?.activeTab, column: ColumnID(arg)); return 0.8 }
        DebugScript.registerStep("filterdates") { arg, w in
            guard let (view, days) = dateFilterStep(arg, details(w)), let first = days.first, let last = days.last else { return 0.3 }
            let count = Calendar.autoupdatingCurrent.dateComponents([.day], from: first, to: last).day ?? 0
            view.scriptSelectInCalendar(from: first, days: count)
            return 1.0
        }
        DebugScript.registerStep("filterfields") { arg, w in
            guard let (view, days) = dateFilterStep(arg, details(w)), let first = days.first, let last = days.last else { return 0.3 }
            view.scriptSetFields(from: first, to: last)
            return 1.0
        }
        DebugScript.registerStep("addressfilters") { arg, w in
            guard let annotation = w?.addressBar.annotation else {
                append("address filters: none\n---\n", to: arg)
                return 0.3
            }
            let rows = annotation.menu().items.map { $0.isSeparatorItem ? "---" : $0.title }
            append("address filters: \(annotation.title)\ntooltip: \(annotation.tooltip)\n" + rows.joined(separator: "\n") + "\n---\n", to: arg)
            return 0.3
        }
        DebugScript.registerStep("filtermenu") { arg, w in
            guard let tab = w?.activeTab, let colon = arg.firstIndex(of: ":") else { return 0.3 }
            let column = ColumnID(String(arg[..<colon]))
            let path = String(arg[arg.index(after: colon)...])
            let checked = ViewOptions.options(for: tab).filters.selected(column)
            let lines = ColumnFilters.options(for: column, items: tab.items ?? [], lookup: lookup)
                .map { $0.title + (checked.contains($0.id) ? " ✓" : "") }
            append("filter \(column):\n  " + lines.joined(separator: "\n  ") + "\n---\n", to: path)
            return 0.3
        }
        DebugScript.registerStep("openfilter") { arg, w in
            if let d = details(w), let i = d.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == arg }) {
                d.showFilter(column: i)
            }
            return 1.0
        }
        DebugScript.registerStep("snapshotpopover") { arg, w in
            if let view = activeFilterPopover?.contentViewController?.view { snapshot(view, to: arg) }
            return 0.3
        }
        DebugScript.registerStep("headerhover") { arg, w in
            if let d = details(w) {
                d.headerOverlay?.hoverColumn = d.table.tableColumns.firstIndex { $0.identifier.rawValue == arg } ?? -1
            }
            return 0.3
        }
        DebugScript.registerStep("columns") { arg, w in
            details(w)?.setColumns(ColumnSet(ids: arg.split(separator: ",").map { ColumnID(String($0)) }))
            return 1.0
        }
        DebugScript.registerStep("showcolumn") { arg, w in details(w)?.setColumnVisible(ColumnID(arg), true); return 1.0 }
        DebugScript.registerStep("hidecolumn") { arg, w in details(w)?.setColumnVisible(ColumnID(arg), false); return 1.0 }
        DebugScript.registerStep("sortcol") { arg, w in
            guard let w else { return 0.5 }
            let parts = arg.split(separator: ":")
            var order = w.activeTab.sortOrder
            order.setPrimary(ColumnID(String(parts.first ?? "name")), ascending: parts.count < 2 || parts[1] != "desc")
            w.setSortOrder(order)
            return 1.0
        }
        DebugScript.registerStep("headermenu") { arg, w in
            guard let d = details(w) else { return 0.3 }
            let menu = NSMenu()
            d.buildHeaderMenu(menu)
            let lines = menu.items.map { item -> String in
                if item.isSeparatorItem { return "---" }
                return item.title + (item.state == .on ? " ✓" : "") + (item.isEnabled ? "" : " (disabled)")
            }
            append("header menu:\n" + lines.joined(separator: "\n") + "\n---\n", to: arg)
            return 0.3
        }
        DebugScript.registerStep("choosedetails") { _, w in details(w)?.presentChooseDetails(); return 1.0 }
        DebugScript.registerStep("cdsearch") { arg, _ in ChooseDetailsController.current?.scriptSearch(arg); return 0.4 }
        DebugScript.registerStep("cdselect") { arg, _ in ChooseDetailsController.current?.scriptSelect(arg); return 0.4 }
        DebugScript.registerStep("cdwidth") { arg, _ in ChooseDetailsController.current?.scriptWidth(Int(arg) ?? 100); return 0.4 }
        DebugScript.registerStep("cdup") { _, _ in ChooseDetailsController.current?.moveEntryUp(); return 0.4 }
        DebugScript.registerStep("cddown") { _, _ in ChooseDetailsController.current?.moveEntryDown(); return 0.4 }
        DebugScript.registerStep("cdshow") { _, _ in ChooseDetailsController.current?.showSelected(); return 0.4 }
        DebugScript.registerStep("cdhide") { _, _ in ChooseDetailsController.current?.hideSelected(); return 0.4 }
        DebugScript.registerStep("snapshotsheet") { arg, w in
            if let view = w?.window?.attachedSheet?.contentView?.superview { snapshot(view, to: arg) }
            return 0.3
        }

        DebugScript.registerLogger("details-depth.log") { w in
            guard !w.tabs.isEmpty, !w.activeTab.showsPage else { return "details: (page)" }
            let tab = w.activeTab
            let o = ViewOptions.options(for: tab)
            var lines: [String] = []
            let order = tab.sortOrder
            lines.append("details kind: \(o.kind.rawValue)  sort: \(order.primaryColumn)\(order.ascending ? "↑" : "↓")"
                         + (order.thenBy.isEmpty ? "" : " then " + order.thenBy.map { "\($0.column)\($0.ascending ? "↑" : "↓")" }.joined(separator: ","))
                         + "  group: \(o.groupBy?.rawValue ?? "none")\(o.groupAscending ? "↑" : "↓")")
            lines.append("filters: " + (o.filters.isEmpty ? "none"
                         : o.filters.columns.map { column in
                             let range = o.filters.dateRange(column).map { " range=\($0.title(calendar: .autoupdatingCurrent))" } ?? ""
                             return "\(column)=\(o.filters.selected(column).sorted())\(range)"
                         }.sorted().joined(separator: " ")))
            if let d = w.itemView as? DetailsViewController {
                lines.append("columns: " + d.table.tableColumns.map { "\($0.identifier.rawValue)(\(Int($0.width)))" }.joined(separator: " "))
                lines.append("filterable: " + d.table.tableColumns.indices.filter { d.headerOverlay?.isFilterable($0) == true }
                    .compactMap { d.columnID(at: $0)?.rawValue }.joined(separator: " "))
                if !d.groups.isEmpty {
                    lines.append("groups: " + d.groups.enumerated().map { i, g in
                        "\(g.bucket.title) (\(g.items.count))\(d.isCollapsed(i) ? " [collapsed]" : "")"
                    }.joined(separator: " | "))
                }
                lines.append("table rows: " + d.rows.map { row -> String in
                    switch row {
                    case .header(let g): return "[\(d.groups[g].bucket.title)]"
                    case .item(let i): return d.items[i].name
                    }
                }.joined(separator: " | "))
                let selectedRows = d.table.selectedRowIndexes.map { row -> String in
                    if let g = d.headerIndex(atRow: row) { return "[\(d.groups[g].bucket.title)]" }
                    return d.item(atRow: row)?.name ?? "?"
                }
                lines.append("focused rows: " + selectedRows.joined(separator: " | "))
                let meta = d.shownColumnIDs.filter(ColumnCatalog.needsLoading)
                if !meta.isEmpty {
                    for item in d.items.prefix(40) {
                        lines.append("  \(item.name): " + meta.map { col in
                            let v = ColumnValues.value(item, col, lookup: lookup)
                            let text = ColumnValues.text(v, column: col)
                            let state: String
                            switch v {
                            case nil: state = "loading"
                            case .unknown?: state = "unknown"
                            case .unsupported?: state = "unsupported"
                            case .empty?: state = "empty"
                            default: state = text
                            }
                            return "\(col)=\(state)"
                        }.joined(separator: " "))
                    }
                }
            }
            if activeFilterPopover?.isShown == true, let dropdown = activeFilterPopover?.contentViewController as? ColumnFilterViewController {
                lines.append(dropdown.debugSummary)
            }
            if let sheet = ChooseDetailsController.current, sheet.view.window?.isVisible == true || w.window?.attachedSheet != nil {
                lines.append(sheet.debugText)
            }
            return lines.joined(separator: "\n")
        }
    }


    /// Parses `<date column>:<yyyy-MM-dd>[:<yyyy-MM-dd>]` and opens that column's dropdown; bad input only logs.
    private static func dateFilterStep(_ arg: String, _ details: DetailsViewController?) -> (DateRangeFilterView, [Date])? {
        let parts = arg.split(separator: ":").map(String.init)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let details, (2...3).contains(parts.count), ColumnCatalog.descriptor(ColumnID(parts[0]))?.groupStyle == .date,
              let index = details.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == parts[0] }) else {
            NSLog("DetailsDepth: bad date filter step %@", arg)
            return nil
        }
        let days = parts.dropFirst().compactMap(formatter.date(from:))
        guard days.count == parts.count - 1 else {
            NSLog("DetailsDepth: bad dates in %@", arg)
            return nil
        }
        func open() -> ColumnFilterViewController? {
            guard activeFilterPopover?.isShown == true else { return nil }
            return (activeFilterPopover?.contentViewController as? ColumnFilterViewController).flatMap { $0.column.rawValue == parts[0] ? $0 : nil }
        }
        if open() == nil { details.showFilter(column: index) }
        guard let view = open()?.loadedDateView else { return nil }
        return (view, days)
    }

    private static func snapshot(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
