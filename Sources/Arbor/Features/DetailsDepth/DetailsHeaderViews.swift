import AppKit
import ArborCore

/// A group header row, Windows 11 style: chevron, "Today (3)", and a thin rule to the right edge.
final class GroupHeaderCellView: NSTableCellView {
    static let chevronWidth: CGFloat = 30
    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = Theme.secondaryText
        chevron.imageScaling = .scaleNone
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(chevron)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.chevronWidth + 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, count: Int, collapsed: Bool) {
        label.stringValue = "\(title) (\(count))"
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        setAccessibilityLabel(collapsed ? L10n.format("%@, %@, collapsed", title, StatusText.items(count))
                                        : L10n.format("%@, %@, expanded", title, StatusText.items(count)))
        setAccessibilityValue(collapsed ? 0 : 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = label.frame.maxX + 10
        let end = bounds.maxX - 10
        guard end > start else { return }
        Theme.separator.setFill()
        NSRect(x: start, y: (label.frame.midY).rounded(.down), width: end - start, height: 1).fill()
    }
}

/// Overlay on the stock header (subclassing it breaks row drawing on macOS 26): sort chevron,
/// hover filter ▾ and ✓ on filtered columns. Clicks pass through except on the ▾.
final class HeaderOverlayView: NSView {
    weak var table: NSTableView?
    var isFilterable: (Int) -> Bool = { _ in false }
    var isFiltered: (Int) -> Bool = { _ in false }
    /// Ascending/descending for the sorted column, nil for others.
    var sortState: (Int) -> Bool? = { _ in nil }
    var onDropdown: (Int) -> Void = { _ in }
    var hoverColumn = -1 { didSet { if hoverColumn != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { superview?.isFlipped ?? true }
    override var isOpaque: Bool { false }

    func columnRect(_ index: Int) -> NSRect {
        guard let header = superview as? NSTableHeaderView else { return .zero }
        return convert(header.headerRect(ofColumn: index), from: header)
    }

    /// The ▾ hit area at a column's right edge.
    func dropdownRect(_ index: Int) -> NSRect {
        let r = columnRect(index)
        return NSRect(x: r.maxX - 22, y: r.minY + 3, width: 18, height: max(0, r.height - 6))
    }

    private var columnCount: Int { table?.tableColumns.count ?? 0 }

    private func shows(_ index: Int) -> Bool { isFilterable(index) && (index == hoverColumn || isFiltered(index)) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for i in 0..<columnCount where shows(i) && dropdownRect(i).contains(p) { return self }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverColumn = (0..<columnCount).first { columnRect($0).contains(p) } ?? -1
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hoverColumn = -1 }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = (0..<columnCount).first(where: { shows($0) && dropdownRect($0).contains(p) }) { onDropdown(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = Theme.secondaryText.resolved(for: effectiveAppearance)
        for i in 0..<columnCount {
            let rect = columnRect(i)
            if rect.width < 30 { continue }
            if let ascending = sortState(i) {
                let r = NSRect(x: rect.midX - 5, y: isFlipped ? rect.minY : rect.maxY - 8, width: 10, height: 8)
                drawSymbol(ascending ? "chevron.up" : "chevron.down", in: r, size: 7, color: color)
            }
            guard isFilterable(i) else { continue }
            let box = dropdownRect(i)
            if i == hoverColumn {
                fillRounded(box, radius: 3, Theme.hover)
                drawSymbol("chevron.down", in: box, size: 9, color: color)
            } else if isFiltered(i) {
                drawSymbol("checkmark", in: box, size: 10, color: Theme.accent.resolved(for: effectiveAppearance))
            }
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)) else { return }
        let tinted = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let target = NSRect(x: rect.midX - base.size.width / 2, y: rect.midY - base.size.height / 2,
                            width: base.size.width, height: base.size.height)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A column's filter dropdown: a calendar for date columns, then a checklist of its buckets.
final class ColumnFilterViewController: NSViewController {
    let column: ColumnID
    /// (choices, checked bucket ids).
    var optionsProvider: () -> ([GroupBucket], Set<String>) = { ([], []) }
    var onToggle: (String) -> Void = { _ in }
    /// Read once, when the dropdown opens.
    var dateRangeProvider: () -> DayRange? = { nil }
    var onDateRange: (DayRange?) -> Void = { _ in }
    /// Whether the tab and folder this dropdown edits are still on screen.
    var isCurrent: () -> Bool = { true }
    private var dateView: DateRangeFilterView?
    /// The calendar, loading the view first (script steps).
    var loadedDateView: DateRangeFilterView? { _ = view; return dateView }
    private let stack = NSStackView()
    /// Rebuilt when metadata arrives; the calendar lives outside it so that can't interrupt a drag.
    private let checklist = NSStackView()
    private var reloadScheduled = false

    init(column: ColumnID) {
        self.column = column
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 16)
        stack.setAccessibilityLabel(L10n.format("Filter by %@", "\(ColumnCatalog.title(column))"))
        view = stack
        checklist.orientation = .vertical
        checklist.alignment = .leading
        checklist.spacing = 6
        if ColumnCatalog.descriptor(column)?.groupStyle == .date { addDateView() }
        stack.addArrangedSubview(checklist)
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.autorecalculatesKeyViewLoop = true   // Tab reaches the controls even after the checklist is rebuilt
    }

    private func addDateView() {
        let dateView = DateRangeFilterView(range: dateRangeProvider(), context: GroupingContext())
        dateView.onChange = { [weak self] range in self?.onDateRange(range) }
        dateView.onContentChange = { [weak self] in self?.fitContent() }
        self.dateView = dateView
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(dateView)
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: dateView.widthAnchor).isActive = true
    }

    /// Keyboard and VoiceOver users start inside the dropdown; a checkbox only takes focus with Full Keyboard Access.
    func focusFirstControl() {
        guard let window = view.window else { return }
        window.makeKey()
        window.makeFirstResponder(dateView?.firstField ?? checklist.arrangedSubviews.first)
    }

    /// One line for `log:`.
    var debugSummary: String {
        let focus = view.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        return "filter dropdown: \(column) focus=\(focus) width=\(Int(view.bounds.width)) fits=\(view.bounds.width >= stack.fittingSize.width)"
    }

    /// Titles with ✓ for checked ones (script logging).
    var debugLines: [String] {
        let (choices, checked) = optionsProvider()
        return choices.map { $0.title + (checked.contains($0.id) ? " ✓" : "") }
    }

    func reload() {
        checklist.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let (choices, checked) = optionsProvider()
        if choices.isEmpty {
            checklist.addArrangedSubview(NSTextField(labelWithString: L10n.tr("No values to filter by.")))
        }
        for bucket in choices.prefix(200) {
            let box = NSButton(checkboxWithTitle: ColumnFilterSummary.displayValue(bucket.title), target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(bucket.id)
            box.state = checked.contains(bucket.id) ? .on : .off
            box.font = Theme.bodyFont
            checklist.addArrangedSubview(box)
        }
        fitContent()
    }

    // Width only grows while open, so dragging across the calendar can't make the dropdown wobble.
    private func fitContent() {
        view.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        preferredContentSize = NSSize(width: max(180, preferredContentSize.width, fitting.width), height: fitting.height)
    }

    func reloadSoon() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reloadScheduled = false
            if self?.isViewLoaded == true { self?.reload() }
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onToggle(id)
    }
}
