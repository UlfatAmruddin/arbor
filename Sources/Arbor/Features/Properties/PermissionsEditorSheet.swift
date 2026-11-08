import AppKit
import ArborCore

/// Security tab ▸ Edit… (FE-153): Explorer's "Permissions for <name>" in macOS terms. Adds and removes
/// access-list entries for users and groups, changes the group to one of the owner's own groups, and
/// explains why the owner can't be changed. Every change is shown as a summary to confirm first
/// ("Apply this change?"), applied at once, and the last change can be undone (refused if the list
/// changed again meanwhile). Only the owner (or root) can edit; others see the list read-only.
final class PermissionsEditorSheet: NSObject {
    private enum Change {
        case acl(ACLChange)
        case group(URL, from: gid_t, to: gid_t, summary: String)
        var summary: String {
            switch self {
            case .acl(let c): return c.summary
            case .group(_, _, _, let s): return s
            }
        }
    }

    private enum Staged {
        case add(ACLRule)
        case remove(Int, String)
        case group(gid_t, String)
    }

    private static var current: PermissionsEditorSheet?

    private let url: URL
    private let isFolder: Bool
    private let done: () -> Void
    private weak var parent: NSWindow?
    private let sheet: NSWindow
    private let canEdit: Bool
    private var entries: [ACLEntry] = []
    private var selected: Int?
    private var rows: [SheetListRow] = []
    private var staged: Staged?
    private var lastChange: Change?
    private let groups: [(id: gid_t, name: String)]

    private let list = SheetScrollList()
    private let emptyList = SheetLabel.make(L10n.tr("No access-list entries. Only the owner, group and everyone else permissions apply."), secondary: true)
    private let ownerLabel = SheetLabel.make("")
    private let groupPopup = NSPopUpButton()
    private lazy var addButton = SheetButton(L10n.tr("Add…")) { [weak self] _ in self?.showAddForm(true) }
    private lazy var removeButton = SheetButton(L10n.tr("Remove")) { [weak self] _ in self?.stageRemove() }
    private lazy var undoButton = SheetButton(L10n.tr("Undo last change")) { [weak self] _ in self?.undo() }
    private lazy var changeOwner = SheetButton(L10n.tr("Change…")) { _ in }
    private let addForm = NSStackView()
    private let kindPopup = NSPopUpButton()
    private let namePicker = NSComboBox()
    private let verdictPopup = NSPopUpButton()
    private let levelPopup = NSPopUpButton()
    private let inherit = SheetCheckbox(L10n.tr("Also apply to new files and folders inside"))
    private lazy var stageAdd = SheetButton(L10n.tr("Add")) { [weak self] _ in self?.stageAddition() }
    private let confirmBox = NSStackView()
    private let confirmText = SheetLabel.wrapping("", secondary: false)
    private let status = SheetLabel.wrapping("", small: true)

    static func show(for url: URL, over window: NSWindow, done: @escaping () -> Void) {
        let editor = PermissionsEditorSheet(url: url, parent: window, done: done)
        current = editor
        window.beginSheet(editor.sheet)
    }

    private init(url: URL, parent: NSWindow, done: @escaping () -> Void) {
        self.url = url
        self.parent = parent
        self.done = done
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        isFolder = isDirectory.boolValue
        canEdit = ACLEditor.canEdit(url)
        groups = ACLEditor.currentUserGroups()
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.title = L10n.format("Permissions for %@", "\(url.lastPathComponent)")
        build()
        reload()
    }

    // MARK: Layout

    private func build() {
        let content = ThemeBackgroundView(SheetColors.windowBackground)
        content.translatesAutoresizingMaskIntoConstraints = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView, gap: CGFloat? = nil) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let gap, let prev = stack.arrangedSubviews.dropLast().last { stack.setCustomSpacing(gap, after: prev) }
        }
        let object = SheetLabel.make(url.path, selectable: true)
        object.toolTip = url.path
        let objectLabel = SheetLabel.make(L10n.tr("Object name:"))
        objectLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        add(hstack([objectLabel, object], spacing: 6))

        // Owner (explained, not editable) and group (the owner's own groups).
        changeOwner.isEnabled = ACLEditor.canChangeOwner
        changeOwner.toolTip = ACLEditor.ownerChangeExplanation
        add(hstack([SheetLabel.make(L10n.tr("Owner:"), bold: true), ownerLabel, NSView(), changeOwner]), gap: 12)
        add(SheetLabel.wrapping(ACLEditor.ownerChangeExplanation, small: true))
        groupPopup.font = SheetColors.font
        groupPopup.target = self
        groupPopup.action = #selector(groupChosen)
        add(hstack([SheetLabel.make(L10n.tr("Group:"), bold: true), groupPopup, NSView()]), gap: 10)

        add(SheetLabel.make(L10n.tr("Access-list entries:"), bold: true), gap: 12)
        let box = SheetBox()
        box.addSubview(list)
        box.addSubview(emptyList)
        emptyList.lineBreakMode = .byWordWrapping
        emptyList.maximumNumberOfLines = 2
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 110),
            list.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            emptyList.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            emptyList.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            emptyList.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        add(box)
        add(hstack([NSView(), addButton, removeButton]))

        // Add form: who, allow/deny, level, inheritance.
        kindPopup.addItems(withTitles: [L10n.tr("Group"), L10n.tr("User")])
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        namePicker.font = SheetColors.font
        namePicker.completes = true
        namePicker.numberOfVisibleItems = 12
        namePicker.translatesAutoresizingMaskIntoConstraints = false
        namePicker.widthAnchor.constraint(equalToConstant: 170).isActive = true
        verdictPopup.addItems(withTitles: [L10n.tr("Allow"), L10n.tr("Deny")])
        levelPopup.addItems(withTitles: ACLPermissionLevel.allCases.map(\.title))
        levelPopup.selectItem(at: ACLPermissionLevel.allCases.firstIndex(of: .read) ?? 0)
        for p in [kindPopup, verdictPopup, levelPopup] { p.font = SheetColors.font }
        inherit.isHidden = !isFolder
        inherit.state = isFolder ? .on : .off
        let cancelAdd = SheetButton(L10n.tr("Cancel")) { [weak self] _ in self?.showAddForm(false) }
        addForm.orientation = .vertical
        addForm.alignment = .leading
        addForm.spacing = 6
        addForm.setViews([SheetLabel.make(L10n.tr("Add an entry"), bold: true),
                          hstack([kindPopup, namePicker, NSView()]),
                          hstack([verdictPopup, levelPopup, NSView()]),
                          inherit,
                          hstack([NSView(), stageAdd, cancelAdd])], in: .top)
        for v in addForm.arrangedSubviews { v.widthAnchor.constraint(equalTo: addForm.widthAnchor).isActive = true }
        addForm.isHidden = true
        add(addForm)

        // Confirmation summary.
        confirmBox.orientation = .vertical
        confirmBox.alignment = .leading
        confirmBox.spacing = 6
        let apply = SheetButton(L10n.tr("Apply"), isDefault: true) { [weak self] _ in self?.applyStaged() }
        let back = SheetButton(L10n.tr("Back")) { [weak self] _ in self?.unstage() }
        confirmBox.setViews([SheetLabel.make(L10n.tr("Apply this change?"), bold: true), confirmText, hstack([NSView(), apply, back])], in: .top)
        for v in confirmBox.arrangedSubviews { v.widthAnchor.constraint(equalTo: confirmBox.widthAnchor).isActive = true }
        confirmBox.isHidden = true
        add(confirmBox)

        add(SheetSeparator(), gap: 10)
        add(status)
        let close = SheetButton(L10n.tr("Close"), isDefault: false) { [weak self] _ in self?.close() }
        add(hstack([undoButton, NSView(), close]))

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 440),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        sheet.contentView = content
        kindChanged()
    }

    private func fit() {
        guard let content = sheet.contentView else { return }
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
    }

    // MARK: State

    private func reload() {
        entries = ACLEntry.read(url)
        if let s = selected, !entries.indices.contains(s) { selected = nil }
        let security = try? ItemSecurity.read(url)
        if let security {
            let full = ItemSecurity.fullName(security.ownerID).map { "\($0) (\(security.ownerName))" } ?? security.ownerName
            ownerLabel.stringValue = full
            groupPopup.removeAllItems()
            var names = groups.map(\.name)
            if !names.contains(security.groupName) { names.insert(security.groupName, at: 0) }
            groupPopup.addItems(withTitles: names)
            groupPopup.selectItem(withTitle: security.groupName)
        }
        list.removeAll()
        rows = []
        for (i, entry) in entries.enumerated() {
            let symbol = entry.kind == .group ? "person.2.fill" : "person.fill"
            let image = fixedImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), 14)
            image.contentTintColor = Theme.iconTint
            let verdict = SheetLabel.make(entry.allow ? L10n.tr("Allow") : L10n.tr("Deny"), bold: true)
            verdict.textColor = entry.allow ? SheetColors.success : SheetColors.failure
            verdict.widthAnchor.constraint(equalToConstant: 38).isActive = true
            let text = SheetLabel.make("\(entry.name)\(entry.isInherited ? " (inherited)" : ""): \(entry.levelTitle(isFolder: isFolder))")
            text.toolTip = text.stringValue
            let row = SheetListRow([image, verdict, text], height: 22)
            row.isSelected = i == selected
            row.onSelect = { [weak self] in self?.select(i) }
            rows.append(row)
            list.add(row)
        }
        emptyList.isHidden = !entries.isEmpty
        updateControls()
    }

    private func select(_ i: Int) {
        selected = i
        for (j, row) in rows.enumerated() { row.isSelected = j == i }
        updateControls()
    }

    private func updateControls() {
        let busy = staged != nil
        addButton.isEnabled = canEdit && !busy && addForm.isHidden
        removeButton.isEnabled = canEdit && !busy && selected.map { entries.indices.contains($0) && !entries[$0].isInherited } == true
        groupPopup.isEnabled = canEdit && !busy && groups.count > 1
        undoButton.isEnabled = canEdit && !busy && lastChange != nil
        undoButton.toolTip = lastChange.map { "Undo: \($0.summary)" }
        if !canEdit {
            status.stringValue = L10n.tr("Only the owner of this item or an administrator can change its permissions, so this list is read-only.")
        }
        fit()
    }

    @objc private func kindChanged() {
        let names = kindPopup.indexOfSelectedItem == 1 ? ACLEditor.localUsers() : ACLEditor.localGroups()
        namePicker.removeAllItems()
        namePicker.addItems(withObjectValues: names)
        namePicker.stringValue = names.first ?? ""
    }

    private func showAddForm(_ show: Bool) {
        addForm.isHidden = !show
        updateControls()
    }

    // MARK: Staging and applying

    private func stage(_ change: Staged, summary: String) {
        staged = change
        confirmText.stringValue = summary
        confirmBox.isHidden = false
        addForm.isHidden = true
        updateControls()
    }

    private func unstage() {
        staged = nil
        confirmBox.isHidden = true
        reload()
    }

    private func stageAddition() {
        let name = namePicker.stringValue.trimmingCharacters(in: .whitespaces)
        let principal = ACLPrincipal(kindPopup.indexOfSelectedItem == 1 ? .user : .group, name)
        guard !name.isEmpty, principal.exists else {
            status.stringValue = ACLEditError.unknownPrincipal(name).localizedDescription
            return
        }
        let level = ACLPermissionLevel.allCases[max(0, levelPopup.indexOfSelectedItem)]
        let rule = ACLRule(principal: principal, allow: verdictPopup.indexOfSelectedItem == 0, level: level,
                           inherit: isFolder && inherit.state == .on)
        var summary = "Add: \(rule.summary)."
        if !rule.allow {
            summary += L10n.tr(" Deny entries win over Allow entries, also for you. You keep the right to see and change these permissions.")
        }
        stage(.add(rule), summary: summary)
    }

    private func stageRemove() {
        guard let i = selected, entries.indices.contains(i) else { return }
        let e = entries[i]
        stage(.remove(i, e.name), summary: L10n.format("Remove: %@ %@ (%@): %@.", "\(e.allow ? "Allow" : "Deny")", "\(e.name)", "\(e.kind == .group ? "group" : "user")", "\(e.levelTitle(isFolder: isFolder))"))
    }

    @objc private func groupChosen() {
        guard let title = groupPopup.titleOfSelectedItem, let group = groups.first(where: { $0.name == title }),
              let security = try? ItemSecurity.read(url), group.id != security.groupID else { return }
        stage(.group(group.id, group.name), summary: L10n.format("Change the group from %@ to %@. Group permissions then apply to members of %@.", "\(security.groupName)", "\(group.name)", "\(group.name)"))
    }

    private func applyStaged() {
        guard let staged else { return }
        do {
            switch staged {
            case .add(let rule):
                lastChange = .acl(try ACLEditor.add(rule, to: url))
            case .remove(let index, let name):
                // The list may have changed since it was shown: remove only the same entry.
                guard ACLEntry.read(url).indices.contains(index), ACLEntry.read(url)[index].name == name else {
                    throw ACLEditError.changedSinceEdit
                }
                lastChange = .acl(try ACLEditor.remove(at: index, from: url))
            case .group(let gid, let name):
                let before = try ItemSecurity.read(url)
                try ACLEditor.changeGroup(url, to: gid)
                lastChange = .group(url, from: before.groupID, to: gid, summary: L10n.format("Group changed from %@ to %@", "\(before.groupName)", "\(name)"))
            }
            status.stringValue = L10n.format("Done. %@", "\(lastChange?.summary ?? "")")
        } catch {
            status.stringValue = L10n.format("Not changed: %@", "\(error.localizedDescription)")
        }
        self.staged = nil
        confirmBox.isHidden = true
        selected = nil
        reload()
        PropertiesFeature.itemsChanged(old: url, new: url)
    }

    private func undo() {
        guard let change = lastChange else { return }
        do {
            switch change {
            case .acl(let c): try ACLEditor.undo(c)
            case .group(let url, let from, let to, _):
                guard (try? ItemSecurity.read(url))?.groupID == to else { throw ACLEditError.changedSinceEdit }
                try ACLEditor.changeGroup(url, to: from)
            }
            status.stringValue = L10n.format("Undone: %@", "\(change.summary)")
            lastChange = nil
        } catch {
            status.stringValue = L10n.format("Couldn't undo: %@", "\(error.localizedDescription)")
        }
        reload()
        PropertiesFeature.itemsChanged(old: url, new: url)
    }

    private func close() {
        parent?.endSheet(sheet)
        sheet.orderOut(nil)
        Self.current = nil
        done()
    }

    // MARK: Scripting

    /// aclset:kind=group,name=staff,verdict=deny,level=modify,inherit=off,select=0,group=staff
    static func scriptSet(_ argument: String) {
        guard let editor = current else { return }
        for part in argument.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "kind":
                editor.kindPopup.selectItem(at: kv[1] == "user" ? 1 : 0)
                editor.kindChanged()
            case "name": editor.namePicker.stringValue = kv[1]
            case "verdict": editor.verdictPopup.selectItem(at: kv[1] == "deny" ? 1 : 0)
            case "level":
                if let i = ACLPermissionLevel.allCases.firstIndex(where: { $0.rawValue == kv[1] }) { editor.levelPopup.selectItem(at: i) }
            case "inherit": editor.inherit.state = kv[1] == "on" ? .on : .off
            case "select": Int(kv[1]).map(editor.select)
            case "group":
                editor.groupPopup.selectItem(withTitle: kv[1])
                editor.groupChosen()
            default: break
            }
        }
    }

    static var debugText: String {
        guard let e = current else { return "permissions editor: none" }
        return ["permissions editor: \(e.sheet.title) editable=\(e.canEdit)",
                "entries: \(e.entries.map { "\($0.allow ? "allow" : "deny") \($0.name) [\($0.permissions.joined(separator: ","))]" }.joined(separator: " | "))",
                "owner: \(e.ownerLabel.stringValue) group: \(e.groupPopup.titleOfSelectedItem ?? "-")",
                "staged: \(e.confirmBox.isHidden ? "-" : e.confirmText.stringValue)",
                "undo: \(e.undoButton.isEnabled ? (e.lastChange?.summary ?? "") : "disabled")",
                "status: \(e.status.stringValue)"].joined(separator: "\n")
    }
}
