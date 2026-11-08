import AppKit
import ArborCore

/// App-wide preferences. Each change posts `Prefs.changed` with the key in `userInfo["key"]`.
enum Prefs {
    static let changed = Notification.Name("ArborPrefsChanged")
    private static var d: UserDefaults { store }

    /// Headless runs (ARBOR_HEADLESS) use a throwaway domain, deleted on quit, so scripts never touch real prefs.
    static let store: UserDefaults = {
        guard Automation.environment["ARBOR_HEADLESS"] != nil else { return .standard }
        sweepStaleHeadlessFiles()
        let defaults = UserDefaults(suiteName: headlessSuite) ?? .standard
        defaults.removePersistentDomain(forName: headlessSuite)
        return defaults
    }()

    /// cfprefsd may rewrite a removed headless domain; delete files of exited runs.
    private static func sweepStaleHeadlessFiles() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let prefix = "io.github.arbor-files.Arbor.headless-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count).replacingOccurrences(of: ".plist", with: "")),
                  kill(pid, 0) != 0 else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static let headlessSuite = "io.github.arbor-files.Arbor.headless-\(ProcessInfo.processInfo.processIdentifier)"

    /// Deletes the headless test domain on quit.
    static func discardHeadlessStore() {
        guard store !== UserDefaults.standard else { return }
        store.removePersistentDomain(forName: headlessSuite)
        CFPreferencesAppSynchronize(headlessSuite as CFString)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(headlessSuite).plist")
        try? FileManager.default.removeItem(at: file)
    }

    private static func set(_ value: Any, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["key": key])
    }

    static var showHidden: Bool {
        get { d.bool(forKey: "showHidden") }
        set { set(newValue, "showHidden") }
    }
    static var showExtensions: Bool {
        get { d.object(forKey: "showExtensions") as? Bool ?? true }
        set { set(newValue, "showExtensions") }
    }
    /// Right-hand pane: "" (none), "preview", "details" or a feature's pane id; one at a time, like Explorer.
    static var sidePane: String {
        get {
            if let id = d.string(forKey: "sidePane") { return id }
            return d.bool(forKey: "previewVisible") ? "preview" : ""   // v0.1 setting
        }
        set { set(newValue, "sidePane") }
    }
    /// "Compact view" row spacing, independent of the view mode.
    static var compactView: Bool {
        get { d.bool(forKey: "compactView") }
        set { set(newValue, "compactView") }
    }
    static var itemCheckBoxes: Bool {
        get { d.bool(forKey: "itemCheckBoxes") }
        set { set(newValue, "itemCheckBoxes") }
    }
    /// Navigation pane "Show libraries" (off by default like Windows 11, FE-076).
    static var showLibraries: Bool {
        get { d.bool(forKey: "showLibraries") }
        set { set(newValue, "showLibraries") }
    }
    /// Folder Options "Always show icons, never thumbnails".
    static let alwaysShowIconsKey = "alwaysShowIcons"
    static var alwaysShowIcons: Bool {
        get { d.bool(forKey: alwaysShowIconsKey) }
        set { set(newValue, alwaysShowIconsKey) }
    }
    /// View mode for new tabs.
    static var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: d.string(forKey: "viewMode") ?? "") ?? .details }
        set { set(newValue.rawValue, "viewMode") }
    }
    static var navigationPaneVisible: Bool {
        get { d.object(forKey: "navigationPaneVisible") as? Bool ?? true }
        set { set(newValue, "navigationPaneVisible") }
    }
    /// Default sort for new tabs; each tab keeps its own afterwards.
    static var sortOrder: FileSortOrder {
        get {
            FileSortOrder(key: SortKey(rawValue: d.string(forKey: "sortKey") ?? "") ?? .name,
                      ascending: d.object(forKey: "sortAscending") as? Bool ?? true,
                      foldersFirst: d.object(forKey: "foldersFirst") as? Bool ?? true)
        }
        set {
            d.set(newValue.key.rawValue, forKey: "sortKey")
            d.set(newValue.ascending, forKey: "sortAscending")
            d.set(newValue.foldersFirst, forKey: "foldersFirst")
        }
    }

    // MARK: Folder Options (FE-042, FE-043). More keys in Features/FolderOptions/FolderOptionsPrefs.swift.

    static func bool(_ key: String, default value: Bool) -> Bool { d.object(forKey: key) as? Bool ?? value }
    static func string(_ key: String, default value: String) -> String { d.string(forKey: key) ?? value }
    /// Writes a feature's own preference (nil removes it) and posts `changed`.
    static func setValue(_ value: Any?, forKey key: String) {
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["key": key])
    }

    // Privacy and "Hide empty drives" live with Home (`HomeStore.swift`).
}

/// Pinned folders shown under "Quick access" (FE-070). Pinning never copies or moves files.
enum QuickAccess {
    static let changed = Notification.Name("ArborQuickAccessChanged")
    private static let key = "quickAccessPaths"

    /// Explorer's default pins, then the Mac home folder and Applications.
    static var defaults: [URL] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory,
                                                       .picturesDirectory, .musicDirectory, .moviesDirectory]
        return dirs.compactMap { fm.urls(for: $0, in: .userDomainMask).first }
            + [fm.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Applications")]
    }

    static var urls: [URL] {
        get {
            guard let paths = Prefs.store.stringArray(forKey: key) else { return defaults }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        set {
            Prefs.store.set(newValue.map(\.path), forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func isPinned(_ url: URL) -> Bool { urls.contains { Location.folder($0) == Location.folder(url) } }
    static func pin(_ url: URL) { if !isPinned(url) { urls.append(url.standardizedFileURL) } }
    static func unpin(_ url: URL) { urls.removeAll { Location.folder($0) == Location.folder(url) } }
}
