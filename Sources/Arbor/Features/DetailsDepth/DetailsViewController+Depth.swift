import AppKit
import ArborCore

/// Group headers (FE-038), column sets and lazily loaded metadata columns (FE-035, FE-036, FE-040),
/// and the column header overlay with filters (FE-039) for the Details view.
extension DetailsViewController {
    // MARK: Host tab

    /// The tab this view shows (the window's active tab).
    var hostTab: TabState? {
        guard let window = itemDelegate as? BrowserWindowController, !window.tabs.isEmpty else { return nil }
        return window.activeTab
    }

    var hostOptions: TabViewOptions? { hostTab.map(ViewOptions.options(for:)) }

    // MARK: Rows

    func item(atRow row: Int) -> FileItem? {
        guard row >= 0, row < rows.count, case .item(let i) = rows[row], i < items.count else { return nil }
        return items[i]
    }

    func headerIndex(atRow row: Int) -> Int? {
        guard row >= 0, row < rows.count, case .header(let g) = rows[row] else { return nil }
        return g
    }

    func headerRow(of group: Int) -> Int? { rows.firstIndex(of: .header(group)) }

    func groupIndex(ofItem index: Int) -> Int? {
        guard !groups.isEmpty else { return nil }
        return groupStarts.lastIndex { $0 <= index }
    }

    /// Splits sorted items into the tab's groups and returns them in display order.
    func regroup(_ sorted: [FileItem]) -> [FileItem] {
        if let o = hostOptions, let by = o.groupBy {
            groups = FileGrouper.group(sorted, by: by, ascending: o.groupAscending, lookup: DetailsDepth.lookup)
        } else {
            groups = []
        }
        var start = 0
        groupStarts = groups.map { g in defer { start += g.items.count }; return start }
        return groups.isEmpty ? sorted : groups.flatMap(\.items)
    }

    /// Rebuilds the row list from `items`, `groups` and the collapsed set.
    func rebuildRows() {
        itemRows = Array(repeating: nil, count: items.count)
        rows = []
        rows.reserveCapacity(items.count + groups.count)
        if groups.isEmpty {
            for i in items.indices { itemRows[i] = i; rows.append(.item(i)) }
            return
        }
        let collapsed = hostOptions?.collapsed ?? []
        var index = 0
        for (g, group) in groups.enumerated() {
            rows.append(.header(g))
            let hidden = collapsed.contains(group.bucket.id)
            for _ in group.items {
                if !hidden { itemRows[index] = rows.count; rows.append(.item(index)) }
                index += 1
            }
        }
    }

    // MARK: Group headers

    func groupHeaderView(row: Int) -> NSView? {
        guard let g = headerIndex(atRow: row), g < groups.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("GroupHeader")
        let cell = table.makeView(withIdentifier: id, owner: nil) as? GroupHeaderCellView ?? GroupHeaderCellView()
        cell.identifier = id
        let group = groups[g]
        cell.configure(title: group.bucket.title, count: group.items.count,
                       collapsed: hostOptions?.collapsed.contains(group.bucket.id) ?? false)
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { headerIndex(atRow: row) != nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if headerIndex(atRow: row) != nil { return Theme.listRowHeight(Prefs.compactView ? 30 : 36) }
        return Theme.rowHeight(compact: Prefs.compactView)
    }

    /// A header can be focused on its own (keyboard), never as part of a multiple selection.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.count > 1, !groups.isEmpty else { return proposed }
        return proposed.filteredIndexSet { item(atRow: $0) != nil }
    }

    /// A new grouping starts at the first group (the old top item may now be anywhere).
    func scrollToTop() {
        if !rows.isEmpty { scrollRowToTop(0) }
    }

    func isCollapsed(_ group: Int) -> Bool {
        group < groups.count && (hostOptions?.collapsed.contains(groups[group].bucket.id) ?? false)
    }

    /// Collapses or expands a group; the header keeps keyboard focus when its items disappear.
    func setGroup(_ group: Int, collapsed: Bool) {
        guard group < groups.count, let o = hostOptions else { return }
        let id = groups[group].bucket.id
        guard o.collapsed.contains(id) != collapsed else { return }
        if collapsed { o.collapsed.insert(id) } else { o.collapsed.remove(id) }
        relayoutRows(focusHeader: collapsed ? group : nil)
    }

    func setAllGroups(collapsed: Bool) {
        guard let o = hostOptions, !groups.isEmpty else { return }
        o.collapsed = collapsed ? Set(groups.map(\.bucket.id)) : []
        relayoutRows(focusHeader: nil)
    }

    private func relayoutRows(focusHeader: Int?) {
        let keep = Set(selectedItems.map(\.url))   // by URL: names repeat in search results
        let wasHeader = table.selectedRowIndexes.count == 1 ? headerIndex(atRow: table.selectedRowIndexes.first!) : nil
        rebuildRows()
        table.reloadData()
        var selection = IndexSet(items.indices.filter { keep.contains(items[$0].url) }.compactMap { itemRows[$0] })
        if selection.isEmpty, let g = focusHeader ?? wasHeader, let row = headerRow(of: g) { selection = [row] }
        table.selectRowIndexes(selection, byExtendingSelection: false)
        itemDelegate?.itemViewSelectionDidChange()
    }

    /// Expands the groups of `names` when none of them is visible (Select All, new items, rename).
    func expandGroupsIfHidden(_ names: Set<String>) {
        guard !groups.isEmpty, !names.isEmpty, let o = hostOptions, !o.collapsed.isEmpty else { return }
        let indices = items.indices.filter { names.contains(items[$0].name) }
        guard !indices.isEmpty, indices.allSatisfy({ itemRows[$0] == nil }) else { return }
        for i in indices { if let g = groupIndex(ofItem: i) { o.collapsed.remove(groups[g].bucket.id) } }
        rebuildRows()
        table.reloadData()
    }

    /// Selects the group's visible items (clicking a header, like Explorer).
    func selectGroup(_ group: Int, extending: Bool = false) {
        guard group < groups.count else { return }
        let start = groupStarts[group]
        var selection = IndexSet((start..<(start + groups[group].items.count)).compactMap { itemRows[$0] })
        if selection.isEmpty, let row = headerRow(of: group) { selection = [row] }
        table.selectRowIndexes(selection, byExtendingSelection: extending)
    }

    func groupHeaderMouseDown(row: Int, event: NSEvent) -> Bool {
        guard let g = headerIndex(atRow: row) else { return false }
        let point = table.convert(event.locationInWindow, from: nil)
        let onChevron = point.x - table.rect(ofRow: row).minX < GroupHeaderCellView.chevronWidth
        if onChevron || event.clickCount == 2 {
            setGroup(g, collapsed: !isCollapsed(g))
        } else {
            selectGroup(g, extending: event.modifierFlags.contains(.command))
        }
        view.window?.makeFirstResponder(table)
        return true
    }

    func groupHeaderMenu(row: Int) -> NSMenu? {
        guard let g = headerIndex(atRow: row) else { return nil }
        let menu = NSMenu(title: "Group")
        let collapsed = isCollapsed(g)
        menu.addItem(ClosureMenuItem(collapsed ? L10n.tr("Expand Group") : L10n.tr("Collapse Group")) { [weak self] in
            self?.setGroup(g, collapsed: !collapsed)
        })
        menu.addItem(ClosureMenuItem(L10n.tr("Collapse All Groups")) { [weak self] in self?.setAllGroups(collapsed: true) })
        menu.addItem(ClosureMenuItem(L10n.tr("Expand All Groups")) { [weak self] in self?.setAllGroups(collapsed: false) })
        return menu
    }

    /// With a header focused: Left collapses, Right expands, Return/Space toggles (reference §6.2).
    func handleGroupHeaderKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard mods.isEmpty, table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first,
              let g = headerIndex(atRow: row) else { return false }
        switch event.keyCode {
        case 123: setGroup(g, collapsed: true)
        case 124: setGroup(g, collapsed: false)
        case 36, 76, 49: setGroup(g, collapsed: !isCollapsed(g))
        default: return false
        }
        return true
    }

    // MARK: Columns

    /// Shows the tab's column set (FE-040): adds, removes, orders and sizes table columns.
    func applyTabColumns() {
        guard let o = hostOptions else { return }
        let wanted = o.columns
        let current = table.tableColumns.map { ColumnSpec(ColumnID($0.identifier.rawValue), width: Double($0.width)) }
        let same = current.count == wanted.columns.count
            && zip(current, wanted.columns).allSatisfy { $0.id == $1.id && abs($0.width - $1.width) < 1 }
        if same { return }
        applyingColumns = true
        defer { applyingColumns = false }
        for column in table.tableColumns where !wanted.contains(ColumnID(column.identifier.rawValue)) {
            table.removeTableColumn(column)
        }
        for (index, spec) in wanted.columns.enumerated() {
            let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(spec.id.rawValue)) ?? makeColumn(spec.id)
            column.isHidden = false
            if abs(Double(column.width) - spec.width) >= 1 { column.width = CGFloat(spec.width) }
            let from = table.column(withIdentifier: column.identifier)
            if from >= 0, from != index { table.moveColumn(from, toColumn: index) }
        }
        // Filters on columns that are no longer shown would be invisible: drop them.
        for column in o.filters.columns where !wanted.contains(column) { o.filters.clear(column) }
        hideNativeSortIndicators()
        headerOverlay?.needsDisplay = true
    }

    @discardableResult
    func makeColumn(_ id: ColumnID) -> NSTableColumn {
        let d = ColumnCatalog.descriptor(id)
        let title = d?.title ?? id.rawValue
        let alignment: NSTextAlignment = .left   // Explorer headers are left-aligned; numeric values align right in cells
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.headerCell.alignment = alignment
        column.headerCell.attributedStringValue = NSAttributedString(string: L10n.tr(title), attributes: [
            .font: Theme.headerFont, .foregroundColor: Theme.secondaryText,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = alignment; p.lineBreakMode = .byTruncatingTail; return p }(),
        ])
        column.width = CGFloat(d?.width ?? 120)
        column.minWidth = CGFloat(d?.minWidth ?? 50)
        column.maxWidth = 2000
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(column)
        return column
    }

    /// Replaces the tab's columns, saves them for the folder kind, and redraws.
    func setColumns(_ set: ColumnSet) {
        guard let o = hostOptions else { return }
        var set = set
        set.groupBy = o.columns.groupBy
        set.groupAscending = o.columns.groupAscending
        set.normalize()
        // Showing, hiding or reordering a column keeps the selected items selected (spec T06).
        let keep = selectedItems.map(\.url)
        o.columns = set
        ViewOptions.saveEditedColumns(o)
        applyTabColumns()
        table.reloadData()
        if !keep.isEmpty, selectedItems.isEmpty { select(urls: keep) }
        scheduleVisibleLoad()
        if let tab = hostTab { DetailsDepth.refresh(tab) }
    }

    func setColumnVisible(_ id: ColumnID, _ visible: Bool) {
        guard var set = hostOptions?.columns else { return }
        set.setVisible(id, visible)
        setColumns(set)
    }

    var shownColumnIDs: [ColumnID] { table.tableColumns.filter { !$0.isHidden }.map { ColumnID($0.identifier.rawValue) } }

    func tableViewColumnDidMove(_ notification: Notification) { columnsEditedByUser() }
    func tableViewColumnDidResize(_ notification: Notification) {
        // Only the user's own drags count; the Name column also resizes with the window.
        guard (table.headerView?.resizedColumn ?? -1) >= 0 else { headerOverlay?.needsDisplay = true; return }
        columnsEditedByUser()
    }

    /// Name stays first, like Explorer's always-present Name column.
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        let name = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        return columnIndex != name && newColumnIndex != name
    }

    private func columnsEditedByUser() {
        headerOverlay?.needsDisplay = true
        guard !applyingColumns, let o = hostOptions else { return }
        // Per-location layouts (Trash, search results) aren't saved into the folder-kind column set.
        guard DetailsColumns.activeLayoutID(of: table) == nil else { return }
        var set = o.columns
        set.columns = table.tableColumns.filter { !$0.isHidden }.map { ColumnSpec(ColumnID($0.identifier.rawValue), width: Double($0.width)) }
        set.normalize()
        guard set != o.columns else { return }
        o.columns = set
        DetailsDepth.saveLater(o)
    }

    // MARK: Metadata cells

    func fillMetadataCell(_ cell: TextCellView, item: FileItem, column: ColumnID) {
        let value = ColumnValues.value(item, column, lookup: DetailsDepth.lookup)
        cell.label.stringValue = ColumnValues.text(value, column: column)
        cell.label.textColor = value == nil || value == .unknown ? Theme.disabledText : Theme.secondaryText
        let state = ColumnValues.stateDescription(value)
        cell.toolTip = state
        cell.label.setAccessibilityLabel(state.map { "\(ColumnCatalog.title(column)): \($0)" })
        if value == nil { scheduleVisibleLoad() }
    }

    /// Loads metadata for the visible rows (plus a small margin), cancelling stale requests.
    func scheduleVisibleLoad() {
        guard !visibleLoadScheduled else { return }
        visibleLoadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.visibleLoadScheduled = false
            self?.loadVisibleMetadata()
        }
    }

    private func loadVisibleMetadata() {
        let columns = Set(shownColumnIDs.filter(ColumnCatalog.needsLoading))
        guard !columns.isEmpty, !rows.isEmpty, view.window != nil else { return }
        let range = table.rows(in: table.visibleRect)
        let low = max(0, range.location - 10), high = min(rows.count, range.location + max(range.length, 30) + 20)
        guard low < high else { return }
        let visible = (low..<high).compactMap { item(atRow: $0) }
        let store = ColumnValueStore.shared
        store.cancel(owner: visibleOwner)
        store.request(visible, columns: columns, owner: visibleOwner, batchSize: 8) { [weak self] items in
            self?.metadataArrived(items)
        }
    }

    @objc func scrolled(_ note: Notification) { scheduleVisibleLoad() }

    private func metadataArrived(_ arrived: [FileItem]) {
        let wasEmpty = arrivedNames.isEmpty
        arrivedNames.formUnion(arrived.map(\.name))
        guard wasEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let names = self.arrivedNames
            self.arrivedNames = []
            let rowIndexes = IndexSet(self.rows.indices.filter { self.item(atRow: $0).map { names.contains($0.name) } ?? false })
            let columnIndexes = IndexSet(self.table.tableColumns.indices.filter {
                ColumnCatalog.needsLoading(ColumnID(self.table.tableColumns[$0].identifier.rawValue))
            })
            guard !rowIndexes.isEmpty, !columnIndexes.isEmpty else { return }
            self.table.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        }
    }

    // MARK: Header: overlay, sort indicator, menu

    func installHeaderOverlay() {
        guard let header = table.headerView, headerOverlay == nil else { return }
        let overlay = HeaderOverlayView(frame: header.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.table = table
        overlay.isFilterable = { [weak self] i in self?.columnID(at: i) != nil }
        overlay.isFiltered = { [weak self] i in
            guard let self, let id = self.columnID(at: i) else { return false }
            return self.hostOptions?.filters.isFiltered(id) ?? false
        }
        overlay.sortState = { [weak self] i in
            guard let self, let id = self.columnID(at: i), self.sortOrder.primaryColumn == id else { return nil }
            return self.sortOrder.ascending
        }
        overlay.onDropdown = { [weak self] i in self?.showFilter(column: i) }
        header.addSubview(overlay)
        headerOverlay = overlay
    }

    func columnID(at index: Int) -> ColumnID? {
        guard index >= 0, index < table.tableColumns.count else { return nil }
        return ColumnID(table.tableColumns[index].identifier.rawValue)
    }

    /// Explorer draws a small chevron above the title; the overlay does, so the Mac triangle is removed.
    func hideNativeSortIndicators() {
        for column in table.tableColumns where table.indicatorImage(in: column) != nil { table.setIndicatorImage(nil, in: column) }
        table.highlightedTableColumn = nil
        headerOverlay?.needsDisplay = true
    }

    /// The header column under the mouse (for "Size column to fit").
    private var headerColumnUnderMouse: Int {
        guard let header = table.headerView, let window = header.window else { return -1 }
        return header.column(at: header.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func buildHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = headerColumnUnderMouse
        let fitOne = ClosureMenuItem(L10n.tr("Size Column to Fit")) { [weak self] in self?.sizeColumnToFit(clicked) }
        fitOne.isEnabled = clicked >= 0
        menu.autoenablesItems = false
        menu.addItem(fitOne)
        menu.addItem(ClosureMenuItem(L10n.tr("Size All Columns to Fit")) { [weak self] in self?.sizeColumnsToFit(nil) })
        menu.addItem(.separator())
        let shown = Set(shownColumnIDs)
        for d in ColumnCatalog.all where d.isCommon {
            let visible = shown.contains(d.id)
            let item = ClosureMenuItem(d.title) { [weak self] in self?.setColumnVisible(d.id, !visible) }
            item.state = visible ? .on : .off
            item.isEnabled = d.id != .name
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let o = hostOptions, !o.filters.isEmpty {
            menu.addItem(ClosureMenuItem(L10n.tr("Clear Filters")) { [weak self] in self.map { DetailsDepth.clearFilters($0.hostTab) } })
        }
        menu.addItem(ClosureMenuItem(L10n.tr("More…")) { [weak self] in self?.presentChooseDetails() })
    }

    func presentChooseDetails() {
        guard let window = view.window, let set = hostOptions?.columns else { return }
        ChooseDetailsController.present(on: window, columns: set) { [weak self] newSet in self?.setColumns(newSet) }
    }

    // MARK: Header filters

    /// Opens the column's filter dropdown: a checklist of its buckets (FE-039).
    func showFilter(column index: Int) {
        guard let id = columnID(at: index), let tab = hostTab, let overlay = headerOverlay else { return }
        let controller = ColumnFilterViewController(column: id)
        controller.optionsProvider = { [weak tab] in
            guard let tab else { return ([], []) }
            let o = ViewOptions.options(for: tab)
            return (ColumnFilters.options(for: id, items: tab.items ?? [], lookup: DetailsDepth.lookup), o.filters.selected(id))
        }
        controller.onToggle = { [weak self, weak tab] bucket in
            guard let tab else { return }
            ViewOptions.options(for: tab).filters.toggle(id, bucket: bucket)
            DetailsDepth.refresh(tab)
            self?.headerOverlay?.needsDisplay = true
        }
        if ColumnCatalog.needsLoading(id), let all = tab.items {
            ColumnValueStore.shared.request(all, columns: [id], owner: DetailsDepth.allValuesOwner(tab)) { [weak controller] _ in
                controller?.reloadSoon()
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: overlay.dropdownRect(index), of: overlay, preferredEdge: .maxY)
        activeFilterPopover = popover
    }
}
