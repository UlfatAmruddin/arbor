import AppKit
import ArborCore

/// Extra large / Large / Medium / Small icons, List, Tiles and Content (FE-029–FE-031). One instance
/// switches between the seven layouts in place, so selection and scroll position survive ⇧⌘1…⇧⌘8.
/// Sorting and filtering happen in the window; this view only displays and reports, exactly like
/// `DetailsViewController`.
final class IconViewController: NSViewController, ItemViewController, ItemGridHost, NSTextFieldDelegate {
    static let modes: [ViewMode] = [.extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons, .list, .tiles, .content]

    weak var itemDelegate: ItemViewDelegate?
    var viewMode: ViewMode = .largeIcons {
        didSet {
            guard viewMode != oldValue, isViewLoaded else { return }
            applyScrollerAxes()
            grid.configure(mode: viewMode, keepTop: true)
        }
    }
    func canDisplay(_ mode: ViewMode) -> Bool { Self.modes.contains(mode) }

    var sortOrder = FileSortOrder()

    let grid = ItemGridView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private(set) var folder: URL?
    private var allowsEditing = true
    private var observers: [NSObjectProtocol] = []

    // Rename state (mirrors DetailsViewController).
    private var renameField: RenameField?
    private var renamingItem: FileItem?
    private var renameCancelled = false
    private var pendingRenameText: String?
    private var deferredUpdate: ItemViewUpdate?
    /// Tab (+1) or Shift-Tab (-1) ended the rename: continue with the next/previous item (FE-064).
    private var renameStep = 0

    override func loadView() {
        let container = ThemeBackgroundView(Theme.contentBackground)
        grid.host = self
        scroll.documentView = grid
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.contentBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true

        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.font = Theme.bodyFont
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 64),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = container

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.grid.visibleAreaChanged()
        })
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.grid.viewportChanged()
            self?.repositionRenameField()
        })
        observers.append(nc.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?["key"] as? String) == Prefs.alwaysShowIconsKey { self?.reloadRows() }
        })
        applyScrollerAxes()
        grid.configure(mode: viewMode, keepTop: false)
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// List scrolls sideways (column flow); the other layouts scroll down.
    private func applyScrollerAxes() {
        let horizontal = viewMode == .list
        scroll.hasHorizontalScroller = horizontal
        scroll.hasVerticalScroller = !horizontal
    }

    var focusView: NSView { grid }
    func focus() { view.window?.makeFirstResponder(grid) }

    // MARK: Showing items

    /// Replaces the items. Keeps selection and scroll position on refresh, waits while renaming so
    /// typed text isn't lost (spec §8.1), and drops thumbnails work when the folder changes.
    func display(_ update: ItemViewUpdate) {
        _ = view
        if renamingItem != nil {
            deferredUpdate = update
            return
        }
        view.superview?.layoutSubtreeIfNeeded()
        let keepSelection = update.locationChanged ? [] : selectedNames
        let keepURLs = update.locationChanged ? [] : Set(selectedItems.map(\.url))
        let keepTop = update.locationChanged ? nil : topVisibleName
        let focusedName = update.locationChanged ? nil : grid.selection.focus.flatMap { $0 < items.count ? items[$0].name : nil }
        folder = update.folder
        allowsEditing = update.allowsEditing
        grid.location = update.location
        grid.setItems(update.items, locationChanged: update.locationChanged)
        if update.select == nil, !keepURLs.isEmpty {
            // Search results can hold several items with one name: keep the selection by URL.
            grid.setSelection(IndexSet(items.indices.filter { keepURLs.contains(items[$0].url) }), notify: true)
        } else {
            select(names: update.select ?? keepSelection, notify: true)
        }
        if update.select == nil, let focusedName, let i = items.firstIndex(where: { $0.name == focusedName }),
           grid.selection.selected.contains(i) || grid.selection.selected.isEmpty {
            grid.selection.focus = i
        }
        if let top = update.scrollTo ?? keepTop, let index = items.firstIndex(where: { $0.name == top }) {
            grid.scrollToStart(index)
        } else if update.locationChanged {
            grid.scrollToTop()
        }
        if let first = grid.selection.selected.first, update.scrollTo == nil, update.select != nil {
            grid.scrollItemToVisible(first)
        }
        emptyLabel.stringValue = update.emptyText
        emptyLabel.isHidden = !items.isEmpty
    }

    /// Compact view, check boxes, extensions or "Always show icons" changed: re-measure and redraw.
    func reloadRows() {
        guard isViewLoaded else { return }
        grid.configure(mode: viewMode, keepTop: true)
    }

    var items: [FileItem] { grid.items }
    var selectedItems: [FileItem] { grid.selectedItems }

    var topVisibleName: String? {
        guard let index = grid.firstVisibleIndex, index < items.count else { return items.first?.name }
        return items[index].name
    }

    func select(names: [String]) { select(names: names, notify: true) }

    func select(urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        grid.setSelection(IndexSet(items.indices.filter { wanted.contains(items[$0].url.standardizedFileURL) }), notify: true)
    }

    private func select(names: [String], notify: Bool) {
        let wanted = Set(names)
        let indexes = wanted.isEmpty ? IndexSet() : IndexSet(items.indices.filter { wanted.contains(items[$0].name) })
        grid.setSelection(indexes, notify: notify)
    }

    var isEditingName: Bool { renamingItem != nil }

    // MARK: ItemGridHost

    func gridOpen(_ items: [FileItem], inNewTab: Bool) {
        guard !items.isEmpty else { return }
        itemDelegate?.itemViewOpen(items, inNewTab: inNewTab)
    }

    func gridSelectionChanged() { itemDelegate?.itemViewSelectionDidChange() }
    func gridContextMenu() -> NSMenu? { itemDelegate?.itemViewContextMenu() }
    func gridTransfer(_ kind: TransferKind, _ urls: [URL], to folder: URL) { itemDelegate?.itemViewTransfer(kind, urls, to: folder) }
    func gridKey(_ event: NSEvent) -> Bool { itemDelegate?.itemViewKey(event) ?? false }
    func gridBeginRename(at index: Int) { beginRename(index: index, text: nil) }
    var gridFolder: URL? { folder }
    var gridAllowsEditing: Bool { allowsEditing }

    // MARK: Rename (F2 selects the base name, Enter commits, Esc cancels)

    func beginRenameSelection() {
        guard allowsEditing, grid.selection.selected.count == 1, let index = grid.selection.selected.first else { NSSound.beep(); return }
        beginRename(index: index, text: nil)
    }

    func beginRename(named name: String, text: String?) {
        guard let index = items.firstIndex(where: { $0.name == name }) else { return }
        beginRename(index: index, text: text)
    }

    private func beginRename(index: Int, text: String?) {
        guard allowsEditing, index < items.count else { return }
        endRenameField()
        grid.cancelSlowRename()
        grid.setSelection([index])
        grid.scrollItemToVisible(index)
        let item = items[index]
        let field = RenameField()
        let multiline = grid.metrics.style == .iconAbove
        field.font = grid.metrics.nameFont
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = Theme.fieldBackground
        // Win11's rename box: field background with a thin accent outline.
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 2
        field.layer?.borderColor = Theme.accent.resolved(for: view.effectiveAppearance).cgColor
        field.textColor = Theme.primaryText
        field.focusRingType = .none
        field.isEditable = true
        field.alignment = multiline ? .center : .left
        field.cell?.wraps = multiline
        field.cell?.isScrollable = !multiline
        field.cell?.usesSingleLineMode = !multiline
        field.lineBreakMode = multiline ? .byWordWrapping : .byClipping
        field.stringValue = text ?? item.name
        field.delegate = self
        field.setAccessibilityLabel(L10n.format("Rename %@", "\(item.name)"))
        field.onBecomeFirstResponder = { [weak self] field in self?.renameFieldActivated(field) }
        renameField = field
        renamingItem = item
        renameCancelled = false
        pendingRenameText = text
        grid.editingIndex = index
        grid.addSubview(field)
        repositionRenameField()
        view.window?.makeFirstResponder(field)
    }

    private func repositionRenameField() {
        guard let field = renameField, let item = renamingItem, let index = items.firstIndex(of: item) else { return }
        field.frame = grid.editorFrame(for: index, text: field.stringValue.isEmpty ? " " : field.stringValue)
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

    func controlTextDidChange(_ obj: Notification) { repositionRenameField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            view.window?.makeFirstResponder(grid)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(grid)
            return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            renameStep = selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
            view.window?.makeFirstResponder(grid)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? RenameField, field === renameField, let item = renamingItem else { return }
        let typed = field.stringValue
        renamingItem = nil
        pendingRenameText = nil
        let cancelled = renameCancelled
        renameCancelled = false
        let step = renameStep
        renameStep = 0
        let nextItem = step == 0 || cancelled ? nil : items.firstIndex(of: item).map { $0 + step }
            .flatMap { items.indices.contains($0) ? items[$0] : nil }
        endRenameField()

        if !(cancelled || typed == item.name), itemDelegate?.itemViewRename(item, to: typed) == false {
            DispatchQueue.main.async { [weak self] in self?.beginRename(named: item.name, text: typed) }
            return
        }
        if view.window?.firstResponder == nil || view.window?.firstResponder === view.window {
            view.window?.makeFirstResponder(grid)
        }
        if let update = deferredUpdate {
            deferredUpdate = nil
            display(update)
        }
        if let nextItem {
            DispatchQueue.main.async { [weak self] in self?.beginRename(named: nextItem.name, text: nil) }
        }
    }

    private func endRenameField() {
        renameField?.delegate = nil
        renameField?.removeFromSuperview()
        renameField = nil
        grid.editingIndex = nil
    }

    // MARK: Debug (scripted checks)

    var debugState: String {
        let m = grid.metrics
        let l = grid.layout
        let focus = grid.selection.focus.map { $0 < items.count ? items[$0].name : "\($0)" } ?? "-"
        let origin = scroll.contentView.bounds.origin
        return "iconview: mode=\(viewMode.rawValue) cell=\(Int(l.itemSize.width))x\(Int(l.itemSize.height)) icon=\(Int(m.iconSize)) "
            + "flow=\(l.flow == .rows ? "rows" : "columns") columns=\(l.columns) rows=\(l.rows) "
            + "content=\(Int(grid.frame.width))x\(Int(grid.frame.height)) scroll=\(Int(origin.x)),\(Int(origin.y)) "
            + "top=\(topVisibleName ?? "-") focus=\(focus) visible=\(grid.visibleIndexes.count) subviews=\(grid.subviews.count) "
            + "renaming=\(renamingItem?.name ?? "-") inflight=\(grid.thumbnails.inFlightCount)"
    }

    var scrollView: NSScrollView { scroll }
}
