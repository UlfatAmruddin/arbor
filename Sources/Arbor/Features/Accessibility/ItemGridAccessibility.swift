import AppKit
import ObjectiveC
import ArborCore

/// VoiceOver for the grid layouts (FE-200): each drawn item is a lazily created, cached virtual cell.
/// Over `allLimit` items, only visible ones plus the focused one are exposed (spec §15.3).
enum ItemGridAccessibility {
    static let allLimit = 2000
    private static var cacheKey = 0

    final class Cache {
        var elements: [URL: GridItemElement] = [:]
    }

    static func cache(of grid: ItemGridView) -> Cache {
        if let existing = objc_getAssociatedObject(grid, &cacheKey) as? Cache { return existing }
        let cache = Cache()
        objc_setAssociatedObject(grid, &cacheKey, cache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return cache
    }

    static func element(_ grid: ItemGridView, index: Int) -> GridItemElement? {
        guard index >= 0, index < grid.items.count else { return nil }
        let cache = cache(of: grid)
        let url = grid.items[index].url
        if cache.elements.count > allLimit * 2 { cache.elements.removeAll() }
        let element = cache.elements[url] ?? GridItemElement(grid: grid, url: url)
        element.index = index
        cache.elements[url] = element
        return element
    }

    /// The indexes exposed to assistive apps.
    static func exposedIndexes(_ grid: ItemGridView) -> [Int] {
        let count = grid.items.count
        if count <= allLimit { return Array(0..<count) }
        var set = Set(grid.visibleIndexes)
        if let focus = grid.selection.focus { set.insert(focus) }
        return set.sorted()
    }

    static func children(_ grid: ItemGridView) -> [Any] {
        exposedIndexes(grid).compactMap { element(grid, index: $0) }
    }

    static func selectedChildren(_ grid: ItemGridView) -> [Any] {
        grid.selection.selected.prefix(allLimit).compactMap { element(grid, index: $0) }
    }

    static func focused(_ grid: ItemGridView) -> GridItemElement? {
        guard let focus = grid.selection.focus ?? grid.selection.selected.first else { return nil }
        return element(grid, index: focus)
    }

    /// Selection changed (any input): tell assistive apps, and move their focus to the focused item.
    static func selectionChanged(_ grid: ItemGridView) {
        NSAccessibility.post(element: grid, notification: .selectedChildrenChanged)
        focusChanged(grid)
    }

    static func focusChanged(_ grid: ItemGridView) {
        guard grid.window?.firstResponder === grid, let element = focused(grid) else { return }
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
    }

    /// One line per exposed item for `axdump`.
    static func describe(_ element: GridItemElement) -> String {
        "\(element.accessibilityRoleDescription() ?? "") selected=\(element.isAccessibilitySelected()) focused=\(element.isAccessibilityFocused())"
    }
}

/// One item of an `ItemGridView`.
final class GridItemElement: NSAccessibilityElement {
    weak var grid: ItemGridView?
    let url: URL
    var index = 0

    init(grid: ItemGridView, url: URL) {
        self.grid = grid
        self.url = url
        super.init()
    }

    private var item: FileItem? {
        guard let grid, index < grid.items.count, grid.items[index].url == url else {
            // The list changed under us: find the item again by identity.
            guard let grid, let i = grid.items.firstIndex(where: { $0.url == url }) else { return nil }
            index = i
            return grid.items[i]
        }
        return grid.items[index]
    }

    override func accessibilityParent() -> Any? { grid }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityRoleDescription() -> String? { item?.typeDescription ?? NSAccessibility.Role.cell.description(with: nil) }
    override func accessibilityLabel() -> String? { item?.name }
    override func accessibilityHelp() -> String? { item.map { ItemGridView.infotip($0, location: grid?.location) } }
    override func accessibilityIndex() -> Int { index }

    override func accessibilityFrame() -> NSRect {
        guard let grid, item != nil, let window = grid.window else { return .zero }
        let rect = grid.geometry(index).highlight
        return window.convertToScreen(grid.convert(rect, to: nil))
    }

    override func isAccessibilitySelected() -> Bool { grid?.selection.selected.contains(index) ?? false }

    override func setAccessibilitySelected(_ selected: Bool) {
        guard let grid, item != nil else { return }
        var indexes = grid.selection.selected
        if selected { indexes.insert(index) } else { indexes.remove(index) }
        grid.setSelection(indexes)
        grid.selection.focus = index
    }

    override func isAccessibilityFocused() -> Bool {
        guard let grid else { return false }
        return grid.window?.firstResponder === grid && grid.selection.focus == index
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused, let grid, item != nil else { return }
        grid.window?.makeFirstResponder(grid)
        grid.selection.focus = index
        grid.scrollItemToVisible(index)
        grid.canvas.needsDisplay = true
    }

    /// Open, like double-click or Return.
    override func accessibilityPerformPress() -> Bool {
        guard let grid, let item else { return false }
        if !grid.selection.selected.contains(index) { grid.setSelection([index]) }
        grid.host?.gridOpen([item], inNewTab: false)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let grid, item != nil else { return false }
        if !grid.selection.selected.contains(index) { grid.setSelection([index]) }
        guard let menu = grid.host?.gridContextMenu() else { return false }
        let rect = grid.geometry(index).highlight
        ContextMenuKey.present(menu, grid, NSPoint(x: rect.midX, y: rect.maxY))
        return true
    }
}

extension ItemGridView {
    override func isAccessibilityElement() -> Bool { true }
    override var accessibilityFocusedUIElement: Any? {
        guard window?.firstResponder === self else { return super.accessibilityFocusedUIElement }
        return ItemGridAccessibility.focused(self) ?? self
    }
    override func accessibilityVisibleChildren() -> [Any]? {
        visibleIndexes.compactMap { ItemGridAccessibility.element(self, index: $0) }
    }
    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        mode == .list ? .horizontal : .vertical
    }
    override func accessibilityLabel() -> String? {
        L10n.format("Items, %@", StatusText.items(items.count))
    }
}
