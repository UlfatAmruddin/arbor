import AppKit
import ArborCore

/// Accessibility, keyboard and input, localization infrastructure (FE-012, FE-016, FE-050, FE-061,
/// FE-062, FE-066–FE-068, FE-199–FE-204; spec §16.2). See docs/features/accessibility.md.
enum AccessibilityFeature {
    static func register() {
        LayoutDirection.applyEnvironment()
        KeyboardRouter.install()
        PointerNavigation.install()
        Announcer.install()
        ChromeAccessibility.install()
        FocusKeeper.install()
        DisplayOptions.install()
        TextSize.register()
        AccessibilityDebug.register()
        CommandRegistry.shared.register(ExplorerCommand(
            id: "focus.nextRegion", title: "Move Focus to Next Area", shortcut: Shortcut.function(NSF6FunctionKey, []),
            placements: [.mainMenu("Go", .tools, 80)],
            isEnabled: { $0.window != nil },
            perform: { ctx in if let w = ctx.window { FocusRegions.cycle(w, forward: true) } }))
    }
}

/// `ARBOR_RTL=1` lays the app out right to left (like an Arabic or Hebrew system language), to check
/// mirroring and truncation without changing the system (FE-204).
enum LayoutDirection {
    static func applyEnvironment() {
        guard ProcessInfo.processInfo.environment["ARBOR_RTL"] == "1" else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSForceRightToLeftWritingDirection"] = true
        arguments["AppleTextDirection"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}

/// Keeps keyboard focus somewhere useful (FE-203): when a refresh, navigation, tab switch, page change
/// or pane toggle removes or hides the focused view, focus moves to the items (or the page) instead of
/// being lost.
enum FocusKeeper {
    static func install() {
        WindowHooks.didDisplay.append { c, _ in schedule(c) }
        WindowHooks.willDisplay.append { c, _, _, _ in schedule(c) }
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { note in
            let key = note.userInfo?["key"] as? String
            guard key == "sidePane" || key == "navigationPaneVisible" else { return }
            (NSApp.delegate as? AppDelegate)?.controllers.forEach(schedule)
        }
    }

    static func schedule(_ c: BrowserWindowController) {
        DispatchQueue.main.async { [weak c] in
            guard let c else { return }
            repair(c)
        }
    }

    /// True when focus was lost: on the window itself, or on a view that is hidden or gone.
    static func isLost(_ window: NSWindow) -> Bool {
        if window.firstResponder === window || window.firstResponder == nil { return true }
        guard let view = FocusRegions.focusedView(in: window) else { return false }
        return view.window !== window || view.isHiddenOrHasHiddenAncestor
    }

    /// Windows whose first content has been shown (a new window starts with focus on the items, like
    /// Explorer, not on whichever text field AppKit picked before the items loaded).
    private static var started = Set<ObjectIdentifier>()

    static func repair(_ c: BrowserWindowController) {
        guard let window = c.window, window.attachedSheet == nil, !c.tabs.isEmpty else { return }
        let first = started.insert(ObjectIdentifier(c)).inserted
        if first, let region = FocusRegions.current(in: c), region == .search || region == .address,
           (window.firstResponder as? NSTextView)?.string.isEmpty != false || region == .address {
            FocusRegions.focus(.items, in: c)
            if c.addressBar.isEditingPath { c.addressBar.endEditing() }
            return
        }
        guard isLost(window) else { return }
        if !FocusRegions.focus(.items, in: c), !c.navPane.view.isHidden {
            FocusRegions.focus(.navigationPane, in: c)
        }
    }
}
