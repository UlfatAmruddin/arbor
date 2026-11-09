import AppKit
import ArborCore

/// Script steps for headless item-action checks (docs/features/item-actions.md):
///
///     sheettype:text            type into the focused field of the window's sheet (wizard, dialogs)
///     editorcmd:insertTab:      send an editing command to the focused field editor (Tab, Shift-Tab…)
///     batchset:find=IMG_        set a Batch rename option (find, replace, regex, numbering, start, …)
///     simdrop:<mode>:<row>:<a|b>  drop items from the current folder onto <row> ("-" = background)
///                               through the Details view's real drop code; mode plain | right
///     dropmenu:Copy here        choose an item in the pending right-drag menu
///     springrow:<name>          hover a simulated drag over a row (spring-loading); "-" = background
///     springtree:<row>          hover over a navigation-tree row
///     springtab:<n>             hover over tab n (1-based)
///     openitem:<name>           open an item as a double-click would
///     dragfiles:<mode>:<a|b>    put absolute paths on the drag pasteboard; mode plain | right
///     crumbhover:<target>       drag them over a breadcrumb: a segment title, chevron:<title>, - (no segment), = (same point);
///                               prefix copyonly: for a source that only allows copying, which crumbdrop keeps
///     crumbstate:/path          write the breadcrumb state and last drag result, without log:'s long pause
///     crumbleave / crumbdrop    leave the address bar, or drop at the last point
///     crumbmiddle:<n>:<target>  click mouse button n on a breadcrumb target (2 = middle)
///     treedrop:<title>          drop on a navigation-tree row
enum ItemActionsDebug {
    /// Last pointer position, source mask and result of the scripted breadcrumb drag.
    private static var crumbPoint = NSPoint.zero
    private static var crumbMask = FakeDraggingInfo.anyOperation
    private static var crumbDragActive = false
    private static var lastDrag = "none"

    static func register() {
        registerDropSteps()
        DebugScript.registerStep("sheettype") { text, window in
            guard let sheet = window?.window?.attachedSheet else { return nil }
            if let editor = sheet.firstResponder as? NSTextView {
                editor.string = text
                editor.didChangeText()
            }
            return nil
        }
        DebugScript.registerStep("sheetsnapshot") { path, window in
            // Sheets are separate windows, not in the window snapshot.
            guard let sheet = window?.window?.attachedSheet ?? NSApp.modalWindow,
                  let frame = sheet.contentView?.superview else { return nil }
            frame.layoutSubtreeIfNeeded()
            if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            return nil
        }
        DebugScript.registerStep("editorcmd") { selector, window in
            let responder = window?.window?.attachedSheet?.firstResponder ?? window?.window?.firstResponder
            (responder as? NSTextView)?.doCommand(by: Selector(selector))
            return nil
        }
        DebugScript.registerStep("batchset") { arg, _ in
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            BatchRenameDialog.current?.debugSet(parts[0], parts.count > 1 ? parts[1] : "")
            return 0.4
        }
        DebugScript.registerStep("simdrop") { arg, window in
            let parts = arg.components(separatedBy: ":")
            guard parts.count >= 3, let window, let details = window.itemView as? DetailsViewController,
                  let folder = window.location.folderURL else { return nil }
            let urls = parts[2].components(separatedBy: "|").map { folder.appendingPathComponent($0) }
            let info = FakeDraggingInfo(pasteboard: writeDragFiles(urls, right: parts[0] == "right"), window: window.window)
            let row = parts[1] == "-" ? -1 : details.items.firstIndex { $0.name == parts[1] } ?? -1
            let op = details.tableView(details.table, validateDrop: info, proposedRow: row, proposedDropOperation: row < 0 ? .above : .on)
            let accepted = op != [] && details.tableView(details.table, acceptDrop: info, row: row, dropOperation: row < 0 ? .above : .on)
            NSLog("simdrop: operation \(op.rawValue) accepted \(accepted)")
            return 1.2
        }
        DebugScript.registerStep("dropmenu") { title, _ in
            guard let menu = DragPolish.pendingMenu, let index = menu.items.firstIndex(where: { $0.title == title }) else {
                NSLog("dropmenu: no pending item \(title)")
                return nil
            }
            menu.performActionForItem(at: index)
            return 1.2
        }
        DebugScript.registerStep("springrow") { name, window in
            guard let window, let details = window.itemView as? DetailsViewController, let folder = window.location.folderURL else { return nil }
            let pasteboard = DragPolish.dragPasteboard
            pasteboard.clearContents()
            pasteboard.writeObjects([folder.appendingPathComponent("__dragged-from-elsewhere__") as NSURL])
            let info = FakeDraggingInfo(pasteboard: pasteboard, window: window.window)
            let row = name == "-" ? -1 : details.items.firstIndex { $0.name == name } ?? -1
            _ = details.tableView(details.table, validateDrop: info, proposedRow: row, proposedDropOperation: row < 0 ? .above : .on)
            return 0.2
        }
        DebugScript.registerStep("springtree") { arg, window in
            guard let window else { return nil }
            let outline = window.navPane.outline
            let row = Int(arg) ?? (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? NavNode)?.title == arg } ?? -1
            guard let node = outline.item(atRow: row) as? NavNode else { return nil }
            let info = FakeDraggingInfo(pasteboard: DragPolish.dragPasteboard, window: window.window)
            DragPolish.dragPasteboard.clearContents()
            DragPolish.dragPasteboard.writeObjects([URL(fileURLWithPath: "/tmp/arbor-elsewhere/x") as NSURL])
            _ = window.navPane.outlineView(window.navPane.outline, validateDrop: info, proposedItem: node,
                                           proposedChildIndex: NSOutlineViewDropOnItemIndex)
            return 0.2
        }
        DebugScript.registerStep("springtab") { arg, window in
            guard let window, let index = Int(arg) else { return nil }
            let strip = window.tabStrip
            let width = strip.bounds.width - strip.leadingInset - 48
            let tabWidth = min(Theme.tabMaxWidth, max(Theme.tabMinWidth, floor(width / CGFloat(max(1, strip.items.count)))))
            let x = strip.leadingInset + tabWidth * (CGFloat(index) - 0.5)
            let point = strip.convert(NSPoint(x: x, y: strip.bounds.height - Theme.tabHeight / 2), to: nil)
            let info = FakeDraggingInfo(pasteboard: DragPolish.dragPasteboard, window: window.window, location: point)
            _ = strip.draggingUpdated(info)
            return 0.2
        }
        DebugScript.registerStep("sendto") { title, window in
            guard let window else { return nil }
            let items = SendToCommands.items(window.context(surface: .itemContextMenu, sender: nil))
            guard let item = items.first(where: { $0.title == title }), let action = item.action else {
                NSLog("sendto: no destination \(title)")
                return nil
            }
            NSApp.sendAction(action, to: item.target, from: item)
            return 1.5
        }
        DebugScript.registerStep("openitem") { name, window in
            guard let window, let item = window.visibleItems.first(where: { $0.name == name }) else { return nil }
            window.open([item], inNewTab: false)
            return 1.0
        }
        DebugScript.registerLogger("item-actions.log") { _ in
            var lines: [String] = []
            if let menu = DragPolish.pendingMenu { lines.append("drop menu: " + describe(menu)) }
            lines.append("last spring: \(DragPolish.lastSpring ?? "none")")
            lines.append("last drag: \(lastDrag)")
            if let dialog = BatchRenameDialog.current { lines.append(dialog.debugSummary) }
            return lines.joined(separator: "\n")
        }
        DebugScript.registerLogger("item-actions.log-2") { window in
            let shortcuts = window.visibleItems.filter { !$0.isFolder && Shortcuts.isAlias($0.url) }.map { item -> String in
                switch Shortcuts.resolve(item.url) {
                case .target(let url, let isFolder)?: return "\(item.name) -> \(url.lastPathComponent)\(isFolder ? "/" : "")"
                case .broken(let name)?: return "\(item.name) -> (broken: \(name ?? "?"))"
                default: return item.name
                }
            }
            let sheet = window.window?.attachedSheet.map { "\($0.title)" } ?? "none"
            let editor = (window.window?.firstResponder as? NSTextView).map {
                "editing “\($0.string)” selected \(NSStringFromRange($0.selectedRange()))"
            } ?? "not editing"
            return "shortcuts: \(shortcuts.joined(separator: " | "))\nsheet title: \(sheet)\nrename field: \(editor)"
        }
    }
}

// MARK: Drops on breadcrumbs and the tree (FE-023, FE-107), through the views' real code

extension ItemActionsDebug {
    private static func registerDropSteps() {
        DebugScript.registerStep("dragfiles") { arg, _ in
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            _ = writeDragFiles(parts[1].components(separatedBy: "|").map { URL(fileURLWithPath: $0) }, right: parts[0] == "right")
            return 0.05
        }
        // log: pauses longer than the spring delay; this reads the bar while a hover is still armed.
        DebugScript.registerStep("crumbstate") { path, window in
            let order = window?.addressBar.debugTitlesLeftToRight().joined(separator: ", ") ?? ""
            let text = (window?.addressBar.debugDescription(includeMenus: false) ?? "") + "\nleft to right: \(order)\nlast drag: \(lastDrag)\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            return 0.05
        }
        DebugScript.registerStep("crumbhover") { argument, window in
            guard let window else { return nil }
            let copyOnly = argument.hasPrefix("copyonly:")
            let target = copyOnly ? String(argument.dropFirst("copyonly:".count)) : argument
            crumbMask = copyOnly ? .copy : FakeDraggingInfo.anyOperation
            if target != "=" { crumbPoint = window.addressBar.debugPoint(target) }
            let info = crumbInfo(window)
            let operation = crumbDragActive ? window.addressBar.draggingUpdated(info) : window.addressBar.draggingEntered(info)
            crumbDragActive = true
            lastDrag = "operation \(operation.rawValue)"
            return 0.2
        }
        DebugScript.registerStep("crumbleave") { _, window in
            window?.addressBar.draggingExited(nil)
            crumbDragActive = false
            return 0.2
        }
        DebugScript.registerStep("crumbdrop") { _, window in
            guard let window else { return nil }
            let info = crumbInfo(window)
            let accepted = window.addressBar.performDragOperation(info)
            window.addressBar.draggingEnded(info)
            crumbDragActive = false
            lastDrag = "accepted \(accepted)"
            return 1.2
        }
        DebugScript.registerStep("crumbmiddle") { arg, window in
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let button = Int(parts[0]), let window, let host = window.window else { return nil }
            sendOtherClick(button: button, at: window.addressBar.debugPoint(parts[1]), in: host)
            return 1.2
        }
        DebugScript.registerStep("treedrop") { title, window in
            guard let window else { return nil }
            let tree = window.navPane
            let row = (0..<tree.outline.numberOfRows).first { (tree.outline.item(atRow: $0) as? NavNode)?.title == title } ?? -1
            let info = FakeDraggingInfo(pasteboard: DragPolish.dragPasteboard, window: window.window)
            guard let node = tree.outline.item(atRow: row) as? NavNode else { return nil }
            let operation = tree.outlineView(tree.outline, validateDrop: info, proposedItem: node, proposedChildIndex: NSOutlineViewDropOnItemIndex)
            let accepted = operation != [] && tree.outlineView(tree.outline, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex)
            lastDrag = "operation \(operation.rawValue) accepted \(accepted)"
            return 1.2
        }
    }

    private static func crumbInfo(_ window: BrowserWindowController) -> FakeDraggingInfo {
        FakeDraggingInfo(pasteboard: DragPolish.dragPasteboard, window: window.window, location: crumbPoint, mask: crumbMask)
    }

    private static func writeDragFiles(_ urls: [URL], right: Bool) -> NSPasteboard {
        let pasteboard = DragPolish.dragPasteboard
        pasteboard.clearContents()
        if right, let firstURL = urls.first {
            let first = NSPasteboardItem()
            first.setString(firstURL.absoluteString, forType: .fileURL)
            first.setString("1", forType: DragPolish.rightDragType)
            pasteboard.writeObjects([first] + urls.dropFirst().map { $0 as NSURL })
        } else {
            pasteboard.writeObjects(urls as [NSURL])
        }
        return pasteboard
    }

    /// Through the window, press then release, so the click takes the real path: segment button, then responder chain.
    private static func sendOtherClick(button: Int, at point: NSPoint, in window: NSWindow) {
        for type: NSEvent.EventType in [.otherMouseDown, .otherMouseUp] {
            guard let plain = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
                  let cg = plain.cgEvent else { return }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            guard let event = NSEvent(cgEvent: cg), event.buttonNumber == button else { return }
            window.sendEvent(event)
        }
    }

    /// "Copy here(default) | Move here | ... | --- | Cancel"
    static func describe(_ menu: NSMenu) -> String {
        menu.items.map { item -> String in
            if item.isSeparatorItem { return "---" }
            let font = item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true
            return item.title + (bold ? "(default)" : "")
        }.joined(separator: " | ")
    }
}

/// A stand-in for AppKit's drag info, so scripted checks run the views' real drop code.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    static let anyOperation: NSDragOperation = [.copy, .move, .link, .generic]

    let pasteboard: NSPasteboard
    weak var window: NSWindow?
    let location: NSPoint
    let draggingSourceOperationMask: NSDragOperation

    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint = .zero,
         mask: NSDragOperation = FakeDraggingInfo.anyOperation) {
        self.pasteboard = pasteboard
        self.window = window
        self.location = location
        draggingSourceOperationMask = mask
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
