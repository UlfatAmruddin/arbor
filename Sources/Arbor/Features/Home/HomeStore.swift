import AppKit
import ArborCore

// MARK: - Preferences (for Folder Options › General › Privacy and View › "Hide empty drives")

/// Keys the Folder Options dialog can bind to. Each change posts `Prefs.changed` with the key.
enum HomePrefKeys {
    /// "Show recently used files" (default on). Off hides Recent and stops recording opened files.
    static let showRecentFiles = "home.showRecentFiles"
    /// "Show frequently used folders" (default on). Off hides frequent folders and stops counting visits.
    static let showFrequentFolders = "home.showFrequentFolders"
    /// "Hide empty drives" (default on): drives without media are left out of This Mac and the tree.
    static let hideEmptyDrives = "thisMac.hideEmptyDrives"
    /// Prefix for each Home section's collapsed state ("home.collapsed.recent").
    static let collapsedPrefix = "home.collapsed."
}

extension Prefs {
    static var showRecentFiles: Bool {
        get { store.object(forKey: HomePrefKeys.showRecentFiles) as? Bool ?? true }
        set { setHomeValue(newValue, HomePrefKeys.showRecentFiles) }
    }
    static var showFrequentFolders: Bool {
        get { store.object(forKey: HomePrefKeys.showFrequentFolders) as? Bool ?? true }
        set { setHomeValue(newValue, HomePrefKeys.showFrequentFolders) }
    }
    static var hideEmptyDrives: Bool {
        get { store.object(forKey: HomePrefKeys.hideEmptyDrives) as? Bool ?? true }
        set { setHomeValue(newValue, HomePrefKeys.hideEmptyDrives) }
    }
    static func isHomeSectionCollapsed(_ id: String) -> Bool { store.bool(forKey: HomePrefKeys.collapsedPrefix + id) }
    static func setHomeSectionCollapsed(_ id: String, _ collapsed: Bool) {
        setHomeValue(collapsed, HomePrefKeys.collapsedPrefix + id)
    }

    fileprivate static func setHomeValue(_ value: Any, _ key: String) {
        store.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["key": key])
    }
}

// MARK: - History, favorites and pin identity

/// What Home remembers: visits, opened files, removals, favorites, pin identities. Projection only
/// (FE-239): never moves, renames or deletes items. In `Prefs.store` (a throwaway domain in tests).
enum HomeStore {
    static let changed = Notification.Name("ArborHomeStoreChanged")
    /// Posted by "Clear history" so other features (search, operations, Back/Forward, address bar) clear theirs.
    static let historyCleared = Notification.Name("ArborHistoryCleared")

    static let recentDays = 30
    static let recentLimit = 20
    static let frequentLimit = 10

    private enum Key {
        static let frequency = "home.frequentFolders"
        static let recent = "home.recentFiles"
        static let removed = "home.recentRemoved"
        static let clearedAt = "home.historyClearedAt"
        static let favorites = "home.favorites"
        static let pins = "home.pinReferences"
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = Prefs.store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ key: String, notify: Bool = true) {
        if let data = try? JSONEncoder().encode(value) { Prefs.store.set(data, forKey: key) }
        if notify { NotificationCenter.default.post(name: changed, object: nil) }
    }

    static var frequency: FolderFrequency { load(FolderFrequency.self, Key.frequency) ?? FolderFrequency() }
    static var recentLog: RecentLog { load(RecentLog.self, Key.recent) ?? RecentLog() }
    static var removedFromRecent: [String: Date] { load([String: Date].self, Key.removed) ?? [:] }
    static var clearedAt: Date? { Prefs.store.object(forKey: Key.clearedAt) as? Date }
    static var favorites: [ItemReference] { load([ItemReference].self, Key.favorites) ?? [] }
    static var pinReferences: [String: ItemReference] { load([String: ItemReference].self, Key.pins) ?? [:] }

    static var recentCutoff: Date { Date().addingTimeInterval(-Double(recentDays) * 86_400) }

    // MARK: Recording

    /// Counts a folder visit for "frequent folders" (not volume roots, not while turned off).
    static func recordVisit(_ location: Location) {
        guard Prefs.showFrequentFolders, let url = location.folderURL, url.path != "/" else { return }
        var f = frequency
        f.recordVisit(url.path, at: Date())
        save(f, Key.frequency, notify: false)   // Home isn't on screen while another folder is.
    }

    /// Remembers files opened from Arbor for Recent.
    static func recordOpened(_ urls: [URL]) {
        guard Prefs.showRecentFiles else { return }
        var log = recentLog
        let now = Date()
        for url in urls where !HomePaths.isInTrash(url.path) { log.record(ItemReference(url: url), at: now) }
        save(log, Key.recent)
    }

    // MARK: Removing (never touches files)

    static func removeFromRecent(_ urls: [URL]) {
        var marks = RecentMerge.prune(removed: removedFromRecent, cutoff: recentCutoff)
        let now = Date()
        for url in urls { marks[HomePaths.normalized(url.path)] = now }
        save(marks, Key.removed, notify: false)
        var log = recentLog
        let paths = Set(urls.map { HomePaths.normalized($0.path) })
        log = RecentLog(records: log.records.filter { !paths.contains($0.reference.path) }, capacity: log.capacity)
        save(log, Key.recent)
    }

    /// "Remove from Quick access" for a frequent (unpinned) folder: forgets its visit count.
    static func forgetFrequentFolder(_ url: URL) {
        var f = frequency
        f.remove(url.path)
        save(f, Key.frequency)
    }

    /// "Clear history": frequent folders, Recent (incl. Spotlight's so far) and removal marks; pins and favorites stay.
    static func clearHistory() {
        save(FolderFrequency(), Key.frequency, notify: false)
        save(RecentLog(), Key.recent, notify: false)
        save([String: Date](), Key.removed, notify: false)
        Prefs.store.set(Date(), forKey: Key.clearedAt)
        NotificationCenter.default.post(name: changed, object: nil)
        NotificationCenter.default.post(name: historyCleared, object: nil)
    }

    // MARK: Favorites (files the user marked with "Add to Favorites")

    static func isFavorite(_ url: URL) -> Bool {
        let path = HomePaths.normalized(url.path)
        return favorites.contains { $0.path == path }
    }

    static func addFavorites(_ urls: [URL]) {
        var list = favorites
        for url in urls where !list.contains(where: { $0.path == HomePaths.normalized(url.path) }) {
            list.append(ItemReference(url: url))
        }
        save(list, Key.favorites)
    }

    static func removeFavorites(_ urls: [URL]) {
        let paths = Set(urls.map { HomePaths.normalized($0.path) })
        save(favorites.filter { !paths.contains($0.path) }, Key.favorites)
    }

    /// Stores paths resolved for renamed or moved favorites and pins.
    static func applyMoves(favorites moves: [String: String], pins pinMoves: [String: String]) {
        if !moves.isEmpty {
            save(favorites.map { ref in
                guard let to = moves[ref.path] else { return ref }
                var updated = ref
                updated.path = HomePaths.normalized(to)
                return updated
            }, Key.favorites, notify: false)
        }
        if !pinMoves.isEmpty {
            var refs = pinReferences
            for (from, to) in pinMoves {
                if let ref = refs.removeValue(forKey: from) { refs[HomePaths.normalized(to)] = ref }
            }
            save(refs, Key.pins, notify: false)
            QuickAccess.urls = QuickAccess.urls.map { url in
                pinMoves[HomePaths.normalized(url.path)].map { URL(fileURLWithPath: $0) } ?? url
            }
        }
    }

    /// Keeps each pinned folder's identity so renamed pins are followed (call when pins change).
    static func syncPinReferences() {
        var refs = pinReferences
        let pinned = QuickAccess.urls.map { HomePaths.normalized($0.path) }
        var changedAny = false
        for path in pinned where refs[path] == nil && FileManager.default.fileExists(atPath: path) {
            refs[path] = ItemReference(url: URL(fileURLWithPath: path))
            changedAny = true
        }
        for key in refs.keys where !pinned.contains(key) {
            refs[key] = nil
            changedAny = true
        }
        if changedAny { save(refs, Key.pins, notify: false) }
    }
}
