import AppKit
import ArborCore

/// Developer test harness, inactive unless `ARBOR_SCRIPT` is set. Runs semicolon-separated steps
/// (see TESTING.md) through the same registry and responder chain as the menus.
/// Features add steps with `registerStep(_:)` and log lines with `registerLogger(_:)`;
/// a duplicate step name is an extension error.
enum DebugScript {
    typealias Step = (_ argument: String, _ window: BrowserWindowController?) -> TimeInterval?
    private static var steps: [String: Step] = [:]
    private static var stepOwners: [String: String] = [:]
    /// Lines `log:` appends, one per contribution, in run order.
    static let loggers = Pipeline<String, BrowserWindowController>(
        "DebugScript.loggers", "Lines the log: script step appends.", signature: "(text, window) -> text")

    static func registerStep(_ name: String, _ step: @escaping Step) {
        guard claim(name) else { return }
        steps[name] = step
    }

    static func registerLogger(_ id: String, _ logger: @escaping (BrowserWindowController) -> String) {
        loggers.add(id) { text, window in text + logger(window) + "\n" }
    }

    /// Holds the script until it returns true: called with `elapsed` 0 to start, then every few ms.
    typealias WaitStep = (_ argument: String, _ window: BrowserWindowController?, _ elapsed: TimeInterval) -> Bool
    private static var waitSteps: [String: WaitStep] = [:]
    static func registerWaitStep(_ name: String, _ step: @escaping WaitStep) {
        guard claim(name) else { return }
        waitSteps[name] = step
    }

    /// False (and an extension error) when the name is taken.
    private static func claim(_ name: String) -> Bool {
        let registry = ExtensionRegistry.shared
        let feature = registry.currentFeature ?? "an earlier registration"
        if let owner = stepOwners[name] {
            registry.report(ExtensionError(point: "DebugScript.steps", problem: .duplicateID,
                                           existing: "feature \"\(owner)\"", rejected: "\(name) (feature \"\(feature)\")"))
            return false
        }
        stepOwners[name] = feature
        return true
    }

    /// Step name → registering feature (listed by the `extensions` step).
    static var stepNames: [(name: String, feature: String)] {
        stepOwners.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    /// The step running now (labels main-thread stall reports).
    private(set) static var currentStep = ""

    static func runIfRequested() {
        guard let script = Automation.environment["ARBOR_SCRIPT"] else { return }
        let list = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        run(list[...], delay: 1.2)
    }

    private static func run(_ list: ArraySlice<String>, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let step = list.first else { return }
            currentStep = step
            let (command, argument) = split(step)
            if let wait = waitSteps[command] {
                poll(wait, argument, started: Date(), rest: list.dropFirst())
                return
            }
            let next = perform(step)
            run(list.dropFirst(), delay: next)
        }
    }

    private static func poll(_ wait: @escaping WaitStep, _ argument: String, started: Date, rest: ArraySlice<String>,
                             first: Bool = true) {
        let elapsed = first ? 0 : max(Date().timeIntervalSince(started), 0.000_001)
        if wait(argument, controller, elapsed) { run(rest, delay: 0); return }
        if elapsed > 600 {
            NSLog("DebugScript: \(currentStep) timed out")
            run(rest, delay: 0)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { poll(wait, argument, started: started, rest: rest, first: false) }
    }

    private static var controller: BrowserWindowController? { BrowserWindowController.active }

    /// Splits "a:b" once.
    private static func split(_ s: String) -> (String, String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    /// Returns the pause before the next step.
    private static func perform(_ step: String) -> TimeInterval {
        let (command, argument) = split(step)
        let c = controller
        let window = c?.window
        switch command {
        case "select":
            c?.itemView?.select(names: argument.components(separatedBy: "|"))
            c?.itemView?.focus()
        case "click":
            if c?.perform(argument, surface: .script) != true { NSLog("DebugScript: command \(argument) unavailable or disabled") }
        case "action":
            // Walk the responder chain directly: a script launched from a terminal may leave no key window.
            let selector = Selector(argument)
            let start: NSResponder? = window?.firstResponder ?? window
            if start?.tryToPerform(selector, with: nil) != true, !NSApp.sendAction(selector, to: nil, from: nil) {
                NSLog("DebugScript: nothing handled \(argument)")
            }
        case "newtab": c?.perform("tab.new")
        case "closetab": c?.perform("tab.close")
        case "duptab": c?.perform("tab.duplicate")
        case "detachtab": c?.perform("tab.moveToNewWindow")
        case "tab":
            if let n = Int(argument) { c?.selectTab(at: n - 1) }
        case "movetab":
            let (a, b) = split(argument)
            if let from = Int(a), let to = Int(b) { c?.moveTab(from: from - 1, to: to - 1) }
        case "location":
            if let location = parseLocation(argument) { c?.navigate(to: location) } else { NSLog("DebugScript: bad location \(argument)") }
        case "view":
            if let mode = ViewMode(rawValue: argument) { c?.setViewMode(mode) } else { NSLog("DebugScript: bad view \(argument)") }
        case "back": c?.goBack()
        case "forward": c?.goForward()
        case "up": c?.goUp()
        case "refresh": c?.reload()
        case "type":
            if let editor = window?.firstResponder as? NSTextView { editor.string = argument }
        case "enter":
            (window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case "escape":
            (window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case "button":
            let sheet = window?.attachedSheet ?? NSApp.modalWindow
            if let button = findButton(argument, in: sheet?.contentView) { button.performClick(nil) }
        case "search":
            c?.focusSearch()
            if let editor = window?.firstResponder as? NSTextView {
                editor.string = argument
                editor.didChangeText()
            }
        case "address":
            c?.focusAddressBar(text: argument)
            (window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case "snapshot":
            snapshot(window, to: argument)
        case "snapshotlayer":
            // Renders the layer tree instead of drawing views (cross-check for `snapshot:`).
            if let frame = window?.contentView?.superview, let layer = frame.layer {
                let scale = window?.backingScaleFactor ?? 2
                let size = frame.bounds.size
                if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    layer.render(in: ctx)
                    if let image = ctx.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: image)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
                    }
                }
            }
        case "log":
            log(to: argument)
        case "crumbs":
            if let c { append("crumbs (\(c.location.key)):\n" + c.addressBar.debugDescription(includeMenus: true) + "\n---\n", to: argument) }
        case "menu":
            // menu:<which>[:<arg>]:<path> — the output path is after the last colon.
            if let colon = argument.range(of: ":", options: .backwards) {
                logMenu(String(argument[..<colon.lowerBound]), to: String(argument[colon.upperBound...]))
            }
        case "hittest":
            let (point, path) = split(argument)
            let xy = point.split(separator: ",").compactMap { Double($0) }
            if xy.count == 2, let frame = window?.contentView?.superview, let win = window {
                let p = NSPoint(x: xy[0], y: win.frame.height - xy[1])
                let hit = frame.hitTest(frame.convert(p, from: nil))
                append("hit \(point): \(hit.map { String(describing: type(of: $0)) } ?? "nil")\n", to: path)
            }
        case "undostate":
            let um = OperationCenter.shared.undoManager
            append("undo: level=\(um.groupingLevel) canUndo=\(um.canUndo) name=\(um.undoActionName)\n", to: argument)
            return 0.8
        case "event":
            // Ends one user input (closes the undo group).
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(e, atStart: false)
            }
            return 0.5
        case "wait":
            return Double(argument) ?? 1
        case "quit":
            Prefs.discardHeadlessStore()
            exit(0)
        default:
            if let custom = steps[command] { return custom(argument, c) ?? 0.8 }
            NSLog("DebugScript: unknown step \(step)")
        }
        return 0.8
    }

    static func parseLocation(_ text: String) -> Location? {
        if let key = Location(key: text) { return key }
        if let place = Location.keyword(text) { return place }
        let base = controller?.location.folderURL ?? FileManager.default.homeDirectoryForCurrentUser
        if case .success(.folder(let url)) = PathResolver().resolve(text, relativeTo: base) { return .folder(url) }
        return nil
    }

    private static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for sub in view.subviews { if let found = findButton(title, in: sub) { return found } }
        return nil
    }

    private static func snapshot(_ window: NSWindow?, to path: String) {
        guard let frameView = window?.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func menuTitles(_ menu: NSMenu?, indent: String = "") -> String {
        guard let menu else { return "(no menu)" }
        menu.update()
        return menu.items.map { item -> String in
            if item.isSeparatorItem { return indent + "---" }
            var line = indent + item.title
            if !item.keyEquivalent.isEmpty, let cmd = (item as? CommandMenuItem).flatMap({ CommandRegistry.shared.command($0.commandID) }),
               let shortcut = cmd.shortcut { line += " [\(shortcut.displayString)]" }
            if item.state == .on { line += " ✓" }
            if !item.isEnabled { line += " (disabled)" }
            if let sub = item.submenu { line += "\n" + menuTitles(sub, indent: indent + "    ") }
            return line
        }.joined(separator: "\n")
    }

    private static func logMenu(_ which: String, to path: String) {
        guard let c = controller else { return }
        let (kind, arg) = split(which)
        let menu: NSMenu?
        switch kind {
        case "item": menu = c.contextMenu(for: .itemContextMenu)
        case "background": menu = c.contextMenu(for: .backgroundContextMenu)
        case "tree":
            let row = Int(arg) ?? 0
            menu = (c.navPane.outline.item(atRow: row) as? NavNode).flatMap { c.navigationPaneMenu(for: $0) }
        case "tab": menu = c.tabStripMenu(for: (Int(arg) ?? 1) - 1)
        case "new": menu = CommandDispatcher.shared.menu(for: .newMenu, context: c.context(surface: .commandBar, sender: nil))
        case "sort": menu = CommandDispatcher.shared.menu(for: .sortMenu, context: c.context(surface: .commandBar, sender: nil))
        case "view": menu = CommandDispatcher.shared.menu(for: .viewMenu, context: c.context(surface: .commandBar, sender: nil))
        case "seemore": menu = CommandDispatcher.shared.menu(for: .seeMore, context: c.context(surface: .commandBar, sender: nil))
        case "main": menu = (NSApp.mainMenu?.item(withTitle: arg) ?? NSApp.mainMenu?.item(withTitle: MainMenu.shownTitle(arg)))?.submenu
        default: menu = nil
        }
        append("menu \(which):\n" + menuTitles(menu) + "\n---\n", to: path)
    }

    private static func log(to path: String) {
        guard let c = controller else { append("no window\n---\n", to: path); return }
        let tab = c.activeTab
        var text = "windows: \(BrowserWindowController.allCount)\n"
        text += "tabs: \(c.tabs.map(\.title).joined(separator: " | "))  active: \(c.activeIndex + 1)\n"
        text += "location: \(tab.location.key)  view: \(tab.viewMode.rawValue)"
            + (ViewModeRegistry.effective(tab.viewMode) != tab.viewMode ? " (shown as details)" : "") + "\n"
        text += "content: \(tab.showsPage ? "page \(type(of: tab.page ?? NSViewController()))" : "items")\n"
        text += "folder: \(tab.location.folderURL?.path ?? "-")\n"
        text += "rows: \(c.visibleItems.map(\.name).joined(separator: " | "))\n"
        text += "selected: \(c.selectedItems.map(\.name).joined(separator: " | "))\n"
        text += "status: \(c.statusBar.debugText)\n"
        text += "back: \(tab.history.canGoBack) forward: \(tab.history.canGoForward) up: \(c.canGoUp)\n"
        text += "address: \(c.addressBar.debugDescription(includeMenus: false).replacingOccurrences(of: "\n", with: "; "))\n"
        text += "search placeholder: \(c.searchBox.placeholder)\n"
        text += "commandbar: \(c.commandBar.debugState)\n"
        text += "statusbar toggles: \(c.statusBar.debugToggles)\n"
        text += "side pane: \(c.sidePane.currentID.isEmpty ? "none" : c.sidePane.currentID)  nav pane: \(Prefs.navigationPaneVisible)\n"
        text += "tree: \(c.navPane.debugRows.joined(separator: " | "))\n"
        text += "sheet: \(c.window?.attachedSheet != nil)\n"
        let parts: [(String, NSView)] = [("tabstrip", c.tabStrip), ("navbar", c.navBar), ("commandbar", c.commandBar),
                                         ("navpane", c.navPane.view), ("sidepane", c.sidePane), ("statusbar", c.statusBar)]
        text += "frames: " + parts.map { "\($0.0)=\(NSStringFromRect($0.1.frame))\($0.1.isHidden ? "(hidden)" : "")" }.joined(separator: " ") + "\n"
        if let window = c.window { text += "window: \(NSStringFromRect(window.frame)) title: \(window.title)\n" }
        text = loggers.apply(text, c)
        text += "---\n"
        append(text, to: path)
    }

    private static func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

extension BrowserWindowController {
    static var allCount: Int { (NSApp.delegate as? AppDelegate)?.controllers.count ?? 0 }
}
