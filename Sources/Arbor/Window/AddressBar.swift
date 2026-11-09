import AppKit
import ArborCore

/// A state of the view shown after the last crumb; it is not a place and never part of the path.
struct AddressAnnotation {
    let title: String
    let tooltip: String
    /// Built when clicked, so chrome updates stay cheap.
    let menu: () -> NSMenu
}

/// What a feature attaches to typing in the address bar. Main thread only.
protocol AddressEditingSession: AnyObject {
    /// The user changed the text; programmatic changes don't call this.
    func textDidChange()
    /// A key command from the field, before the bar handles it; true = consumed.
    func handle(_ command: Selector) -> Bool
    /// Editing started over or ended: forget the old text.
    func reset()
    /// The window moved while the text stayed, so anything derived from the old place is stale.
    func locationDidChange()
}

/// Explorer address bar (FE-003, FE-004, FE-005): breadcrumbs with subfolder chevrons and a "«" overflow menu.
/// Click empty space or ⌘L to type a path; Return resolves, Escape restores. Segments take file drops (FE-107)
/// and middle-clicks (FE-023); the bar handles both because it outlives the segment views during a drag.
final class AddressBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((Location) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenInNewTab: ((Location) -> Void)?
    var onDrop: ((TransferKind, [URL], URL) -> Void)?
    /// The focused annotation went away; focus must not stay on a hidden button.
    var onAnnotationFocusLost: (() -> Void)?
    var editingSession: AddressEditingSession?

    private let iconView = NSImageView()
    private let field = NSTextField()
    /// "▾" at the right end: recent locations.
    let recentButton = ChromeButton(symbol: "chevron.down", tooltip: "Recent locations")
    /// The recent button hides while there is no provider.
    static let recentLocations = Provided<(() -> [Location])?>(
        "AddressBar.recentLocations", "The address bar's recent locations (▾); hidden without a provider.",
        signature: "() -> [Location]", default: nil)
    /// The annotation's menu button, right after the last crumb.
    let annotationButton = ChromeButton()
    static let annotationProviders = Handlers<TabState, AddressAnnotation>(
        "AddressBar.annotationProviders", "A state of the view shown after the last crumb that is not a place (Filtered).",
        signature: "(tab) -> annotation?")
    var annotation: AddressAnnotation? {
        didSet {
            // Closures always differ; only what shows needs work (this runs on every selection change).
            guard annotation?.title != oldValue?.title || annotation?.tooltip != oldValue?.tooltip else { return }
            annotationButton.title = annotation?.title ?? ""
            annotationButton.toolTip = annotation?.tooltip
            annotationButton.setAccessibilityLabel(annotation?.tooltip)
            needsLayout = true
            if annotation == nil, window?.firstResponder === annotationButton { onAnnotationFocusLost?() }
        }
    }
    private let overflowButton = ChromeButton(symbol: "chevron.left.2", tooltip: "Show the rest of the path")
    private let rootChevron = ChromeButton(symbol: "chevron.right", tooltip: "Show places")
    private var segmentButtons: [ChromeButton] = []
    private var chevronButtons: [ChromeButton] = []
    private var crumbs: [Crumb] = []
    private var hiddenCount = 0
    private(set) var isEditingPath = false
    /// The highlight and the destination in one value, so a drop can only go where the highlight is.
    private var dropTarget: (button: ChromeButton, folder: URL)? {
        didSet {
            guard oldValue?.button !== dropTarget?.button else { return }
            oldValue?.button.isDropTarget = false
            dropTarget?.button.isDropTarget = true
        }
    }
    /// A spring reflows a collapsed path under the resting pointer; one per visit stops it climbing on its own.
    private var hasSprung = false
    /// AppKit asks on every periodic update and the rules read every source, so the last answer is reused while its key holds.
    private var hoverAnswer: (folder: URL, flags: NSEvent.ModifierFlags, mask: NSDragOperation, operation: NSDragOperation)?

    var location: Location = .home {
        didSet {
            guard location != oldValue || crumbs.isEmpty else { return }
            rebuildCrumbs()
            if !isEditingPath { field.stringValue = editText }
            setAccessibilityValue(editText)
            editingSession?.locationDidChange()
        }
    }

    /// Editing text: the path for folders, else the place's name.
    var editText: String {
        if let custom = Self.editTextProviders.first(location) { return custom }
        return location.folderURL?.path ?? LocationRegistry.provider(for: location).title(for: location)
    }
    /// Feature-supplied editing text (e.g. `\\server\share`).
    static let editTextProviders = Handlers<Location, String>(
        "AddressBar.editTextProviders", "The text the address field edits for a location; nil = path or title.",
        signature: "(location) -> text?")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.tr("Address"))

        iconView.imageScaling = .scaleProportionallyDown
        iconView.hideFromAccessibility()
        addSubview(iconView)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.bodyFont
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true
        field.placeholderString = L10n.tr("Type a path, ~/folder, or smb://server/share")
        field.setAccessibilityLabel(L10n.tr("Address"))
        addSubview(field)

        for button in [overflowButton, rootChevron, recentButton, annotationButton] {
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }
        annotationButton.isHidden = true
        annotationButton.fixedHeight = 24
        annotationButton.horizontalPadding = 6
        annotationButton.showsMenuIndicator = true
        annotationButton.onPress = { [weak self] button in
            if let menu = self?.annotation?.menu() { button.popUp(menu) }
        }
        recentButton.symbolSize = 9
        recentButton.fixedWidth = 26
        recentButton.fixedHeight = 24
        recentButton.symbolTint = Theme.secondaryText
        recentButton.setAccessibilityLabel(L10n.tr("Recent locations"))
        recentButton.onPress = { [weak self] button in self?.showRecentMenu(button) }
        overflowButton.symbolSize = 9
        overflowButton.fixedWidth = 22
        overflowButton.fixedHeight = 24
        overflowButton.onPress = { [weak self] button in self?.showOverflowMenu(button) }
        overflowButton.setAccessibilityLabel(L10n.tr("Collapsed folders"))
        configureChevron(rootChevron)
        rootChevron.onPress = { [weak self] button in self?.showMenu(Breadcrumbs.rootChildren(), current: self?.crumbs.first?.location, from: button) }
        heightAnchor.constraint(equalToConstant: Theme.fieldHeight).isActive = true
        registerForDraggedTypes([.fileURL] + ItemHooks.dropTypes)   // file promises, like the tree
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
        dropTarget = nil   // a drop after this is refused, never redirected to whatever is now under the pointer
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
            let b = ChromeButton(symbol: "chevron.right", tooltip: L10n.format("Folders in %@", crumb.title))
            configureChevron(b)
            let next = index + 1 < crumbs.count ? crumbs[index + 1].location : nil
            b.onPress = { [weak self] button in self?.showMenu(crumb.children(), current: next, from: button) }
            b.setAccessibilityLabel(L10n.format("Folders in %@", crumb.title))
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
        let showsRecent = Self.recentLocations.value != nil
        recentButton.isHidden = !showsRecent
        recentButton.frame = NSRect(x: bounds.width - 30, y: (h - 24) / 2, width: 26, height: 24)
        let end = showsRecent ? recentButton.frame.minX - 2 : bounds.width - 6
        field.frame = NSRect(x: 30, y: (h - 20) / 2, width: max(0, end - 30), height: 20)
        let hidden = isEditingPath
        let annotationWidth = annotation == nil ? 0 : annotationButton.intrinsicContentSize.width
        let right = end - annotationWidth
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
        annotationButton.isHidden = hidden || annotation == nil
        annotationButton.frame = NSRect(x: min(x, right), y: (h - 24) / 2, width: annotationWidth, height: 24)
        RightToLeft.mirrorBreadcrumb(self, chevrons: chevronButtons + [rootChevron])   // FE-204
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

    // MARK: Drop targets (FE-107) and middle-click (FE-023)

    /// The visible segment under a window point. Collapsed segments and chevrons never match.
    private func segment(at windowPoint: NSPoint) -> (crumb: Crumb, button: ChromeButton)? {
        guard !isEditingPath else { return nil }
        let point = convert(windowPoint, from: nil)
        guard let index = segmentButtons.firstIndex(where: { !$0.isHidden && $0.frame.contains(point) }),
              crumbs.indices.contains(index) else { return nil }
        return (crumbs[index], segmentButtons[index])
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, let hit = segment(at: event.locationInWindow) {
            onOpenInNewTab?(hit.crumb.location)
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        resetDragVisit()
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hit = segment(at: sender.draggingLocation)
        let folder = hit?.crumb.location.folderURL   // real folders only: never Home, archives, search or servers
        let operation = folder.map { dropOperation(sender, onto: $0) } ?? []
        guard let hit, let folder, !operation.isEmpty else {
            dropTarget = nil
            InteractionHooks.dragHover.send((nil, nil))
            return []
        }
        dropTarget = (hit.button, folder)
        if hasSprung || hit.crumb.location == location {
            InteractionHooks.dragHover.send((nil, nil))
        } else {
            InteractionHooks.dragHover.send(("crumb:" + folder.path, { [weak self] in
                self?.hasSprung = true
                self?.onNavigate?(hit.crumb.location)
            }))
        }
        return operation
    }

    private func dropOperation(_ info: NSDraggingInfo, onto folder: URL) -> NSDragOperation {
        let flags = NSEvent.modifierFlags, mask = info.draggingSourceOperationMask
        if let answer = hoverAnswer, answer.folder == folder, answer.flags == flags, answer.mask == mask { return answer.operation }
        let operation = DropPolicy.operation(info, onto: folder)
        hoverAnswer = (folder, flags, mask, operation)
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { resetDragVisit() }

    override func draggingEnded(_ sender: NSDraggingInfo) { dropTarget = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let folder = dropTarget?.folder
        resetDragVisit()
        guard let folder else { return false }
        return DropPolicy.accept(sender, onto: folder, window: window) { kind, urls, destination in
            onDrop?(kind, urls, destination)
        }
    }

    private func resetDragVisit() {
        dropTarget = nil
        hasSprung = false
        hoverAnswer = nil
        InteractionHooks.dragHover.send((nil, nil))
    }

    // MARK: Menus

    private func showMenu(_ children: [CrumbChild], current: Location?, from button: ChromeButton, emptyText: String = L10n.tr("No folders")) {
        let menu = NSMenu()
        if children.isEmpty {
            let empty = NSMenuItem(title: emptyText, action: nil, keyEquivalent: "")
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

    private func showRecentMenu(_ button: ChromeButton) {
        let recent = recentMenuEntries
        showMenu(recent, current: location, from: button, emptyText: L10n.tr("No recent locations"))
    }

    var recentMenuEntries: [CrumbChild] {
        (Self.recentLocations.value?() ?? []).map { place in
            let provider = LocationRegistry.provider(for: place)
            return CrumbChild(title: place.folderURL?.path ?? provider.title(for: place), location: place,
                              icon: provider.icon(for: place, size: 16))
        }
    }

    private func showOverflowMenu(_ button: ChromeButton) {
        // Deepest collapsed ancestor first, like Explorer.
        let hidden = crumbs.prefix(hiddenCount).reversed().map {
            CrumbChild(title: $0.title, location: $0.location, icon: LocationRegistry.provider(for: $0.location).icon(for: $0.location, size: 16))
        }
        showMenu(Array(hidden), current: nil, from: button)
    }

    /// For scripted checks.
    func debugDescription(includeMenus: Bool) -> String {
        layoutSubtreeIfNeeded()
        var lines = ["segments: " + crumbs.map(\.title).joined(separator: " > "),
                     "collapsed: \(hiddenCount)" + (hiddenCount > 0 ? " (" + crumbs.prefix(hiddenCount).map(\.title).joined(separator: ", ") + ")" : "")]
        if let dropTarget { lines.append("drop target: " + dropTarget.button.title) }
        if let annotation { lines.append("annotation: \(annotation.title)") }
        if includeMenus {
            lines.append("root menu: " + Breadcrumbs.rootChildren().map(\.title).joined(separator: ", "))
            for crumb in crumbs {
                lines.append("menu \(crumb.title): " + crumb.children().map(\.title).joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Visible segment titles as they sit on screen, so a check can see whether the bar mirrored.
    func debugTitlesLeftToRight() -> [String] {
        layoutSubtreeIfNeeded()
        return segmentButtons.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }.map(\.title)
    }

    /// Window point of a segment, of "chevron:<title>", or of the location icon for anything else; for scripted checks.
    func debugPoint(_ target: String) -> NSPoint {
        layoutSubtreeIfNeeded()
        let title = target.hasPrefix("chevron:") ? String(target.dropFirst("chevron:".count)) : target
        let buttons = target.hasPrefix("chevron:") ? chevronButtons : segmentButtons
        let frame = crumbs.firstIndex { $0.title == title }.map { buttons[$0].frame } ?? iconView.frame
        return convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    // MARK: Editing

    override func mouseDown(with event: NSEvent) { beginEditing() }

    /// The field editor while a path is being typed. Nil once the shared editor may belong to another field.
    var activeEditor: NSTextView? { isEditingPath ? field.currentEditor() as? NSTextView : nil }

    func beginEditing(text: String? = nil) {
        editingSession?.reset()
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
        editingSession?.reset()
        isEditingPath = false
        field.isHidden = true
        field.stringValue = editText
        needsLayout = true
        needsDisplay = true
    }

    /// Leaves the path field and returns the annotation's button, laid out and visible, ready for focus.
    func revealAnnotationButton() -> ChromeButton? {
        guard annotation != nil else { return nil }
        endEditing()
        layoutSubtreeIfNeeded()
        return annotationButton
    }

    /// Keeps the typed text editable and marks it invalid.
    func showInvalid() {
        field.textColor = .systemRed
        window?.makeFirstResponder(field)
        NSSound.beep()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if editingSession?.handle(selector) == true { return true }
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

    func controlTextDidChange(_ obj: Notification) {
        field.textColor = Theme.primaryText
        editingSession?.textDidChange()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Leaving the field without pressing Return abandons the edit.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditingPath, self.window?.firstResponder !== self.field.currentEditor() else { return }
            self.endEditing()
        }
    }
}
