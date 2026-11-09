import AppKit
import ArborCore

/// Reads Windows .lnk and .url files without changing them (FE-215). See docs/features/windows-shortcuts.md.
enum WindowsShortcutsFeature: ExplorerFeature {
    static let id = "windows-shortcuts"
    /// Its handlers are ordered around item-actions and archives, and it adds to the Properties tabs.
    static let requires = ["item-actions", "properties", "archives"]

    static func register() {
        // Before archives.open-file, which would hand a member's extracted copy to the system unchecked.
        InteractionHooks.openFile.register("windows-shortcuts.archive-member", order: .first, handles: { window, file in
            WindowsShortcutOpener.explainArchiveMember(window, file)
        })
        // Is handed the target item-actions.shortcuts already resolved, so an alias to a shortcut gets the same checks.
        Shortcuts.openTarget.register("windows-shortcuts.alias-target", handles: { window, target in
            FileItem(url: target).map { WindowsShortcutOpener.open(window, $0) } ?? false
        })
        // After item-actions.shortcuts and archives.open-file: an alias named x.lnk is still an alias.
        InteractionHooks.openFile.register("windows-shortcuts.open", order: .late, handles: { window, file in
            WindowsShortcutOpener.open(window, file)
        })
        // After item-actions.shortcut-arrow, for the same reason. Name and flags only: this runs per row.
        InteractionHooks.decorateIcon.register("windows-shortcuts.arrow", order: .late) { item, icon, size in
            guard item.windowsShortcutKind != nil else { return nil }
            return Shortcuts.withArrowBadge(icon, size: size)
        }
        PropertiesTabs.extraTabs.add("windows-shortcuts.tab") { tabs, context in
            guard WindowsShortcutTab.applies(to: context.0) else { return tabs }
            var tabs = tabs
            tabs.insert(WindowsShortcutTab(model: context.0), at: min(1, tabs.count))
            return tabs
        }
        DebugScript.registerLogger("windows-shortcuts.log") { _ in
            "windows shortcuts: \(WindowsShortcutOpener.lastAlert ?? "no alert")"
        }
    }
}
