import AppKit
import ArborCore

/// App-wide keyboard handling that no single view owns (FE-062, FE-066–FE-068, FE-199, FE-061):
///
/// | Keys | Does |
/// |---|---|
/// | F6 / ⇧F6 | Next / previous region (tabs, address, search, command bar, navigation pane, items, side pane) |
/// | ⇥ / ⇧⇥ | Same, but stops at each section of a page or pane first |
/// | ← → Home End | Move between tabs, or between command bar buttons, while one has focus |
/// | Space / Return / ↓ | Press the focused button (↓ opens a drop-down) |
/// | ⇧F10, Menu key | Context menu for the focused item(s), tree node or tab |
/// | Esc | From the command bar or tabs: back to the items. After leaving the address/search box: focus returns to the items |
/// | ⌥⌘ arrows | Icon layouts: move the focus without changing the selection (Explorer's Ctrl+arrows) |
/// | ⌥Space | Icon layouts: select or deselect the focused item (Explorer's Ctrl+Space) |
/// | * + − | Navigation pane: expand everything under the node / expand / collapse |
///
/// While an input method has marked (uncommitted) text, every key without ⌘ goes straight to it, so
/// window shortcuts (⌃Tab, F-keys, ⌥ letters) never steal composition keystrokes (FE-068).
enum KeyboardRouter {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in handle(event) ? nil : event }
    }

    /// Returns true when the event was consumed.
    static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])

        // FE-068: composition owns the keyboard.
        if !mods.contains(.command), let client = window.firstResponder as? (NSResponder & NSTextInputClient), client.hasMarkedText() {
            client.keyDown(with: event)
            return true
        }

        guard let c = window.windowController as? BrowserWindowController, window.attachedSheet == nil, !c.tabs.isEmpty else { return false }
        let focused = FocusRegions.focusedView(in: window)
        let editingText = window.firstResponder is NSTextView

        switch event.keyCode {
        case 97 where mods.subtracting(.shift).isEmpty:   // F6, ⇧F6
            FocusRegions.cycle(c, forward: !mods.contains(.shift))
            return true
        case 48 where mods.subtracting(.shift).isEmpty:   // Tab, ⇧Tab
            // Inline rename and other text fields inside the list keep their own Tab behavior.
            if editingText, !(focused?.isDescendant(of: c.navBar) ?? false) { return false }
            guard FocusRegions.current(in: c) != nil || window.firstResponder === window else { return false }
            FocusRegions.tab(c, forward: !mods.contains(.shift))
            return true
        case 109 where mods == .shift, 110 where mods.isEmpty:   // ⇧F10, Menu (PC keyboards)
            if editingText { return false }
            return ContextMenuKey.show(in: c)
        case 53 where mods.isEmpty:   // Escape
            return escape(c, focused: focused, editingText: editingText)
        default:
            break
        }

        if let tab = focused as? TabItemView { return tabStripKey(event, tab: tab, c: c, mods: mods) }
        if let button = focused as? ChromeButton { return buttonKey(event, button: button, c: c, mods: mods) }
        if let grid = focused as? ItemGridView { return gridKey(event, grid: grid, mods: mods) }
        if let outline = focused as? NavOutlineView { return TreeKeys.handle(event, outline: outline, c: c, mods: mods) }
        return false
    }

    // MARK: Escape

    private static func escape(_ c: BrowserWindowController, focused: NSView?, editingText: Bool) -> Bool {
        guard let window = c.window else { return false }
        if focused is ChromeButton || focused is TabItemView {
            FocusRegions.focus(.items, in: c)
            return true
        }
        if editingText, let region = FocusRegions.region(of: focused, in: c), region == .address || region == .search {
            // The field handles Escape first (restore the path / clear the search); if that left focus
            // nowhere, it goes back to the items, like Explorer.
            DispatchQueue.main.async { [weak c] in
                guard let c, window.firstResponder === window else { return }
                FocusRegions.focus(.items, in: c)
            }
        }
        return false
    }

    // MARK: Tab strip and buttons

    private static func tabStripKey(_ event: NSEvent, tab: TabItemView, c: BrowserWindowController, mods: NSEvent.ModifierFlags) -> Bool {
        guard mods.subtracting(.shift).isEmpty else { return false }
        switch event.keyCode {
        case 123, 124, 115, 119: return FocusRegions.moveWithinToolbar(c, keyCode: event.keyCode)
        case 36, 76, 49:   // Return, Enter, Space: show the tab and go to its items
            c.selectTab(at: tab.index)
            FocusRegions.focus(.items, in: c)
            return true
        case 51, 117:   // Delete closes the focused tab (Explorer: Ctrl+W; Delete on a focused tab)
            let index = tab.index
            c.closeTab(at: index)
            if let next = FocusRegions.tabViews(in: c).first(where: \.isSelected) { FocusRegions.makeFocused(next, in: c.window) }
            return true
        default:
            return false
        }
    }

    private static func buttonKey(_ event: NSEvent, button: ChromeButton, c: BrowserWindowController, mods: NSEvent.ModifierFlags) -> Bool {
        guard mods.subtracting(.shift).isEmpty else { return false }
        switch event.keyCode {
        case 123, 124, 115, 119:
            return FocusRegions.moveWithinToolbar(c, keyCode: event.keyCode)
        case 36, 76, 49:   // Return, Enter, Space
            button.performClick()
            return true
        case 125 where button.onPress != nil:   // ↓ opens a drop-down
            button.performClick()
            return true
        default:
            return false
        }
    }

    // MARK: Icon layouts: Explorer's Ctrl+arrow / Ctrl+Space without macOS's Control shortcuts

    /// ⌃←/→ switch Spaces and ⌃Space switches input sources on a Mac, so the icon layouts take ⌥⌘arrows
    /// (move focus only) and ⌥Space (toggle the focused item) as well (DEC-accessibility-3). They are
    /// delivered to the grid as the Control versions it already understands.
    private static func gridKey(_ event: NSEvent, grid: ItemGridView, mods: NSEvent.ModifierFlags) -> Bool {
        let arrow = [123, 124, 125, 126, 115, 119, 116, 121].contains(Int(event.keyCode))
        let focusMove = arrow && mods.contains([.option, .command]) && !mods.contains(.control)
        let toggle = event.keyCode == 49 && mods == .option
        guard focusMove || toggle else { return false }
        let translated: NSEvent.ModifierFlags = toggle ? .control : mods.subtracting([.option, .command]).union(.control)
        guard let copy = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: translated,
                                          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                          characters: event.charactersIgnoringModifiers ?? "",
                                          charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                          isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        grid.keyDown(with: copy)
        ItemGridAccessibility.focusChanged(grid)
        return true
    }
}

// MARK: - Context menu key (⇧F10 / Menu)

enum ContextMenuKey {
    /// Shows menus; scripted runs record them instead (a menu blocks the run loop while it is open).
    static var present: (NSMenu, NSView, NSPoint) -> Void = { menu, view, point in
        if ProcessInfo.processInfo.environment["ARBOR_SCRIPT"] != nil {
            lastShown = (menu.items.filter { !$0.isSeparatorItem }.map(\.title), String(describing: type(of: view)), point)
            return
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// The last menu a scripted run asked for: titles, anchor view class, point.
    static var lastShown: (titles: [String], view: String, point: NSPoint)?

    static func show(in c: BrowserWindowController) -> Bool {
        guard let window = c.window, let focused = FocusRegions.focusedView(in: window) else { return false }
        switch FocusRegions.region(of: focused, in: c) {
        case .items?:
            if let table = focused as? NSTableView, c.itemView?.focusView === table {
                let row = table.selectedRowIndexes.first ?? -1
                let rect = row >= 0 ? table.rect(ofRow: row) : NSRect(x: 0, y: table.visibleRect.minY, width: 0, height: 0)
                present(c.itemViewContextMenu() ?? NSMenu(), table, NSPoint(x: rect.minX + 40, y: rect.maxY))
                return true
            }
            if let grid = focused as? ItemGridView {
                let index = grid.selection.focus.flatMap { grid.selection.selected.contains($0) ? $0 : nil } ?? grid.selection.selected.first
                let rect = index.map { grid.geometry($0).highlight } ?? NSRect(origin: grid.visibleRect.origin, size: .zero)
                present(c.itemViewContextMenu() ?? NSMenu(), grid, NSPoint(x: rect.midX, y: rect.maxY))
                return true
            }
            // Pages (Home, This Mac…): the selected tiles or rows.
            let menu = c.contextMenu(for: c.selectedItems.isEmpty ? .backgroundContextMenu : .itemContextMenu)
            present(menu, focused, NSPoint(x: focused.bounds.midX, y: focused.bounds.midY))
            return true
        case .navigationPane?:
            let outline = c.navPane.outline
            guard outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? NavNode,
                  let menu = c.navigationPaneMenu(for: node) else { NSSound.beep(); return true }
            let rect = outline.rect(ofRow: outline.selectedRow)
            present(menu, outline, NSPoint(x: rect.minX + 40, y: rect.maxY))
            return true
        case .tabs?:
            guard let tab = focused as? TabItemView, let menu = c.tabStripMenu(for: tab.index) else { return false }
            present(menu, tab, NSPoint(x: 12, y: tab.bounds.maxY))
            return true
        default:
            return false
        }
    }
}

// MARK: - Navigation pane keys (FE-061)

enum TreeKeys {
    static func handle(_ event: NSEvent, outline: NavOutlineView, c: BrowserWindowController, mods: NSEvent.ModifierFlags) -> Bool {
        guard mods.subtracting(.shift).isEmpty, let chars = event.charactersIgnoringModifiers ?? event.characters,
              ["*", "+", "-"].contains(chars) || [67, 69, 78].contains(Int(event.keyCode)) else { return false }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) else { NSSound.beep(); return true }
        let key = event.keyCode == 67 ? "*" : event.keyCode == 69 ? "+" : event.keyCode == 78 ? "-" : chars
        switch key {
        case "*":
            expandAll(node, in: outline, c: c)
        case "+":
            if outline.isExpandable(node) { outline.expandItem(node) } else { NSSound.beep() }
        default:
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { NSSound.beep() }
        }
        return true
    }

    /// Expands the node and the folders under it, breadth-first, within `TreeExpansion`'s bounds.
    static func expandAll(_ node: Any, in outline: NSOutlineView, c: BrowserWindowController) {
        let plan = TreeExpansion.plan(root: node as AnyObject) { item in
            guard outline.isExpandable(item) else { return [] }
            outline.expandItem(item)
            let count = outline.numberOfChildren(ofItem: item)
            return (0..<count).compactMap { outline.child($0, ofItem: item) as AnyObject? }
        }
        if plan.truncated {
            c.statusBar.setMessage(L10n.format("Expanded %@ folders. Expand deeper folders one at a time.", StatusText.number(plan.nodes.count)))
        }
    }
}
