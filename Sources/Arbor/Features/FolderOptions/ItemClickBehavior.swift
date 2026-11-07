import AppKit
import ArborCore

/// Folder Options behaviors in the file list (Details and the icon/list/tiles/content layouts):
/// - "Single-click to open an item (point to select)" (FE-046): pointing selects after a pause, a plain click
///   opens, ⌘/⇧-click still only select. Titles are underlined always or on hover in Details.
/// - "When typing into list view: Automatically type into the Search Box".
/// - "Show pop-up description for folder and desktop items" (infotips; the icon views read the same preference).
final class ItemClickBehavior: NSObject {
    static let shared = ItemClickBehavior()

    /// Windows' default hover time before pointing selects an item.
    static let hoverSelectDelay: TimeInterval = 0.4

    private var monitors: [Any] = []
    private let hover = HoverTracker()

    func install() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [unowned self] event in self.mouseDown(event) } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in self.keyDown(event) } as Any)
        ItemViewHooks.decorateName = { [unowned self] field, item, row, table in self.decorate(field, item, row, table) }
        ItemViewHooks.underlinesName = { [unowned self] view, slot in self.underlines(view, slot) }
        WindowHooks.didDisplay.append { [unowned self] window, _ in self.hover.attach(to: ItemSurface(window)) }
    }

    // MARK: Single-click activation

    private func mouseDown(_ event: NSEvent) -> NSEvent? {
        guard Prefs.singleClickToOpen, let window = event.window, let controller = window.windowController as? BrowserWindowController,
              let itemView = controller.itemView, !itemView.isEditingName, let surface = ItemSurface(controller),
              surface.contains(event.locationInWindow), !surface.isControl(at: event.locationInWindow),
              let slot = surface.slot(at: event.locationInWindow), let item = surface.item(at: slot),
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty else { return event }
        if event.clickCount >= 2 { return nil }      // already opened by the first click
        let start = event.locationInWindow
        // Runs after the view's own mouse tracking: open only if this was a click, not a drag.
        DispatchQueue.main.async { [weak controller] in
            guard let controller, let up = NSApp.currentEvent, up.type == .leftMouseUp,
                  hypot(up.locationInWindow.x - start.x, up.locationInWindow.y - start.y) < 5,
                  controller.itemView?.items.contains(where: { $0.url == item.url }) == true else { return }
            ItemSurface(controller)?.prepareToOpen()
            controller.itemView?.select(urls: [item.url])
            controller.open([item], inNewTab: false)
        }
        return event
    }

    // MARK: Typing into the search box

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        guard Prefs.typeIntoSearchBox, let window = event.window, let controller = window.windowController as? BrowserWindowController,
              let itemView = controller.itemView, window.firstResponder === itemView.focusView, !itemView.isEditingName,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let chars = event.characters, !chars.isEmpty, chars != " ",
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return event }
        controller.focusSearch()
        guard let editor = window.firstResponder as? NSTextView else { return event }
        editor.insertText(chars, replacementRange: editor.selectedRange())
        return nil
    }

    // MARK: Details name cells

    private func decorate(_ field: NSTextField, _ item: FileItem, _ row: Int, _ table: NSTableView) {
        // Same infotip text as the icon views (ItemGridView.infotip).
        field.toolTip = Prefs.showPopupDescriptions ? ItemGridView.infotip(item) : item.name
        let underline = Prefs.singleClickToOpen && (Prefs.underlineTitles == "always" || (hover.view === table && hover.slot == row))
        Self.setUnderline(field, underline)
    }

    /// Icon layouts: underline always, or the pointed item in hover mode (single-click only).
    func underlines(_ view: NSView, _ slot: Int) -> Bool {
        Prefs.singleClickToOpen && (Prefs.underlineTitles == "always" || (hover.view === view && hover.slot == slot))
    }

    static func setUnderline(_ field: NSTextField, _ on: Bool) {
        let text = field.stringValue
        guard on else {
            if !text.isEmpty, field.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil {
                field.stringValue = text
            }
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: field.font ?? Theme.bodyFont, .foregroundColor: field.textColor ?? Theme.primaryText,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: paragraph,
        ])
    }

    // MARK: Scripting

    /// Simulates a plain click on an item (mouse down and up) through the real event path.
    func scriptClick(_ controller: BrowserWindowController, name: String, clickCount: Int = 1) {
        guard let window = controller.window, let surface = ItemSurface(controller), let point = surface.windowPoint(of: name) else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    func scriptHover(_ controller: BrowserWindowController, name: String) {
        guard let surface = ItemSurface(controller), let point = surface.windowPoint(of: name) else { return }
        hover.attach(to: surface)
        hover.setSlot(surface.slot(at: point))
    }

    /// Posts key events as if typed while the file list has focus.
    func scriptType(_ controller: BrowserWindowController, _ text: String) {
        guard let window = controller.window else { return }
        controller.itemView?.focus()
        for ch in text {
            let s = String(ch)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                        isARepeat: false, keyCode: 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    var debugLine: String { "hover slot: \(hover.slot.map(String.init) ?? "-")" }
}

/// The item view on screen, as the click behaviors see it: Details rows (group headers excluded) or the
/// icon grid's items. A "slot" is a table row or a grid index.
struct ItemSurface {
    private enum Kind { case table(DetailsViewController), grid(ItemGridView) }
    private let kind: Kind

    init?(_ window: BrowserWindowController) {
        guard !window.tabs.isEmpty, !window.activeTab.showsPage, let itemView = window.itemView else { return nil }
        if let details = itemView as? DetailsViewController { kind = .table(details) }
        else if let grid = itemView.focusView as? ItemGridView { kind = .grid(grid) }
        else { return nil }
    }

    var view: NSView {
        switch kind {
        case .table(let d): return d.table
        case .grid(let g): return g
        }
    }

    func contains(_ windowPoint: NSPoint) -> Bool {
        let p = view.convert(windowPoint, from: nil)
        return view.visibleRect.contains(p)
    }

    /// Check boxes and text being edited keep their own click behavior.
    func isControl(at windowPoint: NSPoint) -> Bool {
        switch kind {
        case .table(let d):
            guard let superview = d.table.superview, let hit = d.table.hitTest(superview.convert(windowPoint, from: nil)) else { return true }
            return hit is NSButton || hit is NSTextView || !hit.isDescendant(of: d.table)
        case .grid(let g):
            return g.checkboxHit(g.convert(windowPoint, from: nil)) != nil
        }
    }

    func slot(at windowPoint: NSPoint) -> Int? {
        switch kind {
        case .table(let d):
            let row = d.table.row(at: d.table.convert(windowPoint, from: nil))
            return row >= 0 && d.item(atRow: row) != nil ? row : nil
        case .grid(let g):
            return g.itemHit(g.convert(windowPoint, from: nil))
        }
    }

    func item(at slot: Int) -> FileItem? {
        switch kind {
        case .table(let d): return d.item(atRow: slot)
        case .grid(let g): return slot < g.items.count ? g.items[slot] : nil
        }
    }

    /// Point to select.
    func select(_ slot: Int) {
        switch kind {
        case .table(let d):
            if d.table.selectedRowIndexes != [slot] { d.table.selectRowIndexes([slot], byExtendingSelection: false) }
        case .grid(let g):
            if g.selection.selected != [slot] { g.setSelection(IndexSet(integer: slot)) }
        }
    }

    /// Hover underline: Details name cells, or a redraw of the icon grid (it asks `underlines`).
    func setUnderline(_ slot: Int, _ on: Bool) {
        if case .grid(let g) = kind { g.canvas.needsDisplay = true; return }
        guard case .table(let d) = kind, slot < d.table.numberOfRows else { return }
        let column = d.table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, let field = (d.table.view(atColumn: column, row: slot, makeIfNecessary: false) as? NSTableCellView)?.textField else { return }
        ItemClickBehavior.setUnderline(field, on)
    }

    /// A click that opens must not also start the grid's slow-click rename.
    func prepareToOpen() {
        if case .grid(let g) = kind { g.cancelSlowRename() }
    }

    /// Window coordinates of an item's name (scripted clicks).
    func windowPoint(of name: String) -> NSPoint? {
        switch kind {
        case .table(let d):
            guard let row = (0..<d.table.numberOfRows).first(where: { d.item(atRow: $0)?.name == name }) else { return nil }
            let rect = d.table.rect(ofRow: row)
            return d.table.convert(NSPoint(x: min(rect.minX + 60, rect.maxX - 4), y: rect.midY), to: nil)
        case .grid(let g):
            guard let i = g.items.firstIndex(where: { $0.name == name }) else { return nil }
            let r = g.geometry(i).highlight
            return g.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        }
    }
}

/// Tracks the item under the pointer: underlines it (Details, hover mode) and selects it after a pause
/// (point to select). A separate tracking-area owner, so the item views need no changes.
final class HoverTracker: NSResponder {
    private(set) weak var view: NSView?
    private var surface: ItemSurface?
    private var area: NSTrackingArea?
    private(set) var slot: Int?
    private var dwell: DispatchWorkItem?

    func attach(to surface: ItemSurface?) {
        guard let surface else { return }
        let view = surface.view
        self.surface = surface
        guard view !== self.view || area.map({ !view.trackingAreas.contains($0) }) ?? true else { return }
        if let old = self.view, let area { old.removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        self.view = view
        self.area = area
        slot = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard Prefs.singleClickToOpen, let surface else { return }
        setSlot(surface.slot(at: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) { setSlot(nil) }

    func setSlot(_ newSlot: Int?) {
        guard newSlot != slot, let surface else { return }
        let old = slot
        slot = newSlot
        if Prefs.singleClickToOpen && Prefs.underlineTitles == "hover" {
            if let old { surface.setUnderline(old, false) }
            if let newSlot { surface.setUnderline(newSlot, true) }
        }
        dwell?.cancel()
        guard let newSlot, Prefs.singleClickToOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.slot == newSlot, NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty, surface.item(at: newSlot) != nil else { return }
            surface.select(newSlot)
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemClickBehavior.hoverSelectDelay, execute: work)
    }
}
