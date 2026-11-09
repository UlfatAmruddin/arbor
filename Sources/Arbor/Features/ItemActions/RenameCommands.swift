import AppKit
import ArborCore

/// Rename (F2) for one or more items, Tab sequencing in Details, and Batch rename (FE-064, FE-089, FE-103).
enum RenameCommands {
    /// A multi-item rename waiting for the user to commit the inline editor.
    struct Session {
        let items: [RenameCandidate]
        let edited: URL
    }

    private static var sessions: [ObjectIdentifier: Session] = [:]

    static func register() {
        let r = CommandRegistry.shared
        // Replaces the core command so it also works on several items (Explorer's numbered rename).
        r.replace(ExplorerCommand(
            id: "file.rename", title: "Rename", symbol: "character.cursor.ibeam", tooltip: "Rename",
            shortcut: .function(NSF2FunctionKey),
            keyBindings: [KeyBinding(120)],   // F2
            placements: [.commandBar(40), .itemContextMenu(.organize, 10), .mainMenu("Edit", .organize, 10)],
            isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
            isEnabled: { $0.hasSelection && $0.allowsEditing },
            perform: begin), "item-actions.multi-rename")
        r.register([
            ExplorerCommand(
                id: "file.batchRename", title: "Batch rename…", symbol: "pencil.and.list.clipboard",
                placements: [.itemContextMenu(.organize, 15), .seeMore(.selection, 40), .mainMenu("Edit", .organize, 15)],
                dynamicTitle: ItemActionsFeature.title(L10n.tr("Batch rename…"), mac: L10n.tr("Batch Rename…")),
                isAvailable: { $0.surface != .itemContextMenu || $0.selection.count > 1 },
                isEnabled: { $0.hasSelection && $0.allowsEditing },
                perform: { ctx in
                    guard let window = ctx.window else { return }
                    BatchRenameDialog.run(items: ordered(ctx.selection, in: window), window: window)
                }),
        ])
        InteractionHooks.commitRename.register("item-actions.multi-rename") { window, item, typed in commit(window, item, typed) }
    }

    /// The selection in view order (Explorer numbers items in the order they're shown).
    static func ordered(_ selection: [FileItem], in window: BrowserWindowController) -> [FileItem] {
        let wanted = Set(selection.map(\.url))
        let inView = window.visibleItems.filter { wanted.contains($0.url) }
        return inView.count == selection.count ? inView : selection
    }

    static func begin(_ ctx: CommandContext) {
        guard let window = ctx.window, let view = window.itemView else { return }
        let key = ObjectIdentifier(window)
        let items = ordered(ctx.selection, in: window)
        guard items.count > 1 else {
            sessions[key] = nil
            view.beginRenameSelection()
            return
        }
        sessions[key] = Session(items: items.map { RenameCandidate(url: $0.url, isFolder: $0.isFolder) }, edited: items[0].url)
        view.beginRename(items[0], text: nil)
        // Explorer keeps the whole batch selected while the first name is edited.
        if view.isEditingName { view.select(urls: items.map(\.url)) }
        window.statusBar.setMessage(L10n.format("Type a name for all %@ items. Each gets a number: “Name (1)”, “Name (2)”…", "\(items.count)"))
    }

    /// Commit hook: performs the multi-item rename for an active session, else lets the core rename.
    static func commit(_ window: BrowserWindowController, _ item: FileItem, _ typed: String) -> Bool? {
        let key = ObjectIdentifier(window)
        guard let session = sessions[key] else { return nil }
        guard session.edited == item.url else {
            sessions[key] = nil
            return nil
        }
        let base = MultiRename.base(fromTyped: typed, editedName: item.name, editedIsFolder: item.isFolder)
        if let problem = NameRules.validate(base) ?? (base.trimmingCharacters(in: .whitespaces).isEmpty ? .empty : nil) {
            NSAlert.show(L10n.tr("Couldn't rename these items."), problem.errorDescription ?? "", in: nil)
            return false
        }
        var members: [URL: Set<String>] = [:]
        for candidate in session.items { members[candidate.folder, default: []].insert(candidate.name.lowercased()) }
        let names = MultiRename.names(base: base, items: session.items) { name, folder in
            FileOps.exists(folder.appendingPathComponent(name)) && members[folder]?.contains(name.lowercased()) != true
        }
        do {
            let applied = try BatchRenamer.apply(Array(zip(session.items.map(\.url), names)).map { ($0.0, $0.1) })
            sessions[key] = nil
            registerUndo(applied)
            window.navigate(to: window.location, select: names)
            window.statusBar.setMessage(L10n.format("Renamed %@. Press ⌘Z to undo.", "\(StatusText.items(session.items.count))"))
            return true
        } catch {
            NSAlert.show(L10n.tr("Couldn't rename these items."), error.localizedDescription + "\n\n" + L10n.tr("Nothing was renamed."), in: nil)
            return false
        }
    }

    /// One undo step for the batch. Undo refuses rather than overwrite a file that took an old name since.
    static func registerUndo(_ applied: [(from: URL, to: URL)]) {
        guard !applied.isEmpty else { return }
        let center = OperationCenter.shared
        center.undoManager.registerUndo(withTarget: center) { center in
            do {
                let reverted = try BatchRenamer.apply(BatchRenamer.reversePlan(applied))
                registerUndo(reverted)
            } catch {
                NSAlert.show(L10n.tr("Couldn't undo the rename."), error.localizedDescription + "\n\n" + L10n.tr("Nothing was changed."), in: NSApp.keyWindow)
            }
        }
        center.undoManager.setActionName(L10n.tr("Rename"))
    }
}

// MARK: - Batch rename dialog (FE-103)

/// Batch rename: find/replace (plain or regex), insert, case, numbering, extensions, with a live
/// preview that flags conflicts. Rename is disabled while any row has a problem; one undo step.
final class BatchRenameDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static private(set) var current: BatchRenameDialog?

    private let items: [RenameCandidate]
    private weak var browser: BrowserWindowController?
    let sheet: NSWindow
    private var existing: [URL: [String]]?
    private(set) var preview: BatchRenamePreview?
    private var patternError: String?

    private let find = NSTextField()
    private let replace = NSTextField()
    private let regex = NSButton(checkboxWithTitle: L10n.tr("Use regular expressions"), target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: L10n.tr("Match case"), target: nil, action: nil)
    private let includeExt = NSButton(checkboxWithTitle: L10n.tr("Include extension"), target: nil, action: nil)
    private let prefix = NSTextField()
    private let suffix = NSTextField()
    private let caseStyle = NSPopUpButton()
    private let numbering = NSButton(checkboxWithTitle: L10n.tr("Add numbers"), target: nil, action: nil)
    private let start = NSTextField()
    private let step = NSTextField()
    private let digits = NSTextField()
    private let separator = NSTextField()
    private let position = NSPopUpButton()
    private let extensionMode = NSPopUpButton()
    private let newExtension = NSTextField()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: L10n.tr("Rename"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.tr("Cancel"), target: nil, action: nil)

    static func run(items: [FileItem], window: BrowserWindowController) {
        guard let host = window.window, !items.isEmpty else { return }
        let dialog = BatchRenameDialog(items: items.map { RenameCandidate(url: $0.url, isFolder: $0.isFolder) }, browser: window)
        current = dialog
        host.beginSheet(dialog.sheet) { _ in if current === dialog { current = nil } }
        dialog.sheet.makeFirstResponder(dialog.find)
        dialog.loadExistingNames()
    }

    private init(items: [RenameCandidate], browser: BrowserWindowController) {
        self.items = items
        self.browser = browser
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        sheet.title = L10n.tr("Batch rename")
        sheet.minSize = NSSize(width: 640, height: 480)
        build()
        recompute()
    }

    /// Lists affected folders off-main (they can be large or remote).
    private func loadExistingNames() {
        let folders = Set(items.map(\.folder))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var names: [URL: [String]] = [:]
            for folder in folders { names[folder] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
            DispatchQueue.main.async {
                self?.existing = names
                self?.recompute()
            }
        }
    }

    // MARK: Layout

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.bodyFont
        l.textColor = Theme.primaryText
        l.alignment = .right
        return l
    }

    private func small(_ field: NSTextField, _ width: CGFloat) -> NSTextField {
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func build() {
        let content = ThemeBackgroundView(Theme.contentBackground)
        sheet.contentView = content

        let heading = NSTextField(labelWithString: L10n.format("Rename %@", "\(StatusText.items(items.count))"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        for f in [find, replace, prefix, suffix, start, step, digits, separator, newExtension] {
            f.font = Theme.bodyFont
            f.delegate = self
            f.cell?.usesSingleLineMode = true
        }
        find.placeholderString = L10n.tr("Text to find")
        replace.placeholderString = L10n.tr("Replace with")
        prefix.placeholderString = L10n.tr("Before the name")
        suffix.placeholderString = L10n.tr("After the name")
        start.stringValue = "1"
        step.stringValue = "1"
        digits.stringValue = "1"
        separator.stringValue = " "
        newExtension.placeholderString = L10n.tr("ext")
        find.setAccessibleName(L10n.tr("Find"))
        replace.setAccessibleName(L10n.tr("Replace with"))
        // VoiceOver names for the controls whose visible labels sit beside them in the grid.
        prefix.setAccessibleName(L10n.tr("Text before the name"))
        suffix.setAccessibleName(L10n.tr("Text after the name"))
        caseStyle.setAccessibleName(L10n.tr("Change case"))
        start.setAccessibleName(L10n.tr("Start"))
        step.setAccessibleName(L10n.tr("Step"))
        digits.setAccessibleName(L10n.tr("Digits"))
        separator.setAccessibleName(L10n.tr("Separator"))
        position.setAccessibleName(L10n.tr("Number position"))
        extensionMode.setAccessibleName(L10n.tr("Extension"))
        newExtension.setAccessibleName(L10n.tr("New extension"))
        for b in [regex, matchCase, includeExt, numbering] { b.target = self; b.action = #selector(controlChanged) }
        caseStyle.addItems(withTitles: RenameCaseStyle.allCases.map(\.title))
        position.addItems(withTitles: [L10n.tr("After the name"), L10n.tr("Before the name")])
        extensionMode.addItems(withTitles: [L10n.tr("Keep"), L10n.tr("lowercase"), L10n.tr("UPPERCASE"), L10n.tr("Remove"), L10n.tr("Change to:")])
        for p in [caseStyle, position, extensionMode] { p.target = self; p.action = #selector(controlChanged) }

        let grid = NSGridView(views: [
            [label(L10n.tr("Find:")), find],
            [label(L10n.tr("Replace with:")), replace],
            [NSGridCell.emptyContentView, NSStackView(views: [regex, matchCase, includeExt])],
            [label(L10n.tr("Insert text:")), NSStackView(views: [prefix, label(L10n.tr("and")), suffix])],
            [label(L10n.tr("Change case:")), caseStyle],
            [label(L10n.tr("Numbers:")), NSStackView(views: [numbering, label(L10n.tr("Start")), small(start, 54), label(L10n.tr("Step")), small(step, 44),
                                                     label(L10n.tr("Digits")), small(digits, 36), position])],
            [NSGridCell.emptyContentView, NSStackView(views: [label(L10n.tr("Separator")), small(separator, 54)])],
            [label(L10n.tr("Extension:")), NSStackView(views: [extensionMode, small(newExtension, 90)])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        find.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        replace.widthAnchor.constraint(equalTo: find.widthAnchor).isActive = true
        prefix.widthAnchor.constraint(equalToConstant: 180).isActive = true
        suffix.widthAnchor.constraint(equalToConstant: 180).isActive = true

        for (id, title, width) in [("old", L10n.tr("Current name"), 260.0), ("new", L10n.tr("New name"), 260.0), ("status", L10n.tr("Status"), 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.headerCell.attributedStringValue = NSAttributedString(string: L10n.tr(title), attributes: [
                .font: Theme.headerFont, .foregroundColor: Theme.secondaryText])
            column.width = width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.style = .plain
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.contentBackground
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L10n.tr("Preview"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let previewLabel = NSTextField(labelWithString: L10n.tr("Preview"))
        previewLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        summary.font = Theme.bodyFont
        summary.textColor = Theme.secondaryText
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        renameButton.target = self
        renameButton.action = #selector(renameClicked)
        renameButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        for b in [renameButton, cancelButton] {
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        }
        let footer = ThemeBackgroundView(Theme.navPaneBackground)
        let buttons = NSStackView(views: [summary, NSView(), renameButton, cancelButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)

        let top = NSStackView(views: [heading, grid, previewLabel])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top)
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 56),
            buttons.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    // MARK: Options → preview

    var options: BatchRenameOptions {
        var o = BatchRenameOptions()
        o.find = find.stringValue
        o.replace = replace.stringValue
        o.useRegex = regex.state == .on
        o.matchCase = matchCase.state == .on
        o.includeExtension = includeExt.state == .on
        o.caseStyle = RenameCaseStyle.allCases[max(0, caseStyle.indexOfSelectedItem)]
        o.prefix = prefix.stringValue
        o.suffix = suffix.stringValue
        o.numbering = numbering.state == .on
        o.numberStart = Int(start.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        o.numberStep = Int(step.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        o.numberDigits = min(10, max(1, Int(digits.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1))
        o.numberAtStart = position.indexOfSelectedItem == 1
        o.numberSeparator = separator.stringValue
        switch extensionMode.indexOfSelectedItem {
        case 1: o.extensionHandling = .lowercase
        case 2: o.extensionHandling = .uppercase
        case 3: o.extensionHandling = .remove
        case 4: o.extensionHandling = .change(to: newExtension.stringValue)
        default: o.extensionHandling = .keep
        }
        return o
    }

    func controlTextDidChange(_ obj: Notification) { recompute() }

    @objc private func controlChanged() { recompute() }

    func recompute() {
        for f in [start, step, digits, separator, position] { f.isEnabled = numbering.state == .on }
        newExtension.isEnabled = extensionMode.indexOfSelectedItem == 4
        do {
            patternError = nil
            preview = try BatchRenamer.preview(items, options: options) { [existing] folder in existing?[folder] ?? [] }
        } catch {
            patternError = error.localizedDescription
            preview = nil
        }
        table.reloadData()
        updateSummary()
    }

    private func updateSummary() {
        if let patternError {
            summary.stringValue = patternError
            summary.textColor = .systemRed
            renameButton.isEnabled = false
            return
        }
        guard let preview else { return }
        guard existing != nil else {
            summary.stringValue = L10n.tr("Checking names in the folder…")
            summary.textColor = Theme.secondaryText
            renameButton.isEnabled = false
            return
        }
        let problems = preview.problemCount
        let text: String
        if problems > 0 {
            text = (problems == 1 ? L10n.tr("1 name has a problem.") : L10n.format("%@ names have problems.", "\(problems)")) + L10n.tr(" Change the options to rename.")
        } else {
            text = preview.changeCount == 0 ? L10n.tr("No names change.") : L10n.format("%@ of %@ will be renamed.", "\(preview.changeCount)", "\(StatusText.items(items.count))")
        }
        summary.stringValue = text
        summary.textColor = problems > 0 ? .systemRed : Theme.secondaryText
        renameButton.isEnabled = preview.canApply
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = NSTextField(labelWithString: "")
        cell.font = Theme.bodyFont
        cell.lineBreakMode = .byTruncatingMiddle
        let r = preview?.rows[row]
        switch id {
        case "old": cell.stringValue = items[row].name
        case "new":
            cell.stringValue = r?.newName ?? "—"
            cell.textColor = r?.status == .unchanged ? Theme.secondaryText : Theme.primaryText
        default:
            cell.stringValue = r?.status.text ?? ""
            cell.textColor = r?.status.isProblem == true ? .systemRed : Theme.secondaryText
        }
        return cell
    }

    // MARK: Actions

    @objc private func renameClicked() {
        guard existing != nil, let preview, preview.canApply else { NSSound.beep(); return }
        do {
            let applied = try BatchRenamer.apply(preview.plan)
            RenameCommands.registerUndo(applied)
            close()
            if let browser {
                let renamed = Set(applied.map(\.to.lastPathComponent))
                let selection = preview.rows.map { renamed.contains($0.newName) ? $0.newName : $0.item.name }
                browser.navigate(to: browser.location, select: selection)
                browser.statusBar.setMessage(L10n.format("Renamed %@. Press ⌘Z to undo.", "\(StatusText.items(applied.count))"))
            }
        } catch {
            NSAlert.show(L10n.tr("Couldn't rename the items."), error.localizedDescription + "\n\n" + L10n.tr("Nothing was renamed."), in: sheet)
        }
    }

    @objc private func cancelClicked() { close() }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    // MARK: Scripted checks

    /// `batchset:find=IMG_` etc. for headless runs.
    func debugSet(_ key: String, _ value: String) {
        let on: NSControl.StateValue = value == "1" || value == "on" ? .on : .off
        switch key {
        case "find": find.stringValue = value
        case "replace": replace.stringValue = value
        case "regex": regex.state = on
        case "matchCase": matchCase.state = on
        case "includeExtension": includeExt.state = on
        case "prefix": prefix.stringValue = value
        case "suffix": suffix.stringValue = value
        case "case": caseStyle.selectItem(at: RenameCaseStyle.allCases.firstIndex { $0.rawValue == value } ?? 0)
        case "numbering": numbering.state = on
        case "start": start.stringValue = value
        case "step": step.stringValue = value
        case "digits": digits.stringValue = value
        case "separator": separator.stringValue = value
        case "numberAtStart": position.selectItem(at: on == .on ? 1 : 0)
        case "extension": extensionMode.selectItem(at: ["keep", "lower", "upper", "remove", "change"].firstIndex(of: value) ?? 0)
        case "newExtension": newExtension.stringValue = value
        default: NSLog("BatchRenameDialog: unknown option \(key)")
        }
        recompute()
    }

    var debugSummary: String {
        let rows = preview?.rows.map { "\($0.item.name) -> \($0.newName) [\($0.status.text)]" } ?? []
        return "batch rename: " + rows.joined(separator: " | ") + "\nbatch summary: \(summary.stringValue) rename enabled: \(renameButton.isEnabled)"
    }
}
