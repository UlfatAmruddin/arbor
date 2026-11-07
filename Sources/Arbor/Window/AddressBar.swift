import AppKit
import ArborCore

/// Explorer address bar (FE-003, FE-004, FE-005): location icon, breadcrumb segments separated by
/// ">" chevrons that list subfolders, a "«" menu for collapsed ancestors, and Refresh at the right end.
/// Click empty space or press ⌘L to type a path; Return resolves, Escape restores.
final class AddressBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((Location) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onRefresh: (() -> Void)?

    private let iconView = NSImageView()
    private let field = NSTextField()
    let refreshButton = ChromeButton(symbol: "arrow.clockwise", tooltip: "Refresh (⌘R or F5)")
    private let overflowButton = ChromeButton(symbol: "chevron.left.2", tooltip: "Show the rest of the path")
    private let rootChevron = ChromeButton(symbol: "chevron.right", tooltip: "Show places")
    private var segmentButtons: [ChromeButton] = []
    private var chevronButtons: [ChromeButton] = []
    private var crumbs: [Crumb] = []
    private var hiddenCount = 0
    private(set) var isEditingPath = false

    var location: Location = .home {
        didSet {
            guard location != oldValue || crumbs.isEmpty else { return }
            rebuildCrumbs()
            if !isEditingPath { field.stringValue = editText }
            setAccessibilityValue(editText)
        }
    }

    /// What the field shows when editing: the path for folders, otherwise the place's name.
    var editText: String {
        if let custom = Self.editTextProviders.lazy.compactMap({ $0(self.location) }).first { return custom }
        return location.folderURL?.path ?? LocationRegistry.provider(for: location).title(for: location)
    }
    /// Features may supply the editable text for their locations (e.g. `\\server\share`).
    static var editTextProviders: [(Location) -> String?] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Address")

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.bodyFont
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true
        field.placeholderString = "Type a path, ~/folder, or smb://server/share"
        field.setAccessibilityLabel("Address")
        addSubview(field)

        for button in [refreshButton, overflowButton, rootChevron] {
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }
        refreshButton.symbolSize = 12
        refreshButton.fixedWidth = 30
        refreshButton.fixedHeight = 26
        refreshButton.onClick = { [weak self] _ in self?.onRefresh?() }
        refreshButton.setAccessibilityLabel("Refresh")
        overflowButton.symbolSize = 9
        overflowButton.fixedWidth = 22
        overflowButton.fixedHeight = 24
        overflowButton.onPress = { [weak self] button in self?.showOverflowMenu(button) }
        overflowButton.setAccessibilityLabel("Collapsed folders")
        configureChevron(rootChevron)
        rootChevron.onPress = { [weak self] button in self?.showMenu(Breadcrumbs.rootChildren(), current: self?.crumbs.first?.location, from: button) }
        heightAnchor.constraint(equalToConstant: Theme.fieldHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func configureChevron(_ b: ChromeButton) {
        b.translatesAutoresizingMaskIntoConstraints = true
        b.symbolSize = 8
        b.fixedWidth = 18
        b.fixedHeight = 24
        b.symbolTint = Theme.secondaryText
    }

    // MARK: Crumbs

    private func rebuildCrumbs() {
        segmentButtons.forEach { $0.removeFromSuperview() }
        chevronButtons.forEach { $0.removeFromSuperview() }
        crumbs = Breadcrumbs.crumbs(for: location)
        iconView.image = LocationRegistry.provider(for: location).icon(for: location, size: 16)
        segmentButtons = crumbs.enumerated().map { index, crumb in
            let b = ChromeButton(title: crumb.title)
            b.translatesAutoresizingMaskIntoConstraints = true
            b.fixedHeight = 24
            b.horizontalPadding = 6
            b.toolTip = crumb.location.folderURL?.path ?? crumb.title
            b.onClick = { [weak self] _ in self?.onNavigate?(crumb.location) }
            b.setAccessibilityLabel(crumb.title)
            addSubview(b)
            return b
        }
        chevronButtons = crumbs.enumerated().map { index, crumb in
            let b = ChromeButton(symbol: "chevron.right", tooltip: "Folders in \(crumb.title)")
            configureChevron(b)
            let next = index + 1 < crumbs.count ? crumbs[index + 1].location : nil
            b.onPress = { [weak self] button in self?.showMenu(crumb.children(), current: next, from: button) }
            b.setAccessibilityLabel("Folders in \(crumb.title)")
            addSubview(b)
            return b
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        refreshButton.frame = NSRect(x: bounds.width - 32, y: (h - 26) / 2, width: 30, height: 26)
        field.frame = NSRect(x: 30, y: (h - 20) / 2, width: max(0, bounds.width - 30 - 36), height: 20)
        let hidden = isEditingPath
        let right = refreshButton.frame.minX - 4
        var x: CGFloat = 28
        // Decide how many leading segments collapse into «.
        let widths = segmentButtons.map { $0.intrinsicContentSize.width + 18 }
        var start = 0
        let overflowWidth: CGFloat = 22
        func total(from s: Int) -> CGFloat { widths[s...].reduce(0, +) + (s > 0 ? overflowWidth : 18) }
        while start < widths.count - 1, x + total(from: start) > right { start += 1 }
        hiddenCount = start
        overflowButton.isHidden = hidden || start == 0
        rootChevron.isHidden = hidden || start > 0
        if start > 0 {
            overflowButton.frame = NSRect(x: x, y: (h - 24) / 2, width: overflowWidth, height: 24)
            x += overflowWidth
        } else {
            rootChevron.frame = NSRect(x: x, y: (h - 24) / 2, width: 18, height: 24)
            x += 18
        }
        for i in segmentButtons.indices {
            let visible = !hidden && i >= start
            segmentButtons[i].isHidden = !visible
            chevronButtons[i].isHidden = !visible
            guard visible else { continue }
            let w = min(segmentButtons[i].intrinsicContentSize.width, max(40, right - x - 18))
            segmentButtons[i].frame = NSRect(x: x, y: (h - 24) / 2, width: w, height: 24)
            x += w
            chevronButtons[i].frame = NSRect(x: x, y: (h - 24) / 2, width: 18, height: 24)
            x += 18
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        fillRounded(rect, radius: Theme.cornerRadius, Theme.fieldBackground)
        Theme.fieldBorder.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        border.lineWidth = 1
        border.stroke()
        if isEditingPath {
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: bounds.maxY - 2, width: bounds.width - 2, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }

    // MARK: Menus

    private func showMenu(_ children: [CrumbChild], current: Location?, from button: ChromeButton) {
        let menu = NSMenu()
        if children.isEmpty {
            let empty = NSMenuItem(title: "No folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for child in children {
            let item = ClosureMenuItem(child.title, image: child.icon) { [weak self] in self?.onNavigate?(child.location) }
            if child.location == current {
                item.attributedTitle = NSAttributedString(string: child.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            }
            menu.addItem(item)
        }
        let original = button.symbolName
        button.symbolName = "chevron.down"
        button.popUp(menu)
        button.symbolName = original
    }

    private func showOverflowMenu(_ button: ChromeButton) {
        // Deepest collapsed ancestor first, like Explorer.
        let hidden = crumbs.prefix(hiddenCount).reversed().map {
            CrumbChild(title: $0.title, location: $0.location, icon: LocationRegistry.provider(for: $0.location).icon(for: $0.location, size: 16))
        }
        showMenu(Array(hidden), current: nil, from: button)
    }

    /// Visible segments, collapsed segments and each chevron's entries, for scripted checks.
    func debugDescription(includeMenus: Bool) -> String {
        layoutSubtreeIfNeeded()
        var lines = ["segments: " + crumbs.map(\.title).joined(separator: " > "),
                     "collapsed: \(hiddenCount)" + (hiddenCount > 0 ? " (" + crumbs.prefix(hiddenCount).map(\.title).joined(separator: ", ") + ")" : "")]
        if includeMenus {
            lines.append("root menu: " + Breadcrumbs.rootChildren().map(\.title).joined(separator: ", "))
            for crumb in crumbs {
                lines.append("menu \(crumb.title): " + crumb.children().map(\.title).joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Editing

    override func mouseDown(with event: NSEvent) { beginEditing() }

    func beginEditing(text: String? = nil) {
        isEditingPath = true
        field.isHidden = false
        field.stringValue = text ?? editText
        field.textColor = Theme.primaryText
        needsLayout = true
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard isEditingPath else { return }
        isEditingPath = false
        field.isHidden = true
        field.stringValue = editText
        needsLayout = true
        needsDisplay = true
    }

    /// Keeps the typed text editable and marks it invalid.
    func showInvalid() {
        field.textColor = .systemRed
        window?.makeFirstResponder(field)
        NSSound.beep()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) { field.textColor = Theme.primaryText }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Leaving the field without pressing Return abandons the edit.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditingPath, self.window?.firstResponder !== self.field.currentEditor() else { return }
            self.endEditing()
        }
    }
}
