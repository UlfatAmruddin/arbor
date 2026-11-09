import AppKit
import ArborCore

final class FileTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    var middleClick: ((Int) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// Group header clicks (collapse, select the group). Return true if handled.
    var rowMouseDown: ((Int, NSEvent) -> Bool)?
    /// Group header context menu; nil for item rows.
    var rowMenuProvider: ((Int) -> NSMenu?)?
    /// Outlives the press: the single-click open runs after tracking and must see that this press was a band.
    var pressBecameMarquee = false

    /// Type-to-select through the input method (FE-068).
    var typeSelect: ListTypeSelect?
    /// Focus moved apart from the selection (⌥⌘↑/↓, DEC-accessibility-3); nil follows the selection.
    var focusRow: Int? {
        didSet {
            guard focusRow != oldValue else { return }
            for row in [oldValue, focusRow].compactMap({ $0 }) where row < numberOfRows { rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true }
        }
    }

    override func keyDown(with event: NSEvent) {
        if typeSelect?.handleWhileComposing(event) == true { return }
        if keyHandler?(event) == true { return }
        if typeSelect?.handle(event) == true { return }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        typeSelect?.reset()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        focusRow = nil
        pressBecameMarquee = false
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, rowMouseDown?(row, event) == true { return }
        if InteractionHooks.leftMouseDown.handle((self, event)) { return }
        super.mouseDown(with: event)
    }

    /// Right-clicking an unselected item selects it first (spec §7.1).
    override func menu(for event: NSEvent) -> NSMenu? {
        takeFocusForContextMenu()
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let menu = rowMenuProvider?(row) { return menu }
        // Changing the selection would end the rename and leave the menu on the wrong item.
        if isEditingTextInside, row < 0 || !selectedRowIndexes.contains(row) { return nil }
        if row >= 0 {
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            deselectAll(nil)
        }
        return menuProvider?()
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0 { middleClick?(row) } else { super.otherMouseDown(with: event) }
    }

    /// A feature may start a right-button drag here (FE-106); otherwise the context menu opens.
    override func rightMouseDown(with event: NSEvent) {
        if InteractionHooks.rightMouseDown.handle((self, event)) { return }
        super.rightMouseDown(with: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        InteractionHooks.dragHover.send((nil, nil))
        super.draggingExited(sender)
    }
}

final class RenameField: NSTextField {
    var onBecomeFirstResponder: ((RenameField) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?(self) }
        return ok
    }
}

final class NameCellView: NSTableCellView {
    let icon = NSImageView()
    let nameField = RenameField()
    /// Lazy: most rows never show one, and it costs half a new cell.
    private(set) lazy var checkbox: NSButton = {
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.controlSize = .small
        box.isHidden = true
        box.setAccessibilityLabel(L10n.tr("Select"))
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        hasCheckbox = true
        return box
    }()
    private var hasCheckbox = false
    private var iconLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("NameCell")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = false
        nameField.focusRingType = .none
        nameField.font = Theme.bodyFont
        nameField.textColor = Theme.primaryText
        nameField.lineBreakMode = .byTruncatingMiddle   // keeps the extension visible (FE-055)
        nameField.cell?.usesSingleLineMode = true
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(nameField)
        imageView = icon
        textField = nameField
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DetailsNameShape.iconLeading)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: DetailsNameShape.iconSize),
            icon.heightAnchor.constraint(equalToConstant: DetailsNameShape.iconSize),
            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DetailsNameShape.iconTextGap),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DetailsNameShape.textTrailing),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCheckboxVisible(_ visible: Bool) {
        if visible || hasCheckbox { checkbox.isHidden = !visible }
        iconLeading.constant = visible ? DetailsNameShape.iconLeadingWithCheckbox : DetailsNameShape.iconLeading
    }
}

final class TextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(id: String, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("TextCell-\(id)")
        label.alignment = alignment
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Explorer-style Details view (FE-028, FE-035, FE-037). The window sorts and filters; this only displays.
final class DetailsViewController: NSViewController, ItemViewController, NSTableViewDataSource, NSTableViewDelegate,
                                   NSTextFieldDelegate, NSMenuDelegate {
    weak var itemDelegate: ItemViewDelegate?
    var viewMode: ViewMode = .details
    func canDisplay(_ mode: ViewMode) -> Bool { mode == .details }

    let table = FileTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private(set) var folder: URL?
    private(set) var items: [FileItem] = []
    private var allowsEditing = true
    private var syncingSort = false
    private var renamingItem: FileItem?
    private var renameCancelled = false
    private var pendingRenameText: String?
    /// Tab (+1) / Shift-Tab (-1) ended the rename: continue with the next/previous item (FE-064).
    private var renameStep = 0
    private var deferredUpdate: ItemViewUpdate?
    /// A band is being dragged: row indexes must stay valid until mouse-up (FE-058).
    var isTrackingMarquee = false
    /// `restoreSelectionEnds` is re-applying an unchanged selection one step at a time.
    var isRestoringSelectionEnds = false

    // Grouping (FE-038) and columns (FE-035, FE-036) live in DetailsViewController+Depth.swift.
    enum Row: Equatable { case header(Int), item(Int) }
    var rows: [Row] = []
    /// Groups shown (empty when not grouped).
    var groups: [ItemGroup] = []
    /// Table row of each item index (nil while its group is collapsed).
    var itemRows: [Int?] = []
    /// Index in `items` of each group's first item.
    var groupStarts: [Int] = []
    var applyingColumns = false
    var visibleLoadScheduled = false
    var arrivedNames = Set<String>()
    var headerOverlay: HeaderOverlayView?
    lazy var visibleOwner = "visible-\(UUID().uuidString)"

    var sortOrder = FileSortOrder() {
        didSet { if sortOrder != oldValue || table.sortDescriptors.isEmpty { syncSortIndicator() } }
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f
    }()

    override func loadView() {
        let container = ThemeBackgroundView(Theme.contentBackground)

        addColumn("name", L10n.tr("Name"), width: 340, min: 140, key: .name)
        addColumn("dateModified", L10n.tr("Date modified"), width: 160, min: 90, key: .dateModified)
        addColumn("type", L10n.tr("Type"), width: 150, min: 70, key: .type)
        addColumn("size", "Size", width: 90, min: 55, key: .size)   // header text left like Explorer; values right-aligned

        // Stock header on purpose: on macOS 26 a custom header view/cell stops rows drawing (scroll edge effect).
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = Theme.contentBackground
        table.rowHeight = Theme.rowHeight(compact: Prefs.compactView)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        // ViewOptions saves columns per folder kind (FE-040), not table autosave.
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL] + ItemHooks.dropTypes)
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        table.setAccessibilityLabel(L10n.tr("Files"))
        table.headerView?.menu = columnMenu()

        table.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        table.typeSelect = makeTypeSelect()
        table.middleClick = { [weak self] row in
            guard let self, let item = self.item(atRow: row), item.isFolder else { return }
            self.itemDelegate?.itemViewOpen([item], inNewTab: true)
        }
        table.menuProvider = { [weak self] in self?.itemDelegate?.itemViewContextMenu() }
        table.rowMouseDown = { [weak self] row, event in self?.groupHeaderMouseDown(row: row, event: event) ?? false }
        table.rowMenuProvider = { [weak self] row in self?.groupHeaderMenu(row: row) }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.contentBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.font = Theme.bodyFont
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        // Long messages (search errors) wrap.
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.preferredMaxLayoutWidth = 520

        container.addSubview(scroll)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 64),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = container
        installHeaderOverlay()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        syncSortIndicator()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ColumnValueStore.shared.cancel(owner: visibleOwner)
    }

    private func addColumn(_ id: String, _ title: String, width: CGFloat, min: CGFloat, key: SortKey, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.headerCell.alignment = alignment
        column.headerCell.attributedStringValue = NSAttributedString(string: L10n.tr(title), attributes: [
            .font: Theme.headerFont, .foregroundColor: Theme.secondaryText,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = alignment; p.lineBreakMode = .byTruncatingTail; return p }(),
        ])
        column.width = width
        column.minWidth = min
        column.maxWidth = 2000
        // No sortDescriptorPrototype, so no Mac sort triangle; the header overlay draws Explorer's chevron.
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(column)
    }

    var focusView: NSView { table }

    // MARK: Column chooser (right-click the header)

    private func columnMenu() -> NSMenu {
        let menu = NSMenu(title: "Columns")
        menu.allowsContextMenuPlugIns = false
        menu.delegate = self
        return menu
    }

    /// Right-click on a header: Size column to fit · Size all columns to fit · common columns · More…
    func menuNeedsUpdate(_ menu: NSMenu) {
        buildHeaderMenu(menu)
    }

    func sizeToFit() { sizeColumnsToFit(nil) }

    @objc func sizeColumnsToFit(_ sender: Any?) {
        for index in table.tableColumns.indices where !table.tableColumns[index].isHidden { sizeColumnToFit(index) }
    }

    /// Fits one column to its header and the visible rows (group headers don't count).
    func sizeColumnToFit(_ index: Int) {
        guard index >= 0, index < table.tableColumns.count else { return }
        let column = table.tableColumns[index]
        var width = column.headerCell.cellSize.width + 24
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) where item(atRow: row) != nil {
            if let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView,
               let field = cell.textField {
                width = max(width, field.intrinsicContentSize.width + (cell is NameCellView ? 40 : 20))
            }
        }
        column.width = min(max(width, column.minWidth), 800)
    }

    // MARK: Showing items

    private var holdsUpdates: Bool { renamingItem != nil || isTrackingMarquee }

    /// Replaces the rows, keeping selection and scroll on refresh; waits during a rename (spec §8.1) or a band.
    func display(_ update: ItemViewUpdate) {
        _ = view
        if holdsUpdates {
            holdUpdate(update)
            return
        }
        let keepSelection = update.locationChanged ? [] : selectedNames
        let keepURLs = update.locationChanged ? [] : Set(selectedItems.map(\.url))
        let keepTop = update.locationChanged ? nil : topVisibleName
        let keepEnds = update.locationChanged ? nil : currentSelectionEnds()
        folder = update.folder
        allowsEditing = update.allowsEditing
        if update.locationChanged { ColumnValueStore.shared.cancel(owner: visibleOwner) }
        DetailsColumns.apply(to: table, location: update.location)   // per-location extra columns (Trash, cloud, search)
        // A location's own layout wins over the tab's column set.
        if DetailsColumns.activeLayoutID(of: table) == nil { applyTabColumns() }
        let hadGroups = !groups.isEmpty
        if items.count >= 10_000 { BackgroundRelease.drop(items) }   // freed off the main thread
        items = regroup(update.items)
        rebuildRows()
        table.rowHeight = Theme.rowHeight(compact: Prefs.compactView)
        // Without group rows, keep cell views; reloadData() discards them (spec §15.3).
        if hadGroups || !groups.isEmpty { table.reloadData() } else { table.reloadKeepingViews() }
        headerOverlay?.needsDisplay = true
        if update.select == nil, !keepURLs.isEmpty {
            // Names can repeat in search results: keep the selection by URL.
            table.selectRowIndexes(IndexSet(items.indices.filter { keepURLs.contains(items[$0].url) }.compactMap { itemRows[$0] }),
                                   byExtendingSelection: false)
            restoreSelectionEnds(keepEnds)
        } else {
            select(names: update.select ?? keepSelection)
        }
        if let top = update.scrollTo ?? keepTop, let index = items.firstIndex(where: { $0.name == top }),
           let row = itemRows[index] {
            scrollRowToTop(row)
        } else if update.locationChanged {
            table.scrollRowToVisible(0)
        }
        if let first = table.selectedRowIndexes.first, update.scrollTo == nil, update.select != nil {
            table.scrollRowToVisible(first)
        }
        emptyLabel.stringValue = update.emptyText
        emptyLabel.isHidden = !items.isEmpty
    }

    /// Keeps the newest listing, but a pending folder change and where it wanted to land survive a later refresh.
    private func holdUpdate(_ update: ItemViewUpdate) {
        var newest = update
        if let held = deferredUpdate, held.locationChanged, !update.locationChanged {
            newest.locationChanged = true
            newest.select = newest.select ?? held.select
            newest.scrollTo = newest.scrollTo ?? held.scrollTo
        }
        deferredUpdate = newest
    }

    func applyDeferredUpdate() {
        guard let update = deferredUpdate else { return }
        deferredUpdate = nil
        display(update)
    }

    func reloadRows() {
        guard isViewLoaded else { return }
        table.rowHeight = Theme.rowHeight(compact: Prefs.compactView)
        let indexes = IndexSet(integersIn: 0..<rows.count)
        table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        table.noteHeightOfRows(withIndexesChanged: indexes)
    }

    /// Puts the row at the top edge, whatever the header and insets.
    func scrollRowToTop(_ row: Int) {
        guard !rows.isEmpty else { return }
        table.scrollRowToVisible(rows.count - 1)
        table.scrollRowToVisible(row)
    }

    // MARK: Selection

    var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { item(atRow: $0) }
    }

    /// The part of the table on screen below the column header.
    var rowsViewport: CGRect {
        var rect = table.visibleRect
        if let header = table.headerView, header.window != nil {
            let bottom = header.convert(NSPoint(x: 1, y: header.isFlipped ? header.bounds.maxY : header.bounds.minY), to: table)
            let hidden = min(max(bottom.y - rect.minY, 0), rect.height)
            rect.origin.y += hidden
            rect.size.height -= hidden
        }
        return rect
    }

    /// The first row whose top half is below the column header.
    var topVisibleName: String? {
        let row = table.row(at: NSPoint(x: 1, y: rowsViewport.minY + table.rowHeight / 2))
        guard row >= 0, row < rows.count else { return items.first?.name }
        // A group header at the top: the first item below it.
        return (row..<rows.count).lazy.compactMap { self.item(atRow: $0) }.first?.name
    }

    func select(names: [String]) {
        let wanted = Set(names)
        expandGroupsIfHidden(wanted)
        let selected = IndexSet(items.indices.filter { wanted.contains(items[$0].name) }.compactMap { itemRows[$0] })
        table.selectRowIndexes(selected, byExtendingSelection: false)
    }

    func select(urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let indexes = items.indices.filter { wanted.contains(items[$0].url.standardizedFileURL) }
        expandGroupsIfHidden(Set(indexes.map { items[$0].name }))
        table.selectRowIndexes(IndexSet(indexes.compactMap { itemRows[$0] }), byExtendingSelection: false)
    }

    func focus() { view.window?.makeFirstResponder(table) }

    var isEditingName: Bool { renamingItem != nil }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("ExplorerRow")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? ExplorerRowView ?? ExplorerRowView()
        view.identifier = id
        view.style = .content
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let header = groupHeaderView(row: row) { return header }
        guard let id = tableColumn?.identifier.rawValue, let item = item(atRow: row) else { return nil }
        let dimmed = item.isHidden || FileClipboard.shared.isCut(item.url)
        if let extra = DetailsColumns.cell(for: tableView, columnID: id, item: item) { extra.alphaValue = dimmed ? 0.5 : 1; return extra }
        if id == "name" {
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: nil) as? NameCellView ?? NameCellView()
            cell.nameField.stringValue = shownName(item)
            cell.nameField.font = Theme.listFont
            cell.nameField.toolTip = item.name
            cell.nameField.delegate = self
            cell.nameField.onBecomeFirstResponder = { [weak self] field in self?.renameFieldActivated(field) }
            cell.nameField.setAccessibilityLabel(item.name)
            cell.icon.image = IconProvider.shared.icon(for: item, size: 16)
            cell.setCheckboxVisible(Prefs.itemCheckBoxes)
            if Prefs.itemCheckBoxes {
                cell.checkbox.state = table.isRowSelected(row) ? .on : .off
                cell.checkbox.target = self
                cell.checkbox.action = #selector(checkboxClicked(_:))
            }
            cell.alphaValue = dimmed ? 0.5 : 1
            ItemViewHooks.decorateName.send((cell.nameField, item, row, tableView))
            return cell
        }
        let alignment: NSTextAlignment = id == "size" || ColumnCatalog.descriptor(ColumnID(id))?.alignRight == true ? .right : .left
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("TextCell-\(id)"), owner: nil) as? TextCellView
            ?? TextCellView(id: id, alignment: alignment)
        cell.label.font = Theme.listDetailFont
        switch id {
        case "dateModified": cell.label.stringValue = item.modified.map(dateFormatter.string(from:)) ?? ""
        case "type": cell.label.stringValue = item.typeDescription
        case "size": cell.label.stringValue = item.isFolder ? "" : item.size.map(ExplorerSize.detailsColumn) ?? ""
        default: fillMetadataCell(cell, item: item, column: ColumnID(id))
        }
        cell.alphaValue = dimmed ? 0.5 : 1
        return cell
    }

    /// Item check box: toggles that row in the selection.
    @objc private func checkboxClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0 else { return }
        if table.isRowSelected(row) { table.deselectRow(row) } else { table.selectRowIndexes([row], byExtendingSelection: true) }
    }

    func shownName(_ item: FileItem) -> String {
        guard !Prefs.showExtensions, !item.isFolder else { return item.name }
        let base = NameRules.splitExtension(item.name, treatAsFolder: false).base
        return base.isEmpty ? item.name : base
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == "name", let item = item(atRow: row) else { return nil }
        return item.name
    }

    /// Sorts by the column (again: reverses); the previous column becomes the tie-breaker (FE-235).
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let column = ColumnID(tableColumn.identifier.rawValue)
        var order = sortOrder
        if order.primaryColumn == column { order.ascending.toggle() } else { order.setPrimary(column, ascending: true) }
        sortOrder = order
        itemDelegate?.itemViewSortChanged(order)
    }

    /// The header overlay draws the sort, so the table keeps no sort descriptors.
    private func syncSortIndicator() {
        syncingSort = true
        if !table.sortDescriptors.isEmpty { table.sortDescriptors = [] }
        syncingSort = false
        hideNativeSortIndicators()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelectionEnds else { return }
        if Prefs.itemCheckBoxes, let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) {
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NameCellView)?.checkbox.state =
                    table.isRowSelected(row) ? .on : .off
            }
        }
        itemDelegate?.itemViewSelectionDidChange()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0, item(atRow: table.clickedRow) != nil else { return }
        itemDelegate?.itemViewOpen(selectedItems, inNewTab: false)
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if handleGroupHeaderKey(event) { return true }
        switch event.keyCode {
        case 36, 76:   // Return / Enter opens, like Explorer; the Mac preset takes them first (FileListKeys)
            guard !selectedItems.isEmpty, mods.isEmpty || mods == .command else { return false }
            itemDelegate?.itemViewOpen(selectedItems, inNewTab: mods == .command)
            return true
        default:
            return itemDelegate?.itemViewKey(event) ?? false
        }
    }

    // MARK: Rename

    func beginRenameSelection() {
        guard allowsEditing, let row = table.selectedRowIndexes.first, table.selectedRowIndexes.count == 1,
              item(atRow: row) != nil else { NSSound.beep(); return }
        beginRename(row: row, text: nil)
    }

    func beginRename(_ target: FileItem, text: String? = nil) {
        expandGroupsIfHidden([target.name])
        guard let index = items.firstIndex(where: { $0.url == target.url }), let row = itemRows[index] else { return }
        beginRename(row: row, text: text)
    }

    private func beginRename(row: Int, text: String?) {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, let item = item(atRow: row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView else { return }
        renamingItem = item
        renameCancelled = false
        pendingRenameText = text
        cell.nameField.isEditable = true
        cell.nameField.stringValue = text ?? item.name
        view.window?.makeFirstResponder(cell.nameField)
    }

    private func renameFieldActivated(_ field: RenameField) {
        guard let item = renamingItem else { return }
        DispatchQueue.main.async {
            guard let editor = field.currentEditor() else { return }
            if self.pendingRenameText != nil {
                editor.selectAll(nil)
            } else {
                editor.selectedRange = NameRules.basenameSelection(item.name, treatAsFolder: item.isFolder)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control is RenameField else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            view.window?.makeFirstResponder(table)
            return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            renameStep = selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
            view.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? RenameField, let item = renamingItem else { return }
        let typed = field.stringValue
        field.isEditable = false
        renamingItem = nil
        pendingRenameText = nil
        let cancelled = renameCancelled
        renameCancelled = false
        let step = renameStep
        renameStep = 0
        let nextItem = step == 0 || cancelled ? nil : items.firstIndex(of: item).map { $0 + step }
            .flatMap { items.indices.contains($0) ? items[$0] : nil }

        if cancelled || typed == item.name {
            field.stringValue = shownName(item)
        } else if itemDelegate?.itemViewRename(item, to: typed) == false {
            field.stringValue = shownName(item)
            DispatchQueue.main.async { [weak self] in self?.beginRename(item, text: typed) }
            return
        }
        if view.window?.firstResponder == nil || view.window?.firstResponder === view.window {
            view.window?.makeFirstResponder(table)
        }
        applyDeferredUpdate()
        if let nextItem {
            DispatchQueue.main.async { [weak self] in self?.beginRename(nextItem) }
        }
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        item(atRow: row).map { ItemHooks.dragWriter(for: $0) ?? $0.url as NSURL }   // archive members: file promises
    }

    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, let target = item(atRow: row), target.isFolder { return target.url }
        return folder
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let target = dropOperation == .on ? item(atRow: row) : nil
        let onFolder = target?.isFolder == true
        if !onFolder { tableView.setDropRow(-1, dropOperation: .on) }
        if let op = ItemHooks.dropOperation(info, destination: onFolder ? target?.url : folder) { return op }   // file promises
        let kind = (onFolder ? target?.url : folder).flatMap {
            DropPolicy.kind(sources: DropPolicy.fileURLs(from: info), destination: $0, mask: info.draggingSourceOperationMask)
        }
        let springItem = onFolder && kind != nil ? target : nil   // spring-loaded folders (FE-108)
        InteractionHooks.dragHover.send((springItem?.url.path, springItem.map { item in
            { [weak self] in self?.itemDelegate?.itemViewOpen([item], inNewTab: false) }
        }))
        guard let kind else { return [] }
        return kind == .move ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        InteractionHooks.dragHover.send((nil, nil))
        if ItemHooks.acceptDrop(info, destination: dropDestination(row: row, operation: dropOperation), window: view.window) { return true }
        let urls = DropPolicy.fileURLs(from: info)
        guard let dest = dropDestination(row: row, operation: dropOperation),
              let kind = DropPolicy.kind(sources: urls, destination: dest, mask: info.draggingSourceOperationMask) else { return false }
        itemDelegate?.itemViewTransfer(kind, urls, to: dest)
        return true
    }
}
