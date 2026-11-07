import AppKit
import ArborCore

/// The Security tab in Mac terms (FE-153, FE-245): owner, group and everyone else with their POSIX
/// permissions, any ACL entries, and the current user's access *tested* with access(2). Windows'
/// Allow/Deny grid is kept only where it is real: POSIX has no Deny, ACL entries do.
final class SecurityTab: PropertiesTab, PropertiesTabDebug {
    let title = "Security"
    let view: NSView
    private let model: PropertiesModel
    private let page = SheetPage()
    private let objectName = SheetLabel.make("", selectable: true)
    private let namesBox = SheetBox()
    /// Scrolls when owner, group, everyone and access-list entries don't fit the box.
    private let namesScroll = SheetScrollList()
    private var namesList: NSStackView { namesScroll.stack }
    private let permissionsTitle = SheetLabel.make("", bold: true)
    private let allowHeader = SheetLabel.make("Allow")
    private let denyHeader = SheetLabel.make("Deny")
    private let grid = NSStackView()
    private let modeLabel = SheetLabel.make("")
    private let accessGrid = NSStackView()
    private let ownership = SheetLabel.wrapping("", small: true)

    private var security: ItemSecurity?
    private var selected = 0
    private var principals: [Principal] = []
    private var loadToken = 0

    private enum Principal {
        case role(PosixPermissions.Role, String)
        case acl(ACLEntry)

        var title: String {
            switch self {
            case .role(.owner, let name): return "\(name) (Owner)"
            case .role(.group, let name): return "\(name) (Group)"
            case .role(.everyone, _): return "Everyone else"
            case .acl(let e): return "\(e.name) (\(e.kind == .group ? "group" : "user"), access list\(e.isInherited ? ", inherited" : ""))"
            }
        }

        var symbol: String {
            switch self {
            case .role(.owner, _): return "person.fill"
            case .role(.group, _): return "person.2.fill"
            case .role(.everyone, _): return "person.3.fill"
            case .acl(let e): return e.kind == .group ? "person.2.badge.key.fill" : "person.badge.key.fill"
            }
        }
    }

    init(model: PropertiesModel) {
        self.model = model
        view = page
        build()
        load()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView, after spacing: CGFloat? = nil) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let spacing, let prev = stack.arrangedSubviews.dropLast().last { stack.setCustomSpacing(spacing, after: prev) }
        }
        let objectLabel = SheetLabel.make("Object name:")
        objectLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        objectLabel.setContentHuggingPriority(.required, for: .horizontal)
        let objectRow = hstack([objectLabel, objectName], spacing: 6)
        add(objectRow)
        add(SheetLabel.make("Group or user names:"), after: 12)
        namesList.orientation = .vertical
        namesList.alignment = .leading
        namesList.spacing = 0
        namesBox.addSubview(namesScroll)
        NSLayoutConstraint.activate([
            namesBox.heightAnchor.constraint(equalToConstant: 96),
            namesScroll.topAnchor.constraint(equalTo: namesBox.topAnchor, constant: 2),
            namesScroll.leadingAnchor.constraint(equalTo: namesBox.leadingAnchor, constant: 1),
            namesScroll.trailingAnchor.constraint(equalTo: namesBox.trailingAnchor, constant: -1),
            namesScroll.bottomAnchor.constraint(equalTo: namesBox.bottomAnchor, constant: -1),
        ])
        add(namesBox)
        // Explorer: "To change permissions, click Edit." [Edit…] (access-list entries, group).
        let edit = SheetButton("Edit…") { [weak self] _ in self?.openEditor() }
        let editHint = SheetLabel.make("To change permissions, click Edit.")
        editHint.setContentCompressionResistancePriority(.required, for: .horizontal)
        add(hstack([editHint, NSView(), edit]))
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        for v in [permissionsTitle, allowHeader, denyHeader] { header.addSubview(v) }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 18),
            permissionsTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            permissionsTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            permissionsTitle.trailingAnchor.constraint(lessThanOrEqualTo: allowHeader.leadingAnchor, constant: -8),
            denyHeader.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            denyHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            allowHeader.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -62),
            allowHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        add(header, after: 12)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 0
        grid.translatesAutoresizingMaskIntoConstraints = false
        let gridBox = SheetBox()
        gridBox.addSubview(grid)
        NSLayoutConstraint.activate([
            gridBox.heightAnchor.constraint(equalToConstant: 92),
            grid.topAnchor.constraint(equalTo: gridBox.topAnchor, constant: 3),
            grid.leadingAnchor.constraint(equalTo: gridBox.leadingAnchor, constant: 1),
            grid.trailingAnchor.constraint(equalTo: gridBox.trailingAnchor, constant: -1),
        ])
        add(gridBox)
        add(modeLabel)
        add(SheetLabel.make("Your access (tested on this Mac):", bold: true), after: 12)
        accessGrid.orientation = .horizontal
        accessGrid.spacing = 14
        accessGrid.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(accessGrid)
        add(ownership, after: 10)
        page.embed(stack)
    }

    private func load() {
        guard let url = model.single?.url else { return }
        loadToken += 1
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let security = try? ItemSecurity.read(url)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.security = security
                self.rebuild()
            }
        }
    }

    func reload() {
        guard let entry = model.single else { return }
        objectName.stringValue = entry.url.path
        objectName.toolTip = entry.url.path
        if let security, entry.edited.mode != security.permissions.mode || entry.original.mode != security.permissions.mode {
            // Edited permissions show immediately; apply reloads from disk.
            rebuildGrid()
        }
        if security == nil || model.entries.first?.original.mode != security?.permissions.mode { load() }
    }

    private var editedPermissions: PosixPermissions {
        PosixPermissions(mode: model.single?.edited.mode ?? security?.permissions.mode ?? 0)
    }

    private func rebuild() {
        guard let security else {
            namesList.arrangedSubviews.forEach { $0.removeFromSuperview() }
            ownership.stringValue = "The permissions of this item couldn't be read."
            return
        }
        principals = [.role(.owner, security.ownerName), .role(.group, security.groupName), .role(.everyone, "")]
            + security.acl.map { .acl($0) }
        selected = min(selected, principals.count - 1)
        namesList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, p) in principals.enumerated() {
            let image = fixedImage(NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil), 14)
            image.contentTintColor = Theme.iconTint
            let row = SheetListRow([image, SheetLabel.make(p.title)], height: 22)
            row.isSelected = i == selected
            row.onSelect = { [weak self] in
                self?.selected = i
                self?.rebuild()
            }
            namesList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: namesList.widthAnchor).isActive = true
        }
        rebuildGrid()
        accessGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in security.access.lines(isFolder: security.isFolder) {
            let mark = fixedImage(NSImage(systemSymbolName: line.allowed ? "checkmark.circle.fill" : "xmark.circle.fill",
                                          accessibilityDescription: line.allowed ? "allowed" : "not allowed"), 13)
            mark.contentTintColor = line.allowed ? SheetColors.success : SheetColors.failure
            let item = hstack([mark, SheetLabel.make(line.label)], spacing: 4)
            accessGrid.addArrangedSubview(item)
        }
        var note: String
        let fullName = ItemSecurity.fullName(security.ownerID).map { "\($0) (\(security.ownerName))" } ?? security.ownerName
        if security.currentUserCanChangePermissions {
            note = "You own this item, so you can change these permissions. Changes are applied with Apply or OK."
        } else {
            note = "Owner: \(fullName). Only the owner or an administrator can change these permissions."
        }
        if security.flags.isLocked { note += " The item is Locked (Read-only on the General tab), which blocks changes even where permissions allow them." }
        if !security.acl.isEmpty { note += " To add or remove access-list entries, click Edit." }
        ownership.stringValue = note
    }

    private func rebuildGrid() {
        guard let security, principals.indices.contains(selected) else { return }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let principal = principals[selected]
        permissionsTitle.stringValue = "Permissions for \(principal.title.replacingOccurrences(of: " (Owner)", with: "").replacingOccurrences(of: " (Group)", with: ""))"
        let canEdit = security.currentUserCanChangePermissions
        switch principal {
        case .role(let role, _):
            denyHeader.isHidden = false
            let bits = editedPermissions[role]
            let labels = security.isFolder ? ["List folder contents", "Add, rename and delete items", "Open folder (traverse)"]
                                           : ["Read", "Write", "Execute (run as a program)"]
            let values = [bits.read, bits.write, bits.execute]
            for (i, label) in labels.enumerated() {
                let allow = SheetCheckbox("")
                allow.state = values[i] ? .on : .off
                allow.isEnabled = canEdit
                allow.setAccessibilityLabel("Allow \(label)")
                allow.onChange = { [weak self] box in self?.setBit(role: role, index: i, on: box.state == .on) }
                let deny = SheetCheckbox("")
                deny.isEnabled = false
                deny.setAccessibilityLabel("Deny \(label) (POSIX permissions have no Deny)")
                deny.toolTip = "POSIX permissions have no Deny. Use an access-list entry to deny access."
                gridRow(label, allow, deny)
            }
            modeLabel.stringValue = "Mode: \(editedPermissions.octal) (\(editedPermissions.symbolic)) · \(bits.summary(isFolder: security.isFolder))"
        case .acl(let entry):
            for permission in entry.permissions {
                let allow = SheetCheckbox("")
                allow.state = entry.allow ? .on : .off
                allow.isEnabled = false
                let deny = SheetCheckbox("")
                deny.state = entry.allow ? .off : .on
                deny.isEnabled = false
                gridRow(ACLEntry.permissionLabels[permission] ?? permission, allow, deny)
            }
            modeLabel.stringValue = entry.flags.isEmpty ? "Access-list entry" : "Access-list entry · \(entry.flags.joined(separator: ", "))"
        }
    }

    @discardableResult
    private func gridRow(_ label: String, _ allow: SheetCheckbox, _ deny: SheetCheckbox) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let l = SheetLabel.make(label)
        for v in [l, allow, deny] as [NSView] { row.addSubview(v) }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
            l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            l.trailingAnchor.constraint(lessThanOrEqualTo: allow.leadingAnchor, constant: -8),
            allow.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: -78),
            allow.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            deny.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            deny.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.widthAnchor.constraint(equalToConstant: 330).withPriority(.defaultLow).isActive = true
        grid.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        return row
    }

    private func setBit(role: PosixPermissions.Role, index: Int, on: Bool) {
        var p = editedPermissions
        var bits = p[role]
        switch index {
        case 0: bits.read = on
        case 1: bits.write = on
        default: bits.execute = on
        }
        p[role] = bits
        model.edit { edited, _ in edited.mode = p.mode }
    }

    var debugText: String {
        guard let security else { return "security: (loading)" }
        let access = security.access.lines(isFolder: security.isFolder).map { "\($0.label)=\($0.allowed ? "yes" : "no")" }
        return ["object: \(objectName.stringValue)",
                "names: \(principals.map(\.title).joined(separator: " | "))",
                "selected: \(principals.indices.contains(selected) ? principals[selected].title : "-")",
                "mode: \(modeLabel.stringValue)",
                "access: \(access.joined(separator: ", "))",
                "editable: \(security.currentUserCanChangePermissions)"].joined(separator: "\n")
    }

    private func openEditor() {
        guard let url = model.single?.url, let window = view.window else { return }
        PermissionsEditorSheet.show(for: url, over: window) { [weak self] in self?.load() }
    }

    func selectPrincipal(_ index: Int) {
        selected = index
        rebuild()
    }
}
