import AppKit
import ArborCore

/// "Choose Details" (header right-click → More…, Sort ▾ → More…): a searchable checklist of every
/// column with Move Up / Move Down / Show / Hide and the selected column's width, like Explorer (FE-035).
final class ChooseDetailsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                                     NSTextFieldDelegate {
    struct Entry: Equatable {
        let id: ColumnID
        var visible: Bool
        var width: Double
    }

    /// The open dialog (scripts drive it).
    private(set) static weak var current: ChooseDetailsController?

    private(set) var entries: [Entry]
    private var shown: [Int] = []          // indexes into entries matching the search
    private let completion: (ColumnSet) -> Void
    private let list = NSTableView()
    private let search = NSSearchField()
    private let widthField = NSTextField()
    private let upButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let downButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let showButton = NSButton(title: "Show", target: nil, action: nil)
    private let hideButton = NSButton(title: "Hide", target: nil, action: nil)

    static func present(on window: NSWindow, columns: ColumnSet, completion: @escaping (ColumnSet) -> Void) {
        guard window.attachedSheet == nil else { return }
        let controller = ChooseDetailsController(columns: columns, completion: completion)
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Choose Details"
        sheet.styleMask = [.titled]
        current = controller
        window.beginSheet(sheet)
    }

    init(columns: ColumnSet, completion: @escaping (ColumnSet) -> Void) {
        self.completion = completion
        var list = columns.columns.map { Entry(id: $0.id, visible: true, width: $0.width) }
        let rest = ColumnCatalog.all.filter { !columns.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        list += rest.map { Entry(id: $0.id, visible: false, width: $0.width) }
        entries = list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 470))
        let intro = NSTextField(wrappingLabelWithString: "Select the details you want to display for the files in this folder.")
        let detailsLabel = NSTextField(labelWithString: "Details:")
        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        column.width = 260
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 22
        list.style = .plain
        list.dataSource = self
        list.delegate = self
        list.setAccessibilityLabel("Details")
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [(upButton, #selector(moveEntryUp)), (downButton, #selector(moveEntryDown)),
                                 (showButton, #selector(showSelected)), (hideButton, #selector(hideSelected))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let side = NSStackView(views: [upButton, downButton, showButton, hideButton])
        side.orientation = .vertical
        side.alignment = .width
        side.spacing = 8

        let widthLabel = NSTextField(labelWithString: "Width of selected column (in pixels):")
        widthField.formatter = { let f = NumberFormatter(); f.allowsFloats = false; f.minimum = 20; f.maximum = 2000; return f }()
        widthField.delegate = self
        widthField.target = self
        widthField.action = #selector(widthChanged(_:))
        widthField.setAccessibilityLabel("Width of selected column in pixels")

        let ok = NSButton(title: "OK", target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"

        for v in [intro, detailsLabel, search, scroll, side, widthLabel, widthField, ok, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            detailsLabel.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            detailsLabel.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            search.topAnchor.constraint(equalTo: detailsLabel.bottomAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 260),
            side.topAnchor.constraint(equalTo: scroll.topAnchor),
            side.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
            side.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            side.widthAnchor.constraint(equalToConstant: 100),
            widthLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            widthLabel.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            widthField.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            widthField.leadingAnchor.constraint(equalTo: widthLabel.trailingAnchor, constant: 8),
            widthField.widthAnchor.constraint(equalToConstant: 60),
            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.widthAnchor.constraint(equalToConstant: 88),
            ok.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            ok.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
            ok.widthAnchor.constraint(equalTo: cancel.widthAnchor),
            ok.topAnchor.constraint(greaterThanOrEqualTo: widthField.bottomAnchor, constant: 16),
        ])
        view = root
        applySearch()
    }

    // MARK: List

    private func applySearch() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let keep = selectedEntry.map { entries[$0].id }
        shown = entries.indices.filter { i in
            guard !q.isEmpty, let d = ColumnCatalog.descriptor(entries[i].id) else { return true }
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return d.title.range(of: q, options: opts) != nil || d.keywords.contains { $0.range(of: q, options: opts) != nil }
        }
        list.reloadData()
        if let keep, let row = shown.firstIndex(where: { entries[$0].id == keep }) {
            list.selectRowIndexes([row], byExtendingSelection: false)
        } else if !shown.isEmpty {
            list.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateControls()
    }

    private var selectedEntry: Int? {
        let row = list.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[shown[row]]
        let box = NSButton(checkboxWithTitle: ColumnCatalog.title(entry.id), target: self, action: #selector(checkboxToggled(_:)))
        box.state = entry.visible ? .on : .off
        box.isEnabled = entry.id != .name
        box.tag = shown[row]
        return box
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    private func updateControls() {
        guard let i = selectedEntry else {
            [upButton, downButton, showButton, hideButton, widthField].forEach { $0.isEnabled = false }
            widthField.stringValue = ""
            return
        }
        let entry = entries[i]
        let movable = entry.id != .name
        upButton.isEnabled = movable && i > 1
        downButton.isEnabled = movable && i + 1 < entries.count
        showButton.isEnabled = !entry.visible
        hideButton.isEnabled = entry.visible && movable
        widthField.isEnabled = true
        widthField.integerValue = Int(entry.width.rounded())
    }

    // MARK: Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard sender.tag < entries.count, entries[sender.tag].id != .name else { return }
        entries[sender.tag].visible = sender.state == .on
        if let row = shown.firstIndex(of: sender.tag) { list.selectRowIndexes([row], byExtendingSelection: false) }
        updateControls()
    }

    @objc func moveEntryUp() { move(by: -1) }
    @objc func moveEntryDown() { move(by: 1) }

    private func move(by step: Int) {
        guard let i = selectedEntry, entries[i].id != .name else { return }
        let j = i + step
        guard j >= 1, j < entries.count else { return }
        entries.swapAt(i, j)
        let id = entries[j].id
        applySearch()
        if let row = shown.firstIndex(where: { entries[$0].id == id }) { list.selectRowIndexes([row], byExtendingSelection: false) }
        updateControls()
    }

    @objc func showSelected() { setSelectedVisible(true) }
    @objc func hideSelected() { setSelectedVisible(false) }

    private func setSelectedVisible(_ visible: Bool) {
        guard let i = selectedEntry, entries[i].id != .name else { return }
        entries[i].visible = visible
        let row = list.selectedRow
        list.reloadData(forRowIndexes: [row], columnIndexes: [0])
        updateControls()
    }

    @objc private func widthChanged(_ sender: Any?) {
        guard let i = selectedEntry, widthField.integerValue >= 20 else { return }
        entries[i].width = Double(widthField.integerValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { applySearch() } else { widthChanged(nil) }
    }

    @objc private func searchChanged(_ sender: Any?) { applySearch() }

    @objc func confirm() {
        widthChanged(nil)
        let set = ColumnSet(entries.filter(\.visible).map { ColumnSpec($0.id, width: $0.width) })
        close()
        completion(set)
    }

    @objc func cancelSheet() { close() }

    private func close() {
        guard let sheet = view.window else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
    }

    // MARK: Scripts

    func scriptSearch(_ text: String) { search.stringValue = text; applySearch() }
    func scriptSelect(_ title: String) {
        if let row = shown.firstIndex(where: { ColumnCatalog.title(entries[$0].id) == title }) {
            list.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
    func scriptWidth(_ width: Int) { widthField.integerValue = width; widthChanged(nil) }
    var debugText: String {
        let visible = entries.filter(\.visible).map { "\(ColumnCatalog.title($0.id))=\(Int($0.width))" }.joined(separator: ", ")
        let list = shown.map { (entries[$0].visible ? "[x] " : "[ ] ") + ColumnCatalog.title(entries[$0].id) }.joined(separator: " | ")
        return "choose details: shown \(visible)\n  list: \(list)\n  selected: \(selectedEntry.map { ColumnCatalog.title(entries[$0].id) } ?? "-")"
    }
}
