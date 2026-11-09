import AppKit
import ArborCore

/// Windows 11 Explorer chrome parity (docs/features/visual-parity.md): tab tear-off, merge and overflow steps.
enum VisualParityFeature: ExplorerFeature {
    static let id = "visual-parity"
    static func register() {
        registerScriptSteps()
        registerMenuWording()
    }

    /// Windows 11 menu wording and order inside the window (reference §1.5–§1.7, §2.3, §4).
    private static func registerMenuWording() {
        CommandDispatcher.menuTitleHook.add("visual-parity.menu-wording") { title, item in
            let (command, context) = item
            guard context.surface != .menuBar else { return title }   // the Mac menu bar keeps title case
            if command.id == "view.detailsPane", title == L10n.tr("Details") { return L10n.tr("Details pane") }   // the button says "Details"
            return ExplorerMenuWording.inWindowTitle(title)
        }
        // Background menu (§4.4): View › Sort by › Group by › Refresh, Undo / Paste, New ›, Properties, tools.
        CommandRegistry.shared.sectionRanks[.backgroundContextMenu] = [
            MenuSection.view.name: 100, MenuSection.open.name: 150, MenuSection.clipboard.name: 200, MenuSection.new.name: 300,
            MenuSection.organize.name: 350, MenuSection.properties.name: 400, MenuSection.tools.name: 500,
        ]
        // "Undo <action>" comes before Paste.
        if let undo = CommandRegistry.shared.command("edit.undo") {
            undo.placements = undo.placements.map { p in
                var p = p
                if p.slot == .backgroundContextMenu { p.order = 1 }
                return p
            }
        }
    }

    private static var controllers: [BrowserWindowController] { (NSApp.delegate as? AppDelegate)?.controllers ?? [] }

    private static func registerScriptSteps() {
        // tearoff:N — tear tab N (1-based) of the active window off into a new window.
        DebugScript.registerStep("tearoff") { arg, window in
            guard let window, let n = Int(arg) else { return 0.5 }
            window.tearOffTab(at: n - 1, at: NSPoint(x: 400, y: 700), grabOffset: NSPoint(x: 40, y: 12))
            return 1.2
        }
        // mergetab:TAB:WINDOW:SLOT — drop tab TAB into window WINDOW (creation order) before SLOT, all 1-based.
        DebugScript.registerStep("mergetab") { arg, window in
            let parts = arg.split(separator: ":").compactMap { Int($0) }
            guard let window, parts.count == 3, controllers.indices.contains(parts[1] - 1) else { return 0.5 }
            window.mergeTab(at: parts[0] - 1, into: controllers[parts[1] - 1], slot: parts[2] - 1)
            return 1.2
        }
        // focuswindow:N — front window N (creation order) for later steps.
        DebugScript.registerStep("focuswindow") { arg, _ in
            guard let n = Int(arg), controllers.indices.contains(n - 1) else { return 0.5 }
            controllers[n - 1].window?.makeKeyAndOrderFront(nil)
            return 0.8
        }
        // tabscroll:N — press an overflow arrow N times (negative = backward).
        DebugScript.registerStep("tabscroll") { arg, window in
            window?.tabStrip.scrollTabs(by: Int(arg) ?? 1)
            return 0.5
        }
        // windowsize:W,H — resize the active window (tab overflow checks).
        DebugScript.registerStep("windowsize") { arg, window in
            let wh = arg.split(separator: ",").compactMap { Double($0) }
            if wh.count == 2, let w = window?.window {
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - wh[1], width: wh[0], height: wh[1]), display: true)
            }
            return 0.8
        }
        // droppreview:TAB-SLOT — show the merge insertion marker on the active window's tab row.
        DebugScript.registerStep("droppreview") { arg, window in
            window?.tabStrip.showDropMarker(at: Int(arg).map { $0 - 1 })
            return 0.5
        }
        // dragtab:N:DX — drag tab N (1-based) DX points along the row and drop (negative = left).
        DebugScript.registerStep("dragtab") { arg, window in
            let parts = arg.split(separator: ":").compactMap { Double($0) }
            guard let window, parts.count == 2 else { return 0.5 }
            window.tabStrip.scriptDrag(Int(parts[0]) - 1, by: CGFloat(parts[1]))
            return 0.6
        }
        // windowactive:0|1 — draw as inactive / active (headless windows are never key).
        DebugScript.registerStep("windowactive") { arg, _ in
            SelectionEmphasis.headlessWindowActive = arg != "0"
            return 0.4
        }
        DebugScript.registerLogger("visual-parity.log") { window in
            // Selection style the file list draws now: accent (focused, active) or grey.
            let responder = window.window?.firstResponder as? NSView
            let inItems = window.itemView.map { responder?.isDescendant(of: $0.view) ?? false } ?? false
            let focused = inItems && responder.map(SelectionEmphasis.hasFocus) == true
            return "selection emphasis: window=\(SelectionEmphasis.windowIsActive(window.window) ? "active" : "inactive") items="
                + (focused ? "accent" : "grey")
        }
        DebugScript.registerLogger("visual-parity.log-2") { window in
            let all = controllers.enumerated().map { i, c in
                "\(i + 1)[\(c.tabs.map(\.title).joined(separator: ", "))]" + (c === window ? "*" : "")
            }
            return "window tabs: " + all.joined(separator: " ") + "\ntab strip: " + window.tabStrip.debugOverflow
                + "\nnav row: " + window.navBar.debugOrder + "  tooltips: " + [window.navBar.back, window.navBar.forward, window.navBar.up, window.navBar.refresh].map { $0.toolTip ?? "" }.joined(separator: " · ")
                + "\nrecent: " + window.addressBar.recentMenuEntries.map(\.title).joined(separator: " | ")
        }
    }
}

extension BrowserWindowController {
    /// Explorer-style tooltips naming the target, e.g. "Back to “Documents” (⌘[)" (reference §1.2).
    func updateNavigationTooltips(tab: TabState, shown: Location) {
        func name(_ location: Location) -> String { LocationRegistry.provider(for: location).title(for: location) }
        navBar.back.toolTip = tab.history.peekBack().map { L10n.format("Back to “%@” (⌘[ or Delete)", name($0.location)) }
            ?? L10n.tr("Back (⌘[ or Delete)")
        navBar.forward.toolTip = tab.history.peekForward().map { L10n.format("Forward to “%@” (⌘])", name($0.location)) }
            ?? L10n.tr("Forward (⌘])")
        navBar.up.toolTip = shown.parent().map { L10n.format("Up to “%@” (⌘↑)", name($0)) } ?? L10n.tr("Up (⌘↑)")
        navBar.refresh.toolTip = L10n.format("Refresh “%@” (⌘R or F5)", name(shown))
        // VoiceOver reads the same text as each button's help.
        for button in [navBar.back, navBar.forward, navBar.up, navBar.refresh] { button.setAccessibilityHelp(button.toolTip) }
    }
}

extension NavigationBar {
    /// Left-to-right accessibility labels of the navigation row, for scripted checks.
    var debugOrder: String {
        subviews.first.map { stack in
            stack.subviews.sorted { $0.frame.minX < $1.frame.minX }.compactMap { view in
                (view as? ChromeButton)?.accessibilityLabel() ?? (view is AddressBar ? "Address" : view is SearchBox ? "Search" : nil)
            }.joined(separator: ", ")
        } ?? ""
    }
}
