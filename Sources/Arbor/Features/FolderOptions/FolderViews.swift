import AppKit
import ArborCore

/// Folder Options state files (Application Support/Arbor); headless runs stay in memory unless `ARBOR_STATE_DIR` is set.
enum FolderOptionsStorage {
    static let directory: URL? = {
        if let dir = Automation.environment["ARBOR_STATE_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if AppDelegate.isHeadless { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Arbor")
    }()

    static func url(_ name: String) -> URL? { directory?.appendingPathComponent(name) }

    /// One serial queue for state-file writes, so they never block the main thread or interleave.
    static let writeQueue = DispatchQueue(label: "arbor.folder-options.state", qos: .utility)
}

/// Per-folder views (FE-041, FE-052, FE-248). Precedence:
/// - Folder type: Properties › Customize (`FolderTemplateStore`) → Downloads → known folders → discovery (also `ViewOptions.folderKindResolver`).
/// - View mode and sort: app default → template → this folder.
/// - Columns and Group by: the kind's column set (`ViewOptions`) → this folder.
/// Keyed by volume UUID + file number (path fallback), saved in FolderViews.json; nothing is written into folders.
final class FolderViews {
    static let shared = FolderViews()

    /// A location that isn't a folder but keeps a view like one.
    struct VirtualFolder {
        let identity: FolderIdentity
        let template: FolderTemplate
        /// Added to the template's columns until the user saves their own.
        let extraColumns: [ColumnID]
    }

    /// Lets a non-folder location use the saved-view system (libraries).
    static let virtualFolders = Handlers<Location, VirtualFolder>(
        "FolderViews.virtualFolders", "A non-folder location that keeps a saved view like a folder (libraries).",
        signature: "(location) -> VirtualFolder?")

    let store = FolderViewStore(fileURL: FolderOptionsStorage.url("FolderViews.json"))

    final class Tracked {
        let key: String
        let name: String
        let identity: FolderIdentity
        let type: FolderTemplateDetector.Resolution
        let virtual: VirtualFolder?
        var resolved: ResolvedViewSettings
        init(key: String, name: String, identity: FolderIdentity, type: FolderTemplateDetector.Resolution, virtual: VirtualFolder?,
             resolved: ResolvedViewSettings) {
            self.key = key
            self.name = name
            self.identity = identity
            self.type = type
            self.virtual = virtual
            self.resolved = resolved
        }
        var template: FolderTemplate { type.template }
    }

    struct Info {
        let name: String
        let template: FolderTemplate
        let chosen: Bool
        let source: ViewSettingsSource
        /// A virtual folder's extra columns would leak into every folder of the type.
        let canApplyToFolders: Bool
    }

    private let tracked = NSMapTable<TabState, Tracked>.weakToStrongObjects()
    private var applyDepth = 0
    private var isApplying: Bool { applyDepth > 0 }
    private var saveScheduled = false

    func install() {
        ViewOptions.folderKindResolver.provide("folder-options.folder-type") { location, items in
            Self.viewType(location, items)?.kind ?? ViewOptions.defaultKind(location, items)
        }
        ViewOptions.columnsEdited.register("folder-options.folder-columns") { [unowned self] options in
            self.columnsEdited(options) ? true : nil
        }
        WindowHooks.willDisplay.observe("folder-options.folder-views") { [unowned self] window, tab, location, changed in
            self.willDisplay(window, tab, location, changed)
        }
        WindowHooks.viewStateChanged.observe("folder-options.remember-view") { [unowned self] window, tab in self.record(window, tab) }
        NotificationCenter.default.addObserver(forName: PropertiesFeature.folderTemplateChanged, object: nil, queue: .main) { [unowned self] _ in
            self.reresolveAll(redetect: true)
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                FolderIdentityCache.volumesChanged()
            }
        }
    }

    /// The folder's type: Properties' choice first, then discovery.
    static func folderType(_ url: URL, _ items: [FileItem]) -> FolderTemplateDetector.Resolution {
        FolderTemplateDetector.resolve(folder: url, items: items,
                                       chosen: FolderTemplateStore(defaults: Prefs.store).effectiveTemplate(for: url))
    }

    /// A folder's or virtual folder's type; nil for places without a view of their own.
    private static func viewType(_ location: Location, _ items: [FileItem]) -> FolderTemplateDetector.Resolution? {
        if let virtual = virtualFolders.first(location) {
            return FolderTemplateDetector.Resolution(template: virtual.template, kind: virtual.template.folderKind, chosen: false)
        }
        return location.folderURL.map { folderType($0, items) }
    }

    // MARK: Resolving

    private func willDisplay(_ window: BrowserWindowController, _ tab: TabState, _ location: Location, _ changed: Bool) {
        let virtual = Self.virtualFolders.first(location)
        guard let items = tab.items, virtual != nil || location.isFolder else {
            if changed { tracked.removeObject(forKey: tab) }
            return
        }
        if !changed, tracked.object(forKey: tab)?.key == location.key { return }
        guard let type = Self.viewType(location, items),
              let identity = virtual?.identity ?? location.folderURL.map(FolderIdentity.of) else { return }
        let entry = Tracked(key: location.key, name: location.displayName, identity: identity, type: type, virtual: virtual,
                            resolved: resolve(type.template, identity))
        tracked.setObject(entry, forKey: tab)
        apply(entry, to: tab)
        if store.isDirty { scheduleSave() }
    }

    private func resolve(_ template: FolderTemplate, _ identity: FolderIdentity) -> ResolvedViewSettings {
        ViewSettingsResolver.resolve(template: template, applied: store.templateDefault(template), override: store.override(for: identity))
    }

    /// Puts the resolved settings into the tab: mode and sort, then the Details columns and Group by.
    private func apply(_ entry: Tracked, to tab: TabState) {
        let settings = entry.resolved.settings
        if let mode = settings.viewMode.flatMap(ViewMode.init(rawValue:)) { tab.viewMode = mode }
        tab.sortOrder = settings.sortOrder
        let options = ViewOptions.options(for: tab)     // starts from the folder kind's column set
        if let columns = settings.columns {
            options.columns = ColumnSet(columns, groupBy: options.columns.groupBy, groupAscending: options.columns.groupAscending)
        } else {
            entry.virtual?.extraColumns.forEach { options.columns.setVisible($0, true) }
        }
        if let group = settings.groupBy {
            options.groupBy = group.isEmpty ? nil : ColumnID(group)
            options.groupAscending = settings.groupAscending ?? true
        }
        tab.invalidateVisibleItems()
    }

    // MARK: Recording

    /// What the tab shows now, as a folder view.
    private func snapshot(_ tab: TabState) -> FolderViewSettings {
        let options = ViewOptions.options(for: tab)
        var settings = FolderViewSettings(viewMode: tab.viewMode.rawValue, groupBy: options.groupBy?.rawValue ?? "",
                                          groupAscending: options.groupAscending, columns: options.columns.columns)
        settings.setSort(tab.sortOrder)
        return settings
    }

    /// The user changed view mode, sort, Group by or columns: save it for this folder.
    private func record(_ window: BrowserWindowController, _ tab: TabState) {
        guard !isApplying, let entry = tracked.object(forKey: tab), tab.displayedLocation?.key == entry.key else { return }
        let settings = snapshot(tab)
        store.setOverride(settings, for: entry.identity, template: entry.template)
        entry.resolved = resolve(entry.template, entry.identity)
        scheduleSave()
    }

    /// Column edits (Choose Details, header menu, resize, reorder) belong to the folder, like Explorer.
    private func columnsEdited(_ options: TabViewOptions) -> Bool {
        for window in Self.windows {
            for tab in window.tabs where ViewOptions.options(for: tab) === options && tracked.object(forKey: tab) != nil {
                record(window, tab)
                return true
            }
        }
        return false
    }

    // MARK: Folder Options actions

    static var windows: [BrowserWindowController] { (NSApp.delegate as? AppDelegate)?.controllers ?? [] }

    func info(for window: BrowserWindowController) -> Info? {
        guard !window.tabs.isEmpty, let entry = tracked.object(forKey: window.activeTab),
              window.activeTab.displayedLocation?.key == entry.key else { return nil }
        return Info(name: entry.name, template: entry.template, chosen: entry.type.chosen, source: entry.resolved.source,
                    canApplyToFolders: entry.virtual == nil)
    }

    var savedCount: Int { store.count }
    var hasSavedViews: Bool { store.count > 0 || !store.appliedTemplates.isEmpty }

    /// "Apply to Folders": this view becomes its type's default; saved views of that type are dropped.
    func applyToFolders(from window: BrowserWindowController) {
        let tab = window.activeTab
        guard let entry = tracked.object(forKey: tab), entry.virtual == nil else { return }
        let current = snapshot(tab)
        let options = ViewOptions.options(for: tab)
        store.applyToFolders(FolderViewSettings(viewMode: current.viewMode, sortKey: current.sortKey, ascending: current.ascending,
                                                foldersFirst: current.foldersFirst), template: entry.template)
        store.setOverride(nil, for: entry.identity)
        ViewOptions.setColumnSet(ColumnSet(options.columns.columns, groupBy: options.groupBy, groupAscending: options.groupAscending),
                                 for: entry.type.kind)
        ViewOptions.forgetGroupMemory()
        scheduleSave()
        reresolveAll(redetect: false)
    }

    /// "Reset Folders": every folder goes back to its type's built-in view and column set.
    func resetFolders() {
        store.resetAll()
        ViewOptions.resetColumnSets()
        ViewOptions.forgetGroupMemory()
        scheduleSave()
        reresolveAll(redetect: false)
    }

    /// Removes this folder's own saved view (View menu).
    func resetFolder(in window: BrowserWindowController) {
        guard let entry = tracked.object(forKey: window.activeTab) else { return }
        store.setOverride(nil, for: entry.identity)
        scheduleSave()
        reresolveAll(redetect: false)
    }

    /// A virtual folder's type changed or it was deleted: its saved view no longer applies.
    func forgetSavedView(_ identity: FolderIdentity, locationKey: String) {
        store.setOverride(nil, for: identity)
        ViewOptions.forgetGroupMemory(forKey: locationKey)
        scheduleSave()
    }

    /// A renamed virtual folder keeps its saved view.
    func moveSavedView(from old: FolderIdentity, to new: FolderIdentity, oldLocationKey: String) {
        store.moveOverride(from: old, to: new)
        ViewOptions.forgetGroupMemory(forKey: oldLocationKey)
        scheduleSave()
    }

    /// Tabs showing this virtual folder pick up its new type; re-applying resets filters, so other tabs are left alone.
    func reapplyOpenViews(locationKey: String) { reresolveAll(redetect: true, onlyKey: locationKey) }

    /// Re-applies views to open folder tabs after the database, column sets or a folder's template changed.
    private func reresolveAll(redetect: Bool, onlyKey: String? = nil) {
        for window in Self.windows {
            for tab in window.tabs {
                guard let old = tracked.object(forKey: tab), onlyKey == nil || old.key == onlyKey, let location = tab.displayedLocation,
                      let type = redetect ? Self.viewType(location, tab.items ?? []) : old.type else { continue }
                let virtual = Self.virtualFolders.first(location)
                let entry = Tracked(key: old.key, name: old.name, identity: old.identity, type: type, virtual: virtual,
                                    resolved: resolve(type.template, old.identity))
                tracked.setObject(entry, forKey: tab)
                applyDepth += 1
                ViewOptions.reset(tab)
                apply(entry, to: tab)
                if tab === window.activeTab, !tab.showsPage {
                    let mode = tab.viewMode
                    window.setSortOrder(tab.sortOrder)
                    window.setViewMode(mode)
                }
                applyDepth -= 1
            }
        }
    }

    // MARK: Saving

    func scheduleSave() {
        guard !saveScheduled, store.fileURL != nil else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow(sync: false)
        }
    }

    func saveNow(sync: Bool) {
        guard let url = store.fileURL, let data = store.takeChanges() else { return }
        let write = { try? FolderViewStore.write(data, to: url) }
        if sync { FolderOptionsStorage.writeQueue.sync { _ = write() } } else { FolderOptionsStorage.writeQueue.async { _ = write() } }
    }

    // MARK: Debug

    func debugLine(_ window: BrowserWindowController) -> String {
        guard !window.tabs.isEmpty, let entry = tracked.object(forKey: window.activeTab) else { return "folder view: (not a folder)" }
        let tab = window.activeTab
        let options = ViewOptions.options(for: tab)
        let cols = options.columns.columns.map { "\($0.id.rawValue):\(Int($0.width))" }.joined(separator: ",")
        return "folder view: source=\(entry.resolved.source.description) template=\(entry.template.rawValue)"
            + "\(entry.type.chosen ? "(chosen)" : "") kind=\(entry.type.kind.rawValue) mode=\(tab.viewMode.rawValue) "
            + "sort=\(tab.sortOrder.primaryColumn.rawValue)\(tab.sortOrder.ascending ? "↑" : "↓") "
            + "group=\(options.groupBy?.rawValue ?? "none") saved=\(store.count) "
            + "applied=\(store.appliedTemplates.map(\.rawValue).joined(separator: ",")) columns=\(cols)"
    }
}
