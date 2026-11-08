import AppKit
import ArborCore

/// The Folder Options dialog (FE-042, FE-043): General · View · Search pages with Windows' controls,
/// order and wording, OK / Cancel / Apply, and Restore Defaults per page. Values live in `Prefs`.
final class FolderOptionsWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var shared: FolderOptionsWindowController?

    /// Opens (or brings forward) the dialog. `origin` is the window whose folder "Apply to Folders" uses.
    static func show(tab: FolderOptionsTab = .general, from origin: BrowserWindowController?) {
        let controller = shared ?? FolderOptionsWindowController()
        shared = controller
        controller.origin = origin
        controller.selectTab(tab)
        controller.refreshFolderViewsInfo()
        if !controller.window!.isVisible, let parent = origin?.window {
            let frame = controller.window!.frame
            controller.window!.setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.maxY - 90))
        }
        controller.showWindow(nil)
        if AppDelegate.isHeadless {
            controller.window?.alphaValue = 0
            controller.window?.ignoresMouseEvents = true
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    weak var origin: BrowserWindowController?
    private(set) var draft: FolderOptionsDraft
    private(set) var currentTab: FolderOptionsTab = .general
    private let tabBar = DialogTabBar()
    private var pages: [FolderOptionsTab: NSView] = [:]
    /// Controls by key; radios carry "key=value" identifiers.
    private var buttons: [String: [NSButton]] = [:]
    private var notes: [String: NSTextField] = [:]
    private var openToPopup: NSPopUpButton?
    private let applyButton = DialogButton(L10n.tr("Apply"), target: nil, action: nil)
    private let applyToFoldersButton = DialogButton(L10n.tr("Apply to Folders"), target: nil, action: nil)
    private let resetFoldersButton = DialogButton(L10n.tr("Reset Folders"), target: nil, action: nil)
    private let folderInfo = NSTextField(wrappingLabelWithString: "")
    private let historyNote = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?
    private var suppressRefresh = false

    private init() {
        draft = FolderOptionsDraft(current: FolderOptionsPrefs.current(), disabledKeys: FolderOptionsPrefs.runtimeDisabledKeys)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 452, height: 590), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = L10n.tr("Folder Options")
        window.isReleasedWhenClosed = false
        window.backgroundColor = DialogStyle.background
        super.init(window: window)
        window.delegate = self
        build()
        update()
        window.center()
        observer = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.suppressRefresh else { return }
            self.draft.refresh(from: FolderOptionsPrefs.current())
            self.update()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: Layout

    private func build() {
        let root = DialogBackgroundView()
        root.widthAnchor.constraint(equalToConstant: Width.window).isActive = true
        tabBar.titles = FolderOptionsTab.allCases.map(\.title)
        tabBar.onSelect = { [weak self] i in self?.showPage(FolderOptionsTab.allCases[i]) }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)

        let pageHost = DialogPageView()
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageHost)
        for tab in FolderOptionsTab.allCases {
            let page: NSView
            switch tab {
            case .general: page = buildGeneral()
            case .view: page = buildView()
            case .search: page = buildSearch()
            }
            page.translatesAutoresizingMaskIntoConstraints = false
            pageHost.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: pageHost.topAnchor, constant: 12),
                page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor, constant: 12),
                page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor, constant: -12),
                page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor, constant: -12),
            ])
            pages[tab] = page
        }

        let ok = DialogButton(L10n.tr("OK"), target: self, action: #selector(okPressed(_:)))
        ok.isDefaultButton = true
        ok.keyEquivalent = "\r"
        let cancel = DialogButton(L10n.tr("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyPressed(_:))
        let buttons = NSStackView(views: [ok, cancel, applyButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            pageHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            pageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            buttons.topAnchor.constraint(equalTo: pageHost.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    /// Widths available to wrapping text (the dialog has a fixed width, like Windows' property sheets).
    private enum Width {
        static let window: CGFloat = 452
        static let page: CGFloat = 408
        static let groupWithIcon: CGFloat = 346
        static let group: CGFloat = 386
        static let list: CGFloat = 372
    }

    private func label(_ text: String, width: CGFloat = Width.page, font: NSFont = DialogStyle.font,
                       color: NSColor = Theme.primaryText) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        return field
    }

    /// Lets a check box or radio title wrap onto more lines within `width`.
    private func fit(_ button: NSButton, width: CGFloat) {
        button.font = DialogStyle.font
        button.lineBreakMode = .byWordWrapping
        button.cell?.wraps = true
        let natural = button.cell?.cellSize ?? .zero
        guard natural.width > width, let size = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)) else { return }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: ceil(size.height)).isActive = true
    }

    private func checkbox(_ item: FolderOptionItem, width: CGFloat) -> NSView {
        let button = NSButton(checkboxWithTitle: item.title, target: self, action: #selector(checkChanged(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(item.key)
        fit(button, width: width)
        buttons[item.key, default: []].append(button)
        guard let reason = item.unavailableReason else { return button }
        button.isEnabled = false
        return withNote(button, reason, key: item.key, width: width)
    }

    /// A disabled control with its one-line Mac explanation underneath, aligned with the title.
    private func withNote(_ control: NSView, _ text: String, key: String, width: CGFloat) -> NSView {
        let note = label(text, width: width - 20, font: DialogStyle.noteFont, color: Theme.secondaryText)
        notes[key] = note
        let indent = NSStackView(views: [note])
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let stack = NSStackView(views: [control, indent])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    private func radios(_ item: FolderOptionItem, width: CGFloat) -> [NSView] {
        item.choices.map { choice in
            let button = NSButton(radioButtonWithTitle: choice.title, target: self, action: #selector(radioChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("\(item.key)=\(choice.value)")
            let indentWidth = CGFloat(choice.level) * 20
            fit(button, width: width - indentWidth)
            buttons[item.key, default: []].append(button)
            guard choice.level > 0 else { return button }
            let indent = NSStackView(views: [button])
            indent.edgeInsets = NSEdgeInsets(top: 0, left: indentWidth, bottom: 0, right: 0)
            return indent
        }
    }

    private func pageStack(_ views: [NSView], restoreTab: FolderOptionsTab) -> NSView {
        let restore = DialogButton(L10n.tr("Restore Defaults"), target: self, action: #selector(restoreDefaults(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let bottom = NSStackView(views: [NSView(), restore])
        bottom.orientation = .horizontal
        let stack = NSStackView(views: views + [spacer, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for v in views + [bottom] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func buildGeneral() -> NSView {
        let items = Dictionary(uniqueKeysWithValues: FolderOptionsCatalog.general.map { ($0.key, $0) })
        let openTo = NSPopUpButton()
        openTo.font = DialogStyle.font
        for choice in items["openTo"]!.choices {
            openTo.addItem(withTitle: choice.title)
            openTo.lastItem?.representedObject = choice.value
        }
        openTo.target = self
        openTo.action = #selector(popupChanged(_:))
        openTo.identifier = NSUserInterfaceItemIdentifier("openTo")
        openToPopup = openTo
        let openRow = NSStackView(views: [label(items["openTo"]!.title, width: 120), openTo])
        openRow.spacing = 8
        openTo.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let browse = GroupBoxView(title: L10n.tr("Browse folders"), symbol: "macwindow.on.rectangle")
        radios(items["browseFolders"]!, width: Width.groupWithIcon).forEach(browse.content.addArrangedSubview)

        let click = GroupBoxView(title: L10n.tr("Click items as follows"), symbol: "cursorarrow.click.2")
        let clickRadios = radios(items["clickItems"]!, width: Width.groupWithIcon)
        click.content.addArrangedSubview(clickRadios[0])
        radios(items["underlineTitles"]!, width: Width.groupWithIcon).forEach(click.content.addArrangedSubview)
        click.content.addArrangedSubview(clickRadios[1])

        let privacy = GroupBoxView(title: L10n.tr("Privacy"), symbol: "hand.raised")
        for key in ["showRecentFiles", "showFrequentFolders", "accountInsights"] { privacy.content.addArrangedSubview(checkbox(items[key]!, width: Width.groupWithIcon)) }
        let clear = DialogButton(L10n.tr("Clear"), target: self, action: #selector(clearHistory(_:)))
        historyNote.font = DialogStyle.noteFont
        historyNote.textColor = Theme.secondaryText
        let clearRow = NSStackView(views: [label(L10n.tr("Clear Arbor history"), width: 140), clear, historyNote])
        clearRow.spacing = 10
        privacy.content.addArrangedSubview(clearRow)
        privacy.content.setCustomSpacing(10, after: privacy.content.arrangedSubviews[privacy.content.arrangedSubviews.count - 2])

        return pageStack([openRow, browse, click, privacy], restoreTab: .general)
    }

    private func buildView() -> NSView {
        let views = GroupBoxView(title: L10n.tr("Folder views"), symbol: "rectangle.grid.2x2")
        views.content.addArrangedSubview(label(L10n.tr("You can apply this view (such as Details or Icons) to all folders of this type."),
                                               width: Width.groupWithIcon))
        applyToFoldersButton.target = self
        applyToFoldersButton.action = #selector(applyToFolders(_:))
        resetFoldersButton.target = self
        resetFoldersButton.action = #selector(resetFolders(_:))
        let row = NSStackView(views: [applyToFoldersButton, resetFoldersButton])
        row.spacing = 8
        views.content.addArrangedSubview(row)
        folderInfo.font = DialogStyle.noteFont
        folderInfo.textColor = Theme.secondaryText
        folderInfo.isSelectable = false
        folderInfo.preferredMaxLayoutWidth = Width.groupWithIcon
        views.content.addArrangedSubview(folderInfo)
        if let first = views.content.arrangedSubviews.first { views.content.setCustomSpacing(10, after: first) }

        let advanced = label(L10n.tr("Advanced settings:"))
        let list = buildAdvancedList()
        list.heightAnchor.constraint(equalToConstant: 306).isActive = true
        let stack = pageStack([views, advanced, list], restoreTab: .view)
        (stack as? NSStackView)?.setCustomSpacing(4, after: advanced)
        return stack
    }

    private func buildAdvancedList() -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 8, right: 8)
        rows.translatesAutoresizingMaskIntoConstraints = false
        func indented(_ view: NSView, _ level: Int) -> NSView {
            let wrap = NSStackView(views: [view])
            wrap.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(level) * 18, bottom: 0, right: 0)
            return wrap
        }
        func node(_ title: String, level: Int) -> NSView {
            let icon = NSImageView(image: IconProvider.shared.folderIcon(size: 16))
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let text = label(title)
            let row = NSStackView(views: [icon, text])
            row.spacing = 5
            return indented(row, level)
        }
        for item in FolderOptionsCatalog.advanced {
            switch item.kind {
            case .group: rows.addArrangedSubview(node(item.title, level: 0))
            case .check: rows.addArrangedSubview(indented(checkbox(item, width: Width.list - 18), 1))
            case .radio:
                rows.addArrangedSubview(node(item.title, level: 1))
                radios(item, width: Width.list - 36).forEach { rows.addArrangedSubview(indented($0, 2)) }
            case .popup: break
            }
            if item.key == "showLibraries", let note = libraryNote() { rows.addArrangedSubview(indented(note, 2)) }
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let frame = FramedView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: frame.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -1),
        ])
        return frame
    }

    private func libraryNote() -> NSView? {
        guard !FolderOptionsPrefs.librariesAvailable else { return nil }
        let note = label(L10n.tr("Libraries aren't part of this build of Arbor yet."), width: Width.list - 56,
                         font: DialogStyle.noteFont, color: Theme.secondaryText)
        notes["showLibraries"] = note
        let wrap = NSStackView(views: [note])
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return wrap
    }

    private func buildSearch() -> NSView {
        let items = Dictionary(uniqueKeysWithValues: FolderOptionsCatalog.search.map { ($0.key, $0) })
        let how = GroupBoxView(title: L10n.tr("How to search"), symbol: "magnifyingglass")
        how.content.addArrangedSubview(checkbox(items["searchWithoutIndex"]!, width: Width.groupWithIcon))
        let nonIndexed = GroupBoxView(title: L10n.tr("When searching non-indexed locations"), symbol: nil)
        for key in ["searchIncludeSystemDirectories", "searchIncludeCompressedFiles", "searchFileContents"] {
            nonIndexed.content.addArrangedSubview(checkbox(items[key]!, width: Width.group))
        }
        let note = label(L10n.tr("“The index” is Spotlight on the Mac. Choose which folders Spotlight indexes in System Settings › Spotlight."),
                         width: Width.page, font: DialogStyle.noteFont, color: Theme.secondaryText)
        return pageStack([how, nonIndexed, note], restoreTab: .search)
    }

    // MARK: State

    func selectTab(_ tab: FolderOptionsTab) {
        guard let index = FolderOptionsTab.allCases.firstIndex(of: tab) else { return }
        tabBar.select(index)
    }

    private func showPage(_ tab: FolderOptionsTab) {
        currentTab = tab
        for (t, page) in pages { page.isHidden = t != tab }
    }

    /// Puts the draft into the controls.
    private func update() {
        for (key, list) in buttons {
            let value = draft[key]
            let item = FolderOptionsCatalog.item(key)
            let available = (item?.isAvailable ?? false) && !draft.disabledKeys.contains(key)
            for button in list {
                let id = button.identifier?.rawValue ?? ""
                if let eq = id.firstIndex(of: "=") {
                    let choiceValue = String(id[id.index(after: eq)...])
                    button.state = value?.string == choiceValue ? .on : .off
                    let choice = item?.choices.first { $0.value == choiceValue }
                    button.isEnabled = available && (choice.map(draft.isEnabled) ?? true)
                } else {
                    button.state = value?.bool == true ? .on : .off
                    button.isEnabled = available
                }
            }
        }
        if let popup = openToPopup, let value = draft["openTo"]?.string,
           let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == value }) {
            popup.selectItem(at: index)
        }
        applyButton.isEnabled = draft.isDirty
        refreshFolderViewsInfo()
    }

    /// The "this folder" line on the View page and whether Apply to Folders can run.
    func refreshFolderViewsInfo() {
        let info = origin.flatMap { FolderViews.shared.info(for: $0) }
        applyToFoldersButton.isEnabled = info != nil
        resetFoldersButton.isEnabled = FolderViews.shared.hasSavedViews
        if let info {
            let type = info.chosen ? L10n.format("%@ (set in Properties)", "\(info.template.title)") : L10n.format("%@ folder type", "\(info.template.title)")
            let source = info.source == .template(info.template, applied: false) ? "default view for this type" : info.source.description
            folderInfo.stringValue = L10n.format("This folder: “%@” · %@ · %@", "\(info.name)", "\(type)", "\(source)")
        } else {
            folderInfo.stringValue = L10n.tr("Open Folder Options from a folder window to apply its view to similar folders.")
        }
    }

    // MARK: Actions

    @objc private func checkChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        if key == "hideProtectedSystemFiles", !on {
            confirmShowProtected(sender)
            return
        }
        draft.set(key, .bool(on))
        update()
    }

    @objc private func radioChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let eq = id.firstIndex(of: "=") else { return }
        draft.set(String(id[..<eq]), .string(String(id[id.index(after: eq)...])))
        update()
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        draft.set("openTo", .string(value))
        update()
    }

    /// Windows warns before showing protected system files; the Mac wording explains what they are.
    private func confirmShowProtected(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Warning")
        alert.informativeText = L10n.tr("You have chosen to display protected operating system files (files macOS uses to keep track of folders, volumes and Spotlight, such as .DS_Store, and the system folders at the top of the startup disk). Deleting or editing them can make files or apps stop working. Are you sure you want to display these files?")
        alert.addButton(withTitle: L10n.tr("Yes"))
        alert.addButton(withTitle: L10n.tr("No"))
        alert.buttons[0].keyEquivalent = ""          // the safe answer, No, is the default
        alert.buttons[1].keyEquivalent = "\r"
        present(alert) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.draft.set("hideProtectedSystemFiles", .bool(false)) }
            self.update()
        }
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        draft.restoreDefaults(currentTab)
        update()
    }

    @objc private func applyPressed(_ sender: Any?) { commit() }

    @objc private func okPressed(_ sender: Any?) {
        commit()
        window?.close()
    }

    @objc private func cancelPressed(_ sender: Any?) { window?.close() }

    private func commit() {
        let changes = draft.commit()
        guard !changes.isEmpty else { update(); return }
        suppressRefresh = true
        FolderOptionsPrefs.write(changes)
        suppressRefresh = false
        update()
    }

    @objc private func clearHistory(_ sender: Any?) {
        let count = FolderOptionsHistory.clear()
        historyNote.stringValue = count > 0 ? L10n.tr("History cleared.") : L10n.tr("There's no history to clear.")
    }

    @objc private func applyToFolders(_ sender: Any?) {
        guard let origin, let info = FolderViews.shared.info(for: origin) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Folder Views")
        alert.informativeText = L10n.format("Do you want all folders of this type to match this folder's view settings?\n\nEvery “%@” folder will use the view of “%@”. Folders of this type with their own saved view are reset to it. Your files aren't changed.", "\(info.template.title)", "\(info.name)")
        alert.addButton(withTitle: L10n.tr("Yes"))
        alert.addButton(withTitle: L10n.tr("No"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let origin = self.origin else { return }
            FolderViews.shared.applyToFolders(from: origin)
            self.refreshFolderViewsInfo()
        }
    }

    @objc private func resetFolders(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Folder Views")
        let count = FolderViews.shared.savedCount
        alert.informativeText = count == 1
            ? L10n.tr("Do you want to reset all folders to their default view settings?\n\nArbor forgets the saved view of 1 folder and any view applied to a folder type. Your files aren't changed.")
            : L10n.format("Do you want to reset all folders to their default view settings?\n\nArbor forgets the saved views of %@ folders and any view applied to a folder type. Your files aren't changed.", "\(count)")
        alert.addButton(withTitle: L10n.tr("Yes"))
        alert.addButton(withTitle: L10n.tr("No"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            FolderViews.shared.resetFolders()
            self?.refreshFolderViewsInfo()
        }
    }

    private func present(_ alert: NSAlert, _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
        AlertSheets.present(alert, in: window?.isVisible == true ? window : nil, completion: completion)
    }

    func windowWillClose(_ notification: Notification) {
        // Cancel semantics: unapplied edits are dropped; the next opening starts from the saved values.
        draft = FolderOptionsDraft(current: FolderOptionsPrefs.current(), disabledKeys: FolderOptionsPrefs.runtimeDisabledKeys)
        historyNote.stringValue = ""
        update()
    }

    // MARK: Scripting (DebugScript steps)

    /// Clicks the control for `key` so it takes the same path as a user click (warnings included).
    func scriptSet(_ key: String, _ value: OptionValue) {
        if key == "openTo", let popup = openToPopup, case .string(let v) = value,
           let i = popup.itemArray.firstIndex(where: { $0.representedObject as? String == v }) {
            popup.selectItem(at: i)
            popupChanged(popup)
            return
        }
        guard let list = buttons[key] else { NSLog("Folder Options: no control \(key)"); return }
        switch value {
        case .bool(let on):
            if let b = list.first, (b.state == .on) != on, b.isEnabled { b.performClick(nil) }
        case .string(let v):
            if let b = list.first(where: { $0.identifier?.rawValue == "\(key)=\(v)" }), b.isEnabled { b.performClick(nil) }
        }
    }

    /// Presses a button by title, looking in an attached sheet first.
    func scriptPress(_ title: String) -> Bool {
        if let sheet = window?.attachedSheet, let b = Self.findButton(title, in: sheet.contentView) {
            b.performClick(nil)
            return true
        }
        guard let b = Self.findButton(title, in: window?.contentView, visibleOnly: true) else { return false }
        b.performClick(nil)
        return true
    }

    private static func findButton(_ title: String, in view: NSView?, visibleOnly: Bool = false) -> NSButton? {
        guard let view, !(visibleOnly && view.isHidden) else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for sub in view.subviews { if let found = findButton(title, in: sub, visibleOnly: visibleOnly) { return found } }
        return nil
    }

    var debugState: String {
        var lines = ["folder options: tab=\(currentTab.rawValue) dirty=\(draft.isDirty) apply=\(applyButton.isEnabled) sheet=\(window?.attachedSheet != nil)"]
        lines.append("draft: " + FolderOptionsCatalog.all.compactMap { item in draft[item.key].map { "\(item.key)=\($0)" } }.joined(separator: " "))
        var disabled: [String] = []
        for (key, list) in buttons.sorted(by: { $0.key < $1.key }) where list.allSatisfy({ !$0.isEnabled }) { disabled.append(key) }
        lines.append("disabled: " + disabled.joined(separator: " "))
        lines.append("applyToFolders=\(applyToFoldersButton.isEnabled) resetFolders=\(resetFoldersButton.isEnabled) info: \(folderInfo.stringValue)")
        return lines.joined(separator: "\n")
    }
}

/// "Clear Arbor history" (Folder Options › Privacy). Features that keep history (recent files, frequent
/// folders, address suggestions) register a clearer that returns how many entries it removed.
enum FolderOptionsHistory {
    /// Each contribution adds how many entries it removed.
    static let clearers = Pipeline<Int, Void>(
        "FolderOptionsHistory.clearers", "Clears a feature's history for \"Clear Arbor history\"; adds the count removed.",
        signature: "(removed) -> removed")

    static func register(_ id: String, _ clear: @escaping () -> Int) { clearers.add(id) { $0 + clear() } }

    @discardableResult
    static func clear() -> Int {
        var removed = 0
        let documents = NSDocumentController.shared
        removed += documents.recentDocumentURLs.count
        documents.clearRecentDocuments(nil)
        return clearers.apply(removed)
    }
}
