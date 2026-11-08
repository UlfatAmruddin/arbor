import AppKit
import ArborCore

/// The seven non-Details layouts (Features.swift slot "icon views"): Extra large / Large / Medium /
/// Small icons, List, Tiles and Content, plus ⌘-scroll to step icon sizes and scripted-test steps.
/// See docs/features/icon-views.md.
enum IconViewsFeature: ExplorerFeature {
    static let id = "icon-views"
    static func register() {
        ViewModeRegistry.register(IconViewController.modes) { IconViewController() }
        installSizeWheel()
        registerDebugSteps()
    }

    // MARK: ⌘ + scroll wheel (Explorer: Ctrl + mouse wheel changes icon size, FE-033)

    /// From small to large, the order Ctrl+wheel steps through in Explorer.
    static let sizeOrder: [ViewMode] = [.details, .list, .smallIcons, .mediumIcons, .largeIcons, .extraLargeIcons]
    private static var wheelAccumulator: CGFloat = 0
    private static var lastStep = Date.distantPast

    static func nextSize(from mode: ViewMode, larger: Bool) -> ViewMode {
        let position = sizeOrder.firstIndex(of: mode) ?? sizeOrder.firstIndex(of: .mediumIcons)!
        let target = min(max(0, position + (larger ? 1 : -1)), sizeOrder.count - 1)
        return sizeOrder[target]
    }

    private static func installSizeWheel() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  let controller = event.window?.windowController as? BrowserWindowController,
                  let itemView = controller.itemView, !itemView.view.isHidden,
                  itemView.view.bounds.contains(itemView.view.convert(event.locationInWindow, from: nil)) else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            if event.phase == .began { wheelAccumulator = 0 }
            wheelAccumulator += delta
            guard abs(wheelAccumulator) >= 1, Date().timeIntervalSince(lastStep) > 0.12 else { return nil }
            let larger = wheelAccumulator > 0
            wheelAccumulator = 0
            lastStep = Date()
            let current = ViewModeRegistry.effective(controller.activeTab.viewMode)
            let next = nextSize(from: current, larger: larger)
            if next != current, ViewModeRegistry.isRegistered(next) { controller.setViewMode(next) }
            return nil
        }
    }

    // MARK: Scripted checks (TESTING.md; docs/features/icon-views.md lists the steps)

    private static func iconView(_ window: BrowserWindowController?) -> IconViewController? {
        window?.itemView as? IconViewController
    }

    private static func registerDebugSteps() {
        DebugScript.registerLogger("icon-views.log") { window in
            let view = (window.itemView as? IconViewController)?.debugState ?? "iconview: none"
            return view + "\n" + ThumbnailService.shared.debugSummary + "  footprintMB=\(memoryFootprintMB())"
        }
        // iconlog:/path — the icon view's layout, scroll and thumbnail state only.
        DebugScript.registerStep("iconlog") { path, window in
            let text = (iconView(window)?.debugState ?? "iconview: none") + "\n"
                + "selected: \(window?.selectedItems.map(\.name).joined(separator: " | ") ?? "")\n"
                + ThumbnailService.shared.debugSummary + "  footprintMB=\(memoryFootprintMB())\n---\n"
            append(text, to: path)
            return 0.3
        }
        // iconkey:right,shift+down,ctrl+space,end,pagedown,return,f2,type=abc
        DebugScript.registerStep("iconkey") { spec, window in
            guard let view = iconView(window) else { return 0.3 }
            view.focus()
            for token in spec.split(separator: ",").map(String.init) {
                if token.hasPrefix("type=") {
                    for ch in token.dropFirst(5) { sendKey(view.grid, code: 0, characters: String(ch), flags: []) }
                } else if let (code, chars, flags) = keySpec(token) {
                    sendKey(view.grid, code: code, characters: chars, flags: flags)
                } else {
                    NSLog("DebugScript: bad iconkey \(token)")
                }
            }
            return 0.4
        }
        // iconclick:<name>[:cmd|shift|cmd+shift|double|right|name] — real mouse events through the grid.
        DebugScript.registerStep("iconclick") { arg, window in
            guard let view = iconView(window) else { return 0.3 }
            let parts = arg.components(separatedBy: ":")
            guard let index = view.items.firstIndex(where: { $0.name == parts[0] }) else { NSLog("DebugScript: no item \(parts[0])"); return 0.3 }
            let style = parts.count > 1 ? parts[1] : ""
            let g = view.grid.geometry(index)
            let point = style == "name" ? CGPoint(x: g.name.midX, y: g.name.midY) : CGPoint(x: g.icon.midX, y: g.icon.midY)
            var flags: NSEvent.ModifierFlags = []
            if style.contains("cmd") { flags.insert(.command) }
            if style.contains("shift") { flags.insert(.shift) }
            click(view.grid, at: point, flags: flags, count: style == "double" ? 2 : 1, right: style == "right")
            return 0.4
        }
        // iconmarquee:x1,y1,x2,y2[:mods][:holdSeconds] — drag a rubber band; points are relative to the
        // visible area's top-left. A point outside the visible area plus a hold time exercises autoscroll.
        DebugScript.registerStep("iconmarquee") { arg, window in
            guard let view = iconView(window) else { return 0.3 }
            let parts = arg.components(separatedBy: ":")
            let n = parts[0].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else { return 0.3 }
            let origin = view.grid.visibleRect.origin
            let a = CGPoint(x: origin.x + n[0], y: origin.y + n[1]), b = CGPoint(x: origin.x + n[2], y: origin.y + n[3])
            var flags: NSEvent.ModifierFlags = []
            if parts.count > 1, parts[1].contains("cmd") { flags.insert(.command) }
            if parts.count > 1, parts[1].contains("shift") { flags.insert(.shift) }
            let hold = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
            marquee(view.grid, from: a, to: b, flags: flags, hold: hold)
            return 0.5 + hold
        }
        DebugScript.registerStep("iconhover") { name, window in
            guard let view = iconView(window) else { return 0.3 }
            view.grid.setHovered(view.items.firstIndex { $0.name == name })
            return 0.3
        }
        DebugScript.registerStep("iconscroll") { name, window in
            guard let view = iconView(window), let index = view.items.firstIndex(where: { $0.name == name }) else { return 0.3 }
            view.grid.scrollToStart(index)
            return 0.4
        }
        DebugScript.registerStep("iconsonly") { arg, _ in
            Prefs.alwaysShowIcons = arg == "1" || arg == "true"
            return 0.5
        }
        // iconwheel:up|down — ⌘ + scroll wheel over the item view.
        DebugScript.registerStep("iconwheel") { arg, window in
            guard let window else { return 0.3 }
            let next = nextSize(from: ViewModeRegistry.effective(window.activeTab.viewMode), larger: arg != "down")
            window.setViewMode(next)
            return 0.5
        }
        // iconselectrange:0-99 — select items by index range (programmatic, like Select All).
        DebugScript.registerStep("iconselectrange") { arg, window in
            guard let view = iconView(window) else { return 0.3 }
            let n = arg.split(separator: "-").compactMap { Int($0) }
            guard n.count == 2, n[0] <= n[1], n[1] < view.items.count else { return 0.3 }
            view.grid.setSelection(IndexSet(integersIn: n[0]...n[1]))
            return 0.3
        }
    }

    private static func keySpec(_ token: String) -> (UInt16, String, NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        var parts = token.lowercased().split(separator: "+").map(String.init)
        let key = parts.removeLast()
        for p in parts {
            switch p {
            case "shift": flags.insert(.shift)
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "opt", "alt": flags.insert(.option)
            default: return nil
            }
        }
        func fn(_ scalar: Int) -> String { String(Character(UnicodeScalar(UInt32(scalar))!)) }
        switch key {
        case "left": return (123, fn(NSLeftArrowFunctionKey), flags.union(.function))
        case "right": return (124, fn(NSRightArrowFunctionKey), flags.union(.function))
        case "down": return (125, fn(NSDownArrowFunctionKey), flags.union(.function))
        case "up": return (126, fn(NSUpArrowFunctionKey), flags.union(.function))
        case "home": return (115, fn(NSHomeFunctionKey), flags.union(.function))
        case "end": return (119, fn(NSEndFunctionKey), flags.union(.function))
        case "pageup": return (116, fn(NSPageUpFunctionKey), flags.union(.function))
        case "pagedown": return (121, fn(NSPageDownFunctionKey), flags.union(.function))
        case "return": return (36, "\r", flags)
        case "space": return (49, " ", flags)
        case "f2": return (120, fn(NSF2FunctionKey), flags.union(.function))
        case "escape": return (53, "\u{1b}", flags)
        default: return nil
        }
    }

    private static func sendKey(_ view: NSView, code: UInt16, characters: String, flags: NSEvent.ModifierFlags) {
        guard let window = view.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        view.keyDown(with: event)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, _ view: NSView, _ point: CGPoint, _ flags: NSEvent.ModifierFlags,
                                   count: Int = 1) -> NSEvent? {
        guard let window = view.window else { return nil }
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: count, pressure: 1)
    }

    private static func click(_ grid: ItemGridView, at point: CGPoint, flags: NSEvent.ModifierFlags, count: Int, right: Bool) {
        if right {
            if let down = mouseEvent(.rightMouseDown, grid, point, flags) { _ = grid.menu(for: down) }
            return
        }
        for n in 1...count {
            guard let down = mouseEvent(.leftMouseDown, grid, point, flags, count: n),
                  let up = mouseEvent(.leftMouseUp, grid, point, flags, count: n) else { return }
            NSApp.postEvent(up, atStart: false)
            grid.mouseDown(with: down)
        }
    }

    private static func marquee(_ grid: ItemGridView, from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags, hold: Double) {
        guard let down = mouseEvent(.leftMouseDown, grid, a, flags) else { return }
        // Drag events are positioned in window coordinates now; the grid may scroll while they're handled.
        let windowA = grid.convert(a, to: nil), windowB = grid.convert(b, to: nil)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            let p = NSPoint(x: windowA.x + (windowB.x - windowA.x) * t, y: windowA.y + (windowB.y - windowA.y) * t)
            if let window = grid.window, let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: p, modifierFlags: flags,
                                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                                       windowNumber: window.windowNumber, context: nil,
                                                                       eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(drag, atStart: false)
            }
        }
        let postUp = {
            guard let window = grid.window, let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowB, modifierFlags: flags,
                                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                                         windowNumber: window.windowNumber, context: nil,
                                                                         eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            NSApp.postEvent(up, atStart: false)
        }
        if hold > 0 {
            // A run-loop timer fires inside the tracking loop; a main-queue block would wait for this step to end.
            RunLoop.main.add(Timer(timeInterval: hold, repeats: false) { _ in postUp() }, forMode: .common)
        } else {
            postUp()
        }
        grid.mouseDown(with: down)
    }

    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
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
