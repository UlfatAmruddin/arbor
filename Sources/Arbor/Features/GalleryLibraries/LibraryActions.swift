import AppKit
import ArborCore

/// Create, rename, delete and restore (FE-076): the only code that sequences the store and open tabs; none of it touches a file (FE-239).
enum LibraryActions {
    private static var windows: [BrowserWindowController] { FolderViews.windows }

    private static func tabs(showing location: Location) -> [(window: BrowserWindowController, tab: TabState)] {
        windows.flatMap { window in window.tabs.filter { $0.displayedLocation == location }.map { (window, $0) } }
    }

    /// Not quiet: a quiet reload stops early on an unchanged listing, before the drop target and tracked view are refreshed.
    private static func reload(_ tab: TabState, in window: BrowserWindowController) {
        window.request(.reload, tab: tab)
        if tab === window.activeTab { window.startWatching(tab) }
    }

    private static func reason(_ attempt: () throws -> Void) -> String? {
        do {
            try attempt()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Create

    /// Asks for a name, then opens the new library and its Manage dialog.
    static func create(in window: BrowserWindowController?) {
        let initial = LibraryStore.catalog.nextAvailableName(base: L10n.tr("New Library"))
        LibraryNameSheet.present(
            title: L10n.tr("New library"), message: L10n.tr("A library shows folders from different places together. The folders stay where they are."),
            initial: initial, confirm: L10n.tr("Create"), in: window?.window,
            problem: { text in
                var trial = LibraryStore.catalog
                return reason { try trial.create(named: text) }
            },
            commit: { text in finishCreating(text, in: window) })
    }

    private static func finishCreating(_ text: String, in window: BrowserWindowController?) {
        var name = text
        do {
            try LibraryStore.edit { name = try $0.create(named: text) }
        } catch {
            NSAlert.show(L10n.tr("The library couldn't be created."), error.localizedDescription, in: window?.window)
            return
        }
        window?.navigate(to: .library(name))
        LocationsDialog(mode: .library(name)).present(in: window?.window)
    }

    // MARK: Rename

    static func rename(_ name: String, in window: BrowserWindowController?) {
        guard LibraryStore.definition(name) != nil else { reportMissing(name, in: window); return }
        LibraryNameSheet.present(
            title: L10n.tr("Rename library"), message: L10n.tr("The folders and files in this library keep their names."),
            initial: name, confirm: L10n.tr("Rename"), in: window?.window,
            problem: { text in
                var trial = LibraryStore.catalog
                return reason { try trial.rename(name, to: text) }
            },
            commit: { text in finishRenaming(name, to: text, in: window) })
    }

    private static func finishRenaming(_ old: String, to text: String, in window: BrowserWindowController?) {
        var new = old
        var followed: [(window: BrowserWindowController, tab: TabState)] = []
        do {
            try LibraryStore.edit(beforeNotifying: { followed = followRename(from: old, to: new) }) { new = try $0.rename(old, to: text) }
        } catch {
            NSAlert.show(L10n.format("Couldn't rename “%@”.", old), error.localizedDescription, in: window?.window)
            return
        }
        guard new != old else { return }
        FolderViews.shared.moveSavedView(from: LibraryLogic.viewIdentity(named: old), to: LibraryLogic.viewIdentity(named: new),
                                         oldLocationKey: Location.library(old).key)
        followed.forEach { reload($0.tab, in: $0.window) }
        for browser in windows {
            browser.reloadTabStrip()
            if !browser.tabs.isEmpty, let page = browser.activeTab.page as? LibrariesPageController { page.select(names: [new]) }
        }
    }

    /// Back, Forward and Up stay valid. Returns the tabs on screen there.
    private static func followRename(from old: String, to new: String) -> [(window: BrowserWindowController, tab: TabState)] {
        var followed: [(window: BrowserWindowController, tab: TabState)] = []
        for window in windows {
            for tab in window.tabs {
                tab.history.rewriteLocations { LibraryLogic.location($0, afterRenaming: old, to: new) }
                guard let shown = tab.displayedLocation, let moved = LibraryLogic.location(shown, afterRenaming: old, to: new) else { continue }
                tab.displayedLocation = moved
                followed.append((window, tab))
            }
        }
        return followed
    }

    // MARK: Delete

    /// Cancel is the default; the text says plainly that the files stay.
    static func confirmDelete(_ name: String, in window: BrowserWindowController?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("Delete the “%@” library?", name)
        alert.informativeText = L10n.tr("Only the library goes away. Its folders and files stay where they are, and nothing moves to the Trash.")
        let delete = alert.addButton(withTitle: L10n.tr("Delete library"))
        let cancel = alert.addButton(withTitle: L10n.tr("Cancel"))
        delete.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        AlertSheets.present(alert, in: window?.window) { response in
            guard response == .alertFirstButtonReturn else { return }
            finishDeleting(name, in: window)
        }
    }

    private static func finishDeleting(_ name: String, in window: BrowserWindowController?) {
        guard LibraryStore.definition(name) != nil else { reportMissing(name, in: window); return }
        let location = Location.library(name)
        do {
            try LibraryStore.edit(beforeNotifying: {
                for shown in tabs(showing: location) {
                    shown.window.request(.visit(.library(LibraryLogic.rootName), select: [], selectURLs: []), tab: shown.tab)
                }
            }) { $0.delete(name) }
        } catch {
            NSAlert.show(L10n.format("Couldn't delete “%@”.", name), error.localizedDescription, in: window?.window)
            return
        }
        FolderViews.shared.forgetSavedView(LibraryLogic.viewIdentity(named: name), locationKey: location.key)
    }

    // MARK: Restore

    static func restoreDefaults(in window: BrowserWindowController?) {
        var added = 0
        do {
            try LibraryStore.edit { added = $0.restoreDefaults(home: LibraryStore.home) }
        } catch {
            NSAlert.show(L10n.tr("The default libraries couldn't be restored."), error.localizedDescription, in: window?.window)
            return
        }
        window?.statusBar.setMessage(added == 0 ? L10n.tr("All the default libraries are already here.")
                                                : L10n.format("Default libraries restored: %@.", "\(added)"))
    }

    // MARK: Manage library

    /// The dialog's OK: saves the definition and makes every open tab follow it. Throws `notFound` if the library has gone.
    static func commit(_ edited: LibraryDefinition) throws {
        guard let current = LibraryStore.definition(edited.name) else { throw LibraryEditError.notFound(edited.name) }
        guard edited != current else { return }
        try LibraryStore.edit { $0.update(edited) }
        let location = Location.library(edited.name)
        if edited.template != current.template {
            FolderViews.shared.forgetSavedView(LibraryLogic.viewIdentity(named: edited.name), locationKey: location.key)
            FolderViews.shared.reapplyOpenViews(locationKey: location.key)
        }
        tabs(showing: location).forEach { reload($0.tab, in: $0.window) }
    }

    private static func reportMissing(_ name: String, in window: BrowserWindowController?) {
        NSAlert.show(LibraryEditError.notFound(name).localizedDescription, in: window?.window)
    }
}
