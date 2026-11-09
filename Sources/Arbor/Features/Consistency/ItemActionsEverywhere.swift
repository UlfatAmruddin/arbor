import AppKit
import ArborCore

/// Item actions and Folder Options click behaviors in every layout and page, not just Details.
enum ItemActionsEverywhere {
    private static var monitors: [Any] = []
    private static let hover = PageHoverTracker()

    static func register() {
        InteractionHooks.rightDrag.register("consistency.right-drag-in-icon-views", handles: { view, event, urls in
            rightDrag(view, event, urls)
        })
        TileView.showsDescriptions.provide("consistency.popup-descriptions") { Prefs.showPopupDescriptions }
        GalleryGridView.showsDescriptions.provide("consistency.popup-descriptions") { Prefs.showPopupDescriptions }
        WindowHooks.didCreate.observe("consistency.page-hover") { window in window.window?.acceptsMouseMovedEvents = true }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in pageMouseDown(event) } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            hover.moved(event)
            return event
        } as Any)
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            guard let key = note.userInfo?["key"] as? String, ["clickItems", "underlineTitles", "showPopupDescriptions"].contains(key) else { return }
            for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] { refreshPage(controller) }
        }
    }

    /// Re-applies descriptions and underlines on the page shown (after a Folder Options change).
    static func refreshPage(_ controller: BrowserWindowController) {
        guard !controller.tabs.isEmpty, let view = controller.activeTab.page?.view else { return }
        func walk(_ v: NSView) {
            if let tile = v as? TileView {
                tile.refreshToolTip()
                if let field = tile.titleField { ItemClickBehavior.setUnderline(field, Prefs.singleClickToOpen && Prefs.underlineTitles == "always") }
            }
            if let table = v as? NSTableView { table.reloadData() }
            v.subviews.forEach(walk)
        }
        walk(view)
        hover.reset()
    }

    // MARK: Right-button drag in icon layouts

    /// Starts a drag once the right button moves; a plain right click still opens the context menu.
    /// The pasteboard carries DragPolish's marker so the drop shows its menu.
    static func rightDrag(_ view: NSView & NSDraggingSource, _ event: NSEvent, _ urls: @escaping () -> [URL]) -> Bool {
        guard let window = view.window else { return false }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.rightMouseDragged, .rightMouseUp]) {
            if next.type == .rightMouseUp { return false }
            let dx = next.locationInWindow.x - start.x, dy = next.locationInWindow.y - start.y
            guard dx * dx + dy * dy > 16 else { continue }
            let files = urls()
            guard !files.isEmpty else { return false }
            let point = view.convert(next.locationInWindow, from: nil)
            let items: [NSDraggingItem] = files.enumerated().map { i, url in
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                if i == 0 { pasteboardItem.setString("1", forType: DragPolish.rightDragType) }
                let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
                let offset = CGFloat(i) * 4
                dragging.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 + offset, width: 32, height: 32),
                                          contents: NSWorkspace.shared.icon(forFile: url.path))
                return dragging
            }
            view.beginDraggingSession(with: items, event: next, source: view)
            return true
        }
        return false
    }

    // MARK: Single-click to open on pages

    private static func pageMouseDown(_ event: NSEvent) -> NSEvent? {
        guard Prefs.singleClickToOpen, let window = event.window, let controller = window.windowController as? BrowserWindowController,
              !controller.tabs.isEmpty, controller.activeTab.showsPage, let surface = controller.activeTab.page as? PageItemSurface,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let slot = surface.pageSlot(at: event.locationInWindow) else { return event }
        if event.clickCount >= 2 { return nil }      // already opened by the first click
        let start = event.locationInWindow
        DispatchQueue.main.async { [weak controller] in
            guard let controller, let up = NSApp.currentEvent, up.type == .leftMouseUp,
                  hypot(up.locationInWindow.x - start.x, up.locationInWindow.y - start.y) < 5 else { return }
            surface.selectPageSlot(slot)
            controller.open([slot.item], inNewTab: false)
        }
        return event
    }

    /// Scripted checks: a plain click on a page item through the real event path.
    static func scriptClick(_ controller: BrowserWindowController, name: String) {
        guard let window = controller.window, let surface = controller.activeTab.page as? PageItemSurface,
              let point = surface.windowPoint(ofName: name) else { NSLog("DebugScript: no page item \(name)"); return }
        ScriptedMouse.postClick(in: window, at: point)
    }

    static func scriptHover(_ controller: BrowserWindowController, name: String) {
        guard let surface = controller.activeTab.page as? PageItemSurface, let point = surface.windowPoint(ofName: name) else { return }
        hover.point(at: point, in: controller)
    }

    static var debugLine: String { hover.debugLine }
}

/// One item on a page: which list it is in (tiles, Favorites, Recent, a drive group…) and its index.
struct PageSlot: Equatable {
    let section: Int
    let index: Int
    let item: FileItem
    static func == (a: PageSlot, b: PageSlot) -> Bool { a.section == b.section && a.index == b.index }
}

/// A custom page whose items follow Folder Options' click behaviors.
protocol PageItemSurface: AnyObject {
    func pageSlot(at windowPoint: NSPoint) -> PageSlot?
    func selectPageSlot(_ slot: PageSlot)
    /// The item's title field, for the hover underline (nil: the layout draws no names).
    func titleField(of slot: PageSlot) -> NSTextField?
    func windowPoint(ofName name: String) -> NSPoint?
}

/// Point to select and hover underline on pages.
final class PageHoverTracker {
    private weak var surface: AnyObject?
    private(set) var slot: PageSlot?
    private var dwell: DispatchWorkItem?

    func reset() {
        if let slot, let surface = surface as? PageItemSurface { underline(surface, slot, false) }
        slot = nil
        dwell?.cancel()
    }

    func moved(_ event: NSEvent) {
        guard let window = event.window, let controller = window.windowController as? BrowserWindowController else { return }
        point(at: event.locationInWindow, in: controller)
    }

    func point(at windowPoint: NSPoint, in controller: BrowserWindowController) {
        guard Prefs.singleClickToOpen, !controller.tabs.isEmpty, controller.activeTab.showsPage,
              let surface = controller.activeTab.page as? PageItemSurface else { if slot != nil { reset() }; return }
        let new = surface.pageSlot(at: windowPoint)
        if surface !== self.surface { reset(); self.surface = surface }
        guard new != slot else { return }
        if let old = slot { underline(surface, old, false) }
        slot = new
        if let new { underline(surface, new, true) }
        dwell?.cancel()
        guard let new else { return }
        let work = DispatchWorkItem { [weak self, weak surface] in
            guard let self, let surface, self.slot == new, NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            surface.selectPageSlot(new)
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemClickBehavior.hoverSelectDelay, execute: work)
    }

    private func underline(_ surface: PageItemSurface, _ slot: PageSlot, _ on: Bool) {
        guard let field = surface.titleField(of: slot) else { return }
        let always = Prefs.singleClickToOpen && Prefs.underlineTitles == "always"
        ItemClickBehavior.setUnderline(field, always || (on && Prefs.singleClickToOpen && Prefs.underlineTitles == "hover"))
    }

    var debugLine: String {
        guard let slot else { return "page hover: -" }
        let underlined = (surface as? PageItemSurface)?.titleField(of: slot)?.attributedStringValue.length ?? 0 > 0
            && (surface as? PageItemSurface)?.titleField(of: slot)?.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil
        return "page hover: \(slot.item.name) underlined=\(underlined)"
    }
}

// MARK: - Helpers for the shared tile grid and Home's lists

extension TileGridView {
    func tileIndex(atWindowPoint point: NSPoint) -> Int? {
        let p = convert(point, from: nil)
        return tiles.firstIndex { !$0.isHidden && $0.frame.contains(p) }
    }

    func windowPoint(ofTile index: Int) -> NSPoint? {
        guard index < tiles.count else { return nil }
        let f = tiles[index].frame
        return convert(NSPoint(x: f.midX, y: f.midY), to: nil)
    }
}

private func row(of table: NSTableView, at windowPoint: NSPoint) -> Int? {
    guard !table.isHiddenOrHasHiddenAncestor else { return nil }
    let p = table.convert(windowPoint, from: nil)
    guard table.visibleRect.contains(p) else { return nil }
    let row = table.row(at: p)
    return row >= 0 ? row : nil
}

private func nameField(of table: NSTableView, row: Int) -> NSTextField? {
    let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
    guard column >= 0 else { return nil }
    return (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField
}

// MARK: - Pages

extension ExplorerHomePage: PageItemSurface {
    private var lists: [HomeFileList] { [homeFavorites, homeRecent] }

    func pageSlot(at windowPoint: NSPoint) -> PageSlot? {
        guard isViewLoaded else { return nil }
        if !homeTiles.isHiddenOrHasHiddenAncestor, let i = homeTiles.tileIndex(atWindowPoint: windowPoint), i < snapshot.quickAccess.count {
            return PageSlot(section: 0, index: i, item: snapshot.quickAccess[i].item)
        }
        for (n, list) in lists.enumerated() {
            if let r = row(of: list.table, at: windowPoint), r < list.rows.count {
                return PageSlot(section: n + 1, index: r, item: list.rows[r].item)
            }
        }
        return nil
    }

    func selectPageSlot(_ slot: PageSlot) {
        switch slot.section {
        case 0: select(.quickAccess, names: [slot.item.name])
        case 1: select(.favorites, names: [slot.item.name])
        default: select(.recent, names: [slot.item.name])
        }
    }

    func titleField(of slot: PageSlot) -> NSTextField? {
        if slot.section == 0 { return slot.index < homeTiles.tiles.count ? homeTiles.tiles[slot.index].titleField : nil }
        let list = lists[min(slot.section - 1, 1)]
        return nameField(of: list.table, row: slot.index)
    }

    func windowPoint(ofName name: String) -> NSPoint? {
        if let i = snapshot.quickAccess.firstIndex(where: { $0.name == name }), let p = homeTiles.windowPoint(ofTile: i) { return p }
        for list in lists {
            if let r = list.rows.firstIndex(where: { $0.item.name == name }) {
                let rect = list.table.rect(ofRow: r)
                return list.table.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
            }
        }
        return nil
    }
}

extension ThisMacPage: PageItemSurface {
    func pageSlot(at windowPoint: NSPoint) -> PageSlot? {
        for (n, grid) in driveGrids.enumerated() {
            guard !grid.grid.isHiddenOrHasHiddenAncestor, let i = grid.grid.tileIndex(atWindowPoint: windowPoint), i < grid.volumes.count else { continue }
            let v = grid.volumes[i]
            return PageSlot(section: n, index: i, item: FileItem(url: v.url, name: v.name, isFolder: true, typeDescription: v.kind.typeName))
        }
        return nil
    }

    func selectPageSlot(_ slot: PageSlot) { select(names: [slot.item.name]) }

    func titleField(of slot: PageSlot) -> NSTextField? {
        let grids = driveGrids
        guard slot.section < grids.count, slot.index < grids[slot.section].grid.tiles.count else { return nil }
        return grids[slot.section].grid.tiles[slot.index].titleField
    }

    func windowPoint(ofName name: String) -> NSPoint? {
        for grid in driveGrids {
            if let i = grid.volumes.firstIndex(where: { $0.name == name }) { return grid.grid.windowPoint(ofTile: i) }
        }
        return nil
    }
}

extension GalleryPageController: PageItemSurface {
    func pageSlot(at windowPoint: NSPoint) -> PageSlot? {
        guard isViewLoaded, let hit = grid.item(atWindowPoint: windowPoint) else { return nil }
        return PageSlot(section: 0, index: hit.index, item: Self.fileItem(hit.item))
    }

    func selectPageSlot(_ slot: PageSlot) { grid.select(keys: [Location.normalizedKey(slot.item.url)]) }

    func titleField(of slot: PageSlot) -> NSTextField? { nil }   // Gallery shows no names (Explorer too)

    func windowPoint(ofName name: String) -> NSPoint? { grid.windowPoint(ofName: name) }
}
