import AppKit
import ArborCore

protocol HomeFileListDelegate: AnyObject {
    func fileListOpen(_ list: HomeFileList, rows: [Int], inNewTab: Bool)
    func fileListSelectionChanged(_ list: HomeFileList)
    func fileListMenu(_ list: HomeFileList) -> NSMenu?
    func fileList(_ list: HomeFileList, unhandledKey event: NSEvent) -> Bool
    func fileList(_ list: HomeFileList, leaveToward direction: Int) -> Bool
}

/// A scroll view that never scrolls itself: it hands wheel events to the page around it, so a
/// table with a real header can sit inside the scrolling Home page.
final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

final class HomeTableView: NSTableView, SectionTagged {
    var sectionID = ""
    weak var owner: HomeFileList?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            deselectAll(nil)
        }
        return owner.flatMap { $0.delegate?.fileListMenu($0) }
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0, let owner { owner.delegate?.fileListOpen(owner, rows: [row], inNewTab: true) }
        else { super.otherMouseDown(with: event) }
    }
}

/// Favorites and Recent: a list with Name, a date column and File location (Explorer's Home lists).
/// It sizes itself to its rows; the page scrolls.
final class HomeFileList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: HomeFileListDelegate?
    let table = HomeTableView()
    private let scroll = PassThroughScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private(set) var rows: [HomeRow] = []
    private var sortKey: String?
    private var sortAscending = true

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    init(sectionID: String, dateTitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        table.sectionID = sectionID
        table.owner = self
        addColumn("name", "Name", width: 320, min: 140)
        addColumn("date", dateTitle, width: 170, min: 90)
        addColumn("location", "File location", width: 320, min: 100)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = Theme.contentBackground
        table.rowHeight = Theme.rowHeight(compact: Prefs.compactView)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setAccessibilityLabel(sectionID == "recent" ? "Recent files" : "Favorites")

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.contentBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        heightConstraint = heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            heightConstraint,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addColumn(_ id: String, _ title: String, width: CGFloat, min: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        // Stock header cells, styled through the attributed title (custom header classes stop
        // rows drawing on macOS 26).
        column.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: Theme.headerFont, .foregroundColor: Theme.secondaryText,
        ])
        column.width = width
        column.minWidth = min
        column.maxWidth = 2000
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "date")
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(column)
    }

    func setRows(_ newRows: [HomeRow]) {
        let keep = Set(selectedItems.map(\.url))
        rows = sorted(newRows)
        table.rowHeight = Theme.rowHeight(compact: Prefs.compactView)
        table.reloadData()
        let again = IndexSet(rows.indices.filter { keep.contains(rows[$0].item.url) })
        table.selectRowIndexes(again, byExtendingSelection: false)
        let header = table.headerView?.frame.height ?? 28
        heightConstraint.constant = header + CGFloat(rows.count) * table.rowHeight + 2
    }

    private func sorted(_ list: [HomeRow]) -> [HomeRow] {
        guard let key = sortKey else { return list }
        let ascending = sortAscending
        return list.sorted { a, b in
            let result: ComparisonResult
            switch key {
            case "date": result = (a.date ?? .distantPast).compare(b.date ?? .distantPast)
            case "location": result = a.location.localizedStandardCompare(b.location)
            default: result = a.item.name.localizedStandardCompare(b.item.name)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: Selection

    var selectedRows: [Int] { Array(table.selectedRowIndexes).filter { $0 < rows.count } }
    var selectedItems: [FileItem] { selectedRows.map { rows[$0].item } }

    func select(names: [String]) {
        let wanted = Set(names)
        table.selectRowIndexes(IndexSet(rows.indices.filter { wanted.contains(rows[$0].item.name) }), byExtendingSelection: false)
    }

    func clearSelection() {
        if !table.selectedRowIndexes.isEmpty { table.deselectAll(nil) }
    }

    func focusFirstRow(last: Bool = false) {
        guard !rows.isEmpty else { return }
        if table.selectedRowIndexes.isEmpty { table.selectRowIndexes([last ? rows.count - 1 : 0], byExtendingSelection: false) }
        window?.makeFirstResponder(table)
    }

    // MARK: Keys

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch event.keyCode {
        case 36, 76:
            guard !selectedRows.isEmpty, mods.isEmpty || mods == .command else { return false }
            delegate?.fileListOpen(self, rows: selectedRows, inNewTab: mods == .command)
            return true
        case 126 where mods.isEmpty && table.selectedRowIndexes.first == 0:
            return delegate?.fileList(self, leaveToward: -1) ?? false
        case 125 where mods.isEmpty && table.selectedRowIndexes.last == rows.count - 1:
            return delegate?.fileList(self, leaveToward: 1) ?? false
        case 123, 124, 125, 126, 115, 119, 116, 121:
            return false
        default:
            return delegate?.fileList(self, unhandledKey: event) ?? false
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        delegate?.fileListOpen(self, rows: selectedRows, inNewTab: false)
    }

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
        guard let id = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
        let entry = rows[row]
        if id == "name" {
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: nil) as? NameCellView ?? NameCellView()
            cell.nameField.stringValue = shownName(entry.item)
            cell.nameField.toolTip = entry.item.url.path
            cell.nameField.isEditable = false
            cell.nameField.setAccessibilityLabel(entry.item.name)
            cell.icon.image = IconProvider.shared.icon(for: entry.item, size: 16)
            cell.setCheckboxVisible(false)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("TextCell-\(id)"), owner: nil) as? TextCellView
            ?? TextCellView(id: id, alignment: .left)
        switch id {
        case "date": cell.label.stringValue = entry.date.map(dateFormatter.string(from:)) ?? ""
        case "location":
            cell.label.stringValue = entry.location
            cell.label.toolTip = entry.item.url.deletingLastPathComponent().path
            cell.label.lineBreakMode = .byTruncatingHead
        default: cell.label.stringValue = ""
        }
        return cell
    }

    private func shownName(_ item: FileItem) -> String {
        guard !Prefs.showExtensions, !item.isFolder else { return item.name }
        let base = NameRules.splitExtension(item.name, treatAsFolder: false).base
        return base.isEmpty ? item.name : base
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "name" && row < rows.count ? rows[row].item.name : nil
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first else { return }
        sortKey = d.key
        sortAscending = d.ascending
        setRows(rows)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { delegate?.fileListSelectionChanged(self) }

    /// Drag out: the real file (FE-239: Home rows are the items themselves, not copies).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < rows.count ? rows[row].item.url as NSURL : nil
    }
}
