import AppKit
import CoreServices
import ArborCore

/// A Quick access tile: a pinned or frequently used folder.
struct HomeTile: Equatable {
    let url: URL
    let name: String
    /// The folder's location, shown under the name (its parent folder).
    let subtitle: String
    let isPinned: Bool

    var item: FileItem { FileItem(url: url, name: name, isFolder: true, typeDescription: "Folder") }
}

/// A Favorites or Recent row: the real item plus the date and location Home shows.
struct HomeRow: Equatable {
    let item: FileItem
    let date: Date?
    let location: String
}

struct HomeSnapshot {
    var quickAccess: [HomeTile] = []
    var favorites: [HomeRow] = []
    var recent: [HomeRow] = []
    var showsRecent = true
    var showsFrequent = true
    /// Spotlight couldn't be asked (headless run without a scope, or the query failed).
    var spotlightUsed = false

    var itemCount: Int { quickAccess.count + favorites.count + (showsRecent ? recent.count : 0) }
}

/// Builds Home's content off the main thread: resolves references, stats files and asks
/// Spotlight for recently used files (spec §15: no slow I/O on the main thread).
enum HomeLoader {
    /// The folder Spotlight searches for recent files: the user's home. Headless runs use
    /// `ARBOR_RECENT_SPOTLIGHT_SCOPE` (a fixture) or skip Spotlight, so tests never list real files.
    static var spotlightScope: URL? {
        let env = ProcessInfo.processInfo.environment
        if let scope = env["ARBOR_RECENT_SPOTLIGHT_SCOPE"] { return scope.isEmpty ? nil : URL(fileURLWithPath: scope) }
        return AppDelegate.isHeadless ? nil : FileManager.default.homeDirectoryForCurrentUser
    }

    @discardableResult
    static func load(completion: @escaping (HomeSnapshot) -> Void) -> LoadHandle {
        let handle = LoadHandle()
        // Inputs are read on the main thread (preferences), the rest happens in the background.
        let pins = QuickAccess.urls
        let pinRefs = HomeStore.pinReferences
        let showsFrequent = Prefs.showFrequentFolders
        let showsRecent = Prefs.showRecentFiles
        let pinnedPaths = Set(pins.map { HomePaths.normalized($0.path) })
        let frequent = showsFrequent
            ? HomeStore.frequency.ranked(now: Date(), limit: HomeStore.frequentLimit * 2, excluding: pinnedPaths) : []
        let favorites = HomeStore.favorites
        let log = HomeStore.recentLog
        let removed = HomeStore.removedFromRecent
        let clearedAt = HomeStore.clearedAt
        let cutoff = HomeStore.recentCutoff
        let scope = spotlightScope

        DispatchQueue.global(qos: .userInitiated).async {
            var snapshot = HomeSnapshot(showsRecent: showsRecent, showsFrequent: showsFrequent)
            var pinMoves: [String: String] = [:]
            var favoriteMoves: [String: String] = [:]
            let fm = FileManager.default

            // Quick access: pins in their order, then frequent folders.
            for pin in pins {
                var url = pin.standardizedFileURL
                let key = HomePaths.normalized(url.path)
                if !fm.fileExists(atPath: url.path) {
                    guard let moved = pinRefs[key]?.resolve() else { continue }   // gone: hidden like the tree does
                    pinMoves[key] = moved.path
                    url = moved
                }
                snapshot.quickAccess.append(tile(url, pinned: true))
            }
            var frequentCount = 0
            for path in frequent where frequentCount < HomeStore.frequentLimit {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                snapshot.quickAccess.append(tile(URL(fileURLWithPath: path), pinned: false))
                frequentCount += 1
            }
            if handle.isCancelled { return }

            // Favorites keep their identity across renames and moves.
            for ref in favorites {
                guard let url = ref.resolve(), let item = FileItem(url: url) else { continue }
                if HomePaths.normalized(url.path) != ref.path { favoriteMoves[ref.path] = url.path }
                snapshot.favorites.append(row(item, date: item.modified))
            }
            if handle.isCancelled { return }

            // Recent: files opened in Arbor plus Spotlight's "last used" dates in the home folder.
            if showsRecent {
                let arbor = log.records.compactMap { record -> RecentEntry? in
                    guard let url = record.reference.resolve() else { return nil }
                    return RecentEntry(path: url.path, date: record.date, source: .arbor)
                }
                var spotlight: [RecentEntry] = []
                if let scope {
                    spotlight = spotlightRecents(scope: scope, since: cutoff, handle: handle)
                    snapshot.spotlightUsed = true
                }
                let merged = RecentMerge.merge([arbor, spotlight], removed: removed, clearedAt: clearedAt,
                                               cutoff: cutoff, limit: HomeStore.recentLimit * 2)
                for entry in merged where snapshot.recent.count < HomeStore.recentLimit {
                    guard let item = FileItem(url: URL(fileURLWithPath: entry.path)), !item.isFolder else { continue }
                    snapshot.recent.append(row(item, date: entry.date))
                }
            }
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                HomeStore.applyMoves(favorites: favoriteMoves, pins: pinMoves)
                completion(snapshot)
            }
        }
        return handle
    }

    private static func tile(_ url: URL, pinned: Bool) -> HomeTile {
        let parent = url.deletingLastPathComponent()
        let subtitle = url.path == "/" ? "This Mac" : FileManager.default.displayName(atPath: parent.path)
        return HomeTile(url: url, name: FileManager.default.displayName(atPath: url.path), subtitle: subtitle, isPinned: pinned)
    }

    private static func row(_ item: FileItem, date: Date?) -> HomeRow {
        HomeRow(item: item, date: date, location: (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
    }

    /// Files whose Spotlight "last used" date is within the cutoff, newest first, bounded.
    static func spotlightRecents(scope: URL, since: Date, handle: LoadHandle) -> [RecentEntry] {
        let days = max(1, Int((Date().timeIntervalSince(since) / 86_400).rounded()))
        let text = "kMDItemLastUsedDate >= $time.today(-\(days))" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [scope.path] as CFArray, 0)
        MDQuerySetMaxCount(query, 600)
        guard !handle.isCancelled, MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: [RecentEntry] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                  RecentMerge.isEligible(path: path, home: home) else { continue }
            if let types = MDItemCopyAttribute(item, kMDItemContentTypeTree) as? [String],
               types.contains("public.folder") || types.contains("com.apple.application") { continue }
            result.append(RecentEntry(path: path, date: date, source: .spotlight))
        }
        return result
    }
}
