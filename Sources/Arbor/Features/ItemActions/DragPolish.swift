import AppKit
import ArborCore

/// Drag and drop polish (FE-106, FE-108, FE-109, FE-111): right-drag drop menu, ⌥⌘-drop for aliases,
/// spring-loading (~0.7 s) on folders, tree nodes, breadcrumbs and tabs, drops to the shown folder (never a stale
/// selection), and overlapping sources handled once.
enum DragPolish {
    static let rightDragType = NSPasteboard.PasteboardType("io.github.arbor-files.right-drag")

    private static var tracker = SpringLoadTracker(delay: 0.7, staleAfter: 1.0)
    private static var activation: (() -> Void)?
    private static var timer: Timer?
    /// Headless runs never show menus; the drop menu waits here for a script step.
    static var pendingMenu: NSMenu?
    /// The last spring-loaded activation, for scripted checks.
    static var lastSpring: String?

    static func install() {
        InteractionHooks.dragHover.observe("item-actions.spring-loading") { key, activate in hover(key, activate) }
        InteractionHooks.drop.register("item-actions.drop-polish", handles: { window, kind, urls, destination in
            drop(window, kind, urls, destination)
        })
        InteractionHooks.rightMouseDown.register("item-actions.right-drag", handles: { table, event in rightMouseDown(table, event) })
    }

    /// Drag pasteboard; headless runs use a private one so tests never touch the system's.
    static var dragPasteboard: NSPasteboard {
        AppDelegate.isHeadless ? NSPasteboard(name: NSPasteboard.Name("io.github.arbor-files.test-drag.\(getpid())"))
                               : NSPasteboard(name: .drag)
    }

    // MARK: Spring-loading

    static func hover(_ key: String?, _ activate: (() -> Void)?) {
        let now = ProcessInfo.processInfo.systemUptime
        if tracker.hover(key, now: now) {
            activation = activate
            timer?.invalidate()
            // Common modes: the run loop is in event-tracking mode during a drag.
            let t = Timer(timeInterval: tracker.delay, repeats: false) { _ in fire() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if key == nil {
            cancelSpring()
        } else if activate != nil {
            activation = activate
        }
    }

    static func cancelSpring() {
        tracker.cancel()
        timer?.invalidate()
        timer = nil
        activation = nil
    }

    private static func fire() {
        guard let key = tracker.due(now: ProcessInfo.processInfo.systemUptime) else { return }
        let action = activation
        activation = nil
        lastSpring = key
        action?()
    }

    // MARK: Drops

    static func drop(_ window: BrowserWindowController, _ kind: TransferKind, _ urls: [URL], _ destination: URL) -> Bool {
        cancelSpring()
        let sources = DragSources.deduplicated(urls)
        if dragPasteboard.types?.contains(rightDragType) == true {
            // Let the drop finish first; the menu then runs outside the drag session.
            DispatchQueue.main.async { showDropMenu(window, suggested: kind, sources, to: destination) }
            return true
        }
        if NSEvent.modifierFlags.intersection([.option, .command, .control, .shift]) == [.option, .command] {
            createShortcuts(window, sources, in: destination)
            return true
        }
        guard sources.count != urls.count else { return false }
        window.startTransfer(kind, sources, to: destination)
        return true
    }

    static func createShortcuts(_ window: BrowserWindowController, _ sources: [URL], in destination: URL) {
        let created = Shortcuts.createShortcuts(to: sources, in: destination, window: window)
        guard !created.isEmpty else { return }
        if Location.folder(destination) == window.location {
            window.navigate(to: window.location, select: created.map(\.lastPathComponent))
        }
        window.statusBar.setMessage(created.count == 1 ? L10n.format("Created “%@”.", created[0].lastPathComponent)
                                                       : L10n.plural(one: "Created %lld shortcut in “%@”.", other: "Created %lld shortcuts in “%@”.",
                                                                     created.count, displayName(of: destination)))
    }

    /// Explorer's right-drag menu. The default (bold) item is what a plain drag would have done.
    static func showDropMenu(_ window: BrowserWindowController, suggested: TransferKind, _ sources: [URL], to destination: URL) {
        let menu = NSMenu(title: "Drop")
        menu.autoenablesItems = false
        func add(_ title: String, isDefault: Bool, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title) {
                pendingMenu = nil
                action()
            }
            if isDefault {
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            menu.addItem(item)
        }
        let sameFolder = sources.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL }
        add(L10n.tr("Copy here"), isDefault: suggested == .copy) { window.startTransfer(.copy, sources, to: destination) }
        if !sameFolder {
            add(L10n.tr("Move here"), isDefault: suggested == .move) { window.startTransfer(.move, sources, to: destination) }
        }
        add(L10n.tr("Create shortcuts here"), isDefault: false) { createShortcuts(window, sources, in: destination) }
        menu.addItem(.separator())
        add(L10n.tr("Cancel"), isDefault: false) {}
        if AppDelegate.isHeadless {
            pendingMenu = menu
            return
        }
        guard let view = window.window?.contentView, let host = window.window else { return }
        let point = view.convert(host.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: Right-button drag (Details view)

    /// Starts a drag when the right button moves a few points over a row; else the context menu shows on release.
    static func rightMouseDown(_ table: NSTableView, _ event: NSEvent) -> Bool {
        guard let window = table.window else { return false }
        let start = event.locationInWindow
        let row = table.row(at: table.convert(start, from: nil))
        guard row >= 0 else { return false }
        while let next = window.nextEvent(matching: [.rightMouseDragged, .rightMouseUp]) {
            if next.type == .rightMouseUp { return false }
            let dx = next.locationInWindow.x - start.x, dy = next.locationInWindow.y - start.y
            guard dx * dx + dy * dy > 16 else { continue }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            var items: [NSDraggingItem] = []
            for r in table.selectedRowIndexes {
                guard let url = table.dataSource?.tableView?(table, pasteboardWriterForRow: r) as? NSURL as URL? else { continue }
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                if items.isEmpty { pasteboardItem.setString("1", forType: rightDragType) }
                let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let point = table.convert(next.locationInWindow, from: nil)
                let offset = CGFloat(items.count) * 4
                dragging.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 + offset, width: 32, height: 32), contents: icon)
                items.append(dragging)
            }
            guard !items.isEmpty else { return false }
            table.beginDraggingSession(with: items, event: next, source: table)
            return true
        }
        return false
    }
}
