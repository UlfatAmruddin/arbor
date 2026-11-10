import AppKit
import ArborCore

/// Checks what a workspace still has on disk, off the main thread, then opens what's there.
final class WorkspaceOpener {
    static let shared = WorkspaceOpener()

    let check: WorkspaceOpenCheck
    private static let namesShown = 6
    private var store: WorkspaceStore { WorkspacesFeature.store }

    init(check: WorkspaceOpenCheck = WorkspaceOpenCheck()) { self.check = check }

    /// Replaces the tabs of `window`, or opens a new window when it's nil.
    func open(_ id: String, replacing window: BrowserWindowController? = nil) {
        guard let workspace = store.list.workspace(id: id) else { NSSound.beep(); return }
        let replaces = window != nil
        check.run(workspace) { [weak self, weak window] outcome in
            guard let self, let current = self.store.list.workspace(id: id), !replaces || window != nil else {
                NSSound.beep()
                return
            }
            switch outcome {
            case .timedOut: Self.showNotResponding(current.name, in: window?.window)
            case .finished(let plan): Self.apply(plan, name: current.name, replacing: replaces ? window : nil)
            }
        }
    }

    /// The check can take seconds, so the window is judged now, not when the menu was built.
    static func apply(_ plan: WorkspaceOpenPlan, name: String, replacing window: BrowserWindowController?) {
        guard !plan.tabs.isEmpty else {
            showNothingAvailable(name, plan: plan, in: window?.window)
            return
        }
        if let window, window.window?.attachedSheet != nil {
            NSSound.beep()
            window.statusBar.setMessage(L10n.tr("Close the open dialog, then try again."), isError: true)
            return
        }
        let tabs = plan.tabs.map { TabState(session: $0.saved, location: $0.location) }
        let host: NSWindow?
        if let window {
            window.replaceTabs(with: tabs, activeIndex: plan.activeIndex)
            host = window.window
        } else {
            host = (NSApp.delegate as? AppDelegate)?.openWindow(tabs: tabs, activeIndex: plan.activeIndex).window
        }
        if !plan.unavailableNames.isEmpty || plan.unreadableCount > 0 { showSkipped(name, plan: plan, in: host) }
    }

    // MARK: Messages

    private static func showNotResponding(_ name: String, in host: NSWindow?) {
        WorkspacePrompts.inform(title: L10n.format("A place in “%@” isn't responding", name),
                                message: L10n.tr("No tabs were changed. Try again in a moment."), in: host)
    }

    private static func showNothingAvailable(_ name: String, plan: WorkspaceOpenPlan, in host: NSWindow?) {
        var lines: [String] = []
        if !plan.unavailableNames.isEmpty { lines.append(L10n.tr("They may have been moved, deleted or disconnected.")) }
        if let line = unreadableLine(plan.unreadableCount) { lines.append(line) }
        lines.append(L10n.tr("No tabs were changed, and the workspace stays as it was."))
        WorkspacePrompts.inform(title: L10n.format("None of the places in “%@” are available", name),
                                message: lines.joined(separator: "\n"), in: host)
    }

    private static func showSkipped(_ name: String, plan: WorkspaceOpenPlan, in host: NSWindow?) {
        var lines = Array(plan.unavailableNames.prefix(namesShown))
        if plan.unavailableNames.count > namesShown { lines.append(L10n.format("…and %d more.", plan.unavailableNames.count - namesShown)) }
        if !plan.unavailableNames.isEmpty {
            lines.append(L10n.tr("These places may have been moved, deleted or disconnected. They stay in the workspace and come back when the folder does; saving again under the same name removes them."))
        }
        if let line = unreadableLine(plan.unreadableCount) { lines.append(line) }
        WorkspacePrompts.inform(title: L10n.format("Some tabs in “%@” couldn't be opened", name),
                                message: lines.joined(separator: "\n"), in: host)
    }

    private static func unreadableLine(_ count: Int) -> String? {
        count == 0 ? nil : L10n.plural(one: "%lld tab has a location this version of Arbor can't open.", other: "%lld tabs have a location this version of Arbor can't open.", count)
    }
}
