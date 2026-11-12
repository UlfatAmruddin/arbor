import AppKit
import ArborCore

/// In-app updates (FE-259, DEC-028): a quiet Update button when a signed newer release exists, Arbor ▸
/// Check for Updates… and a Settings switch. A build without a feed and key has none of them and never
/// reaches the network. See docs/features/updates.md.
enum UpdatesFeature: ExplorerFeature {
    static let id = "updates"
    /// The automatic-check switch goes on Folder Options' General page.
    static let requires = ["folder-options"]

    /// Decided once: the built Info.plist, and in debug builds a test feed for the end-to-end check.
    static let plan: UpdateConfiguration.Plan = {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let testFeed = Automation.environment["ARBOR_UPDATE_FEED"]
        #else
        let testFeed: String? = nil
        #endif
        return UpdateConfiguration.plan(feed: info["SUFeedURL"] as? String, publicKey: info["SUPublicEDKey"] as? String,
                                        testFeed: testFeed, headless: AppDelegate.isHeadless,
                                        scripted: Automation.environment["ARBOR_SCRIPT"] != nil)
    }()

    static func register() {
        UpdatePills.install()
        registerScriptSteps()
        guard case .run(let configuration) = plan else { return }
        CommandRegistry.shared.register(ExplorerCommand(
            id: "app.checkForUpdates", title: "Check for Updates…",
            placements: [.mainMenu("Arbor", .main, 5)],
            isEnabled: { _ in AppUpdater.shared?.canCheck == true },
            perform: { _ in AppUpdater.shared?.checkForUpdates() }))
        FolderOptionsWindowController.generalGroups.add("updates.automatic-checks") { $0 + [AutomaticChecksBox.group()] }
        WindowHooks.didCreate.observe("updates.start") { _ in AppUpdater.startSoon(configuration) }
    }

    // MARK: Scripted checks

    private static func registerScriptSteps() {
        // updatestate:available:0.4.0 | available | none — the Update button without a feed (Sparkle's events).
        DebugScript.registerStep("updatestate") { arg, _ in
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.first == "available" {
                UpdatePills.apply(.found(version: parts.count > 1 ? parts[1] : "", shownByUpdater: false))
            } else {
                UpdatePills.apply(.finished)
            }
            return 0.5
        }
        // scripts/update-e2e.sh: check as the user would, press the Update button, press buttons in Sparkle's windows.
        DebugScript.registerStep("updatecheck") { _, _ in
            AppUpdater.shared?.checkForUpdates()
            return 1
        }
        DebugScript.registerStep("updatepill") { _, window in
            if let window, let pill = UpdatePills.pill(in: window) { pill.performClick() } else { NSLog("DebugScript: no Update button") }
            return 1
        }
        DebugScript.registerStep("updatepress") { title, _ in
            if let button = updateWindows.lazy.compactMap({ findButton(title, in: $0.contentView) }).first {
                button.performClick(nil)
            } else {
                NSLog("DebugScript: no update window button %@", title)
            }
            return 1
        }
        DebugScript.registerLogger("updates.log") { window in
            var lines = ["updates: updater=\(updaterState) menu=\(menuItemPresent ? "present" : "absent") settings=\(settingsSwitchState)"
                         + " windows=\(updateWindows.count)"]
            if let pill = UpdatePills.pill(in: window) {
                lines.append("update button: shown title=\(pill.title) tooltip=\(pill.toolTip ?? "") label=\(pill.accessibilityLabel() ?? "")"
                             + " overlap=\(overlapsTabs(pill, in: window)) keyboard=\(window.tabStrip.trailingStops.contains { $0 === pill })")
            } else {
                lines.append("update button: none")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static var updaterState: String {
        switch plan {
        case .off(let reason): return "off (\(reason.rawValue))"
        case .run:
            guard let app = AppUpdater.shared else { return "waiting for a window" }
            if let error = app.lastError { return "on, last error: \(error)" }
            return app.isStarted ? "on" : "starting"
        }
    }

    /// Sparkle's own windows on screen (its classes start with SU or SPU), to show that a scheduled find opens none.
    private static var updateWindows: [NSWindow] {
        NSApp.windows.filter { window in
            guard window.isVisible, let controller = window.windowController else { return false }
            let name = String(describing: type(of: controller))
            return name.hasPrefix("SU") || name.hasPrefix("SPU")
        }
    }

    private static var menuItemPresent: Bool {
        NSApp.mainMenu?.items.first?.submenu?.items.contains { ($0 as? CommandMenuItem)?.commandID == "app.checkForUpdates" } ?? false
    }

    private static var settingsSwitchState: String {
        guard let content = FolderOptionsWindowController.shared?.window?.contentView else { return "not open" }
        guard let box = findView(AutomaticChecksBox.identifier, in: content) as? NSButton else { return "absent" }
        return box.state == .on ? "on" : "off"
    }

    /// Whether the button covers a visible tab or the New tab button.
    private static func overlapsTabs(_ pill: NSView, in window: BrowserWindowController) -> Bool {
        let strip = window.tabStrip
        let frame = pill.convert(pill.bounds, to: strip)
        let tabs = FocusRegions.tabViews(in: window).map { $0.convert($0.visibleRect, to: strip) }.filter { !$0.isEmpty }
        return (tabs + [strip.plusButton.frame]).contains { $0.intersects(frame) }
    }

    private static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view, !view.isHidden else { return nil }
        if let button = view as? NSButton, button.title == title, button.isEnabled { return button }
        return view.subviews.lazy.compactMap { findButton(title, in: $0) }.first
    }

    private static func findView(_ identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identifier { return view }
        return view.subviews.lazy.compactMap { findView(identifier, in: $0) }.first
    }
}
