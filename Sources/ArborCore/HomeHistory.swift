import Foundation

// Home logic (FE-069–FE-072, FE-206, FE-239). Removing an entry never touches the file it points at.

/// A persistent pointer to a real item (spec §3.2: a path alone is not identity). File ID, bookmark and
/// last path follow renames and moves without mistaking a new item at the old path for the original.
public struct ItemReference: Codable, Equatable, Sendable {
    /// Callers may update it after `resolve()` finds the item elsewhere.
    public var path: String
    public var bookmark: Data?
    /// Inode and `statfs.f_fsid` at creation.
    public var fileID: UInt64?
    public var fsid: [Int32]?

    public init(path: String, bookmark: Data? = nil, fileID: UInt64? = nil, fsid: [Int32]? = nil) {
        self.path = HomePaths.normalized(path)
        self.bookmark = bookmark
        self.fileID = fileID
        self.fsid = fsid
    }

    /// No UI, no mounting.
    public init(url: URL) {
        let url = url.standardizedFileURL
        let id = Self.identity(of: url.path)
        self.init(path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                  fileID: id?.fileID, fsid: id?.fsid)
    }

    static func identity(of path: String) -> (fileID: UInt64, fsid: [Int32])? {
        var st = stat()
        var sf = statfs()
        guard stat(path, &st) == 0, statfs(path, &sf) == 0 else { return nil }
        return (UInt64(st.st_ino), [sf.f_fsid.val.0, sf.f_fsid.val.1])
    }

    static func isMounted(_ fsid: [Int32]) -> Bool {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return false }
        return (0..<Int(count)).contains { list[$0].f_fsid.val.0 == fsid[0] && list[$0].f_fsid.val.1 == fsid[1] }
    }

    /// Nil when the item is gone or in a Trash.
    public func resolve() -> URL? {
        let fm = FileManager.default
        // 1. By file ID on its volume: follows renames and moves, never fooled by a replacement.
        if let fileID, let fsid, fsid.count == 2 {
            var id = fsid_t(val: (fsid[0], fsid[1]))
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fsgetpath(&buffer, buffer.count, &id, fileID) > 0 {
                let found = String(cString: buffer)
                return HomePaths.isInTrash(found) ? nil : URL(fileURLWithPath: found).standardizedFileURL
            }
            // The volume is mounted but the ID is gone: the original was deleted.
            if errno == ENOENT, Self.isMounted(fsid) { return nil }
        }
        // 2. Bookmark (other volumes, or IDs that changed after a remount).
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let url = url.standardizedFileURL
                guard !HomePaths.isInTrash(url.path), fm.fileExists(atPath: url.path) else { return nil }
                return url
            }
        }
        // 3. The last known path.
        guard !HomePaths.isInTrash(path), fm.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

public enum HomePaths {
    /// Path without a trailing slash, symlinks in /private collapsed (so /tmp == /private/tmp).
    public static func normalized(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if p.hasPrefix("/private/var/") || p.hasPrefix("/private/tmp/") || p == "/private/tmp" {
            p = String(p.dropFirst("/private".count))
        }
        return p
    }

    public static func isInTrash(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }
}

// MARK: - Frequent folders

/// Frecency-ranked folder visits for Quick access; when full, the lowest score is dropped.
public struct FolderFrequency: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var count: Int
        public var lastVisit: Date
    }

    public private(set) var entries: [Entry]
    public var capacity: Int

    /// A visit's weight halves every `halfLifeDays`, so old habits fade.
    public static let halfLifeDays: Double = 30

    public init(entries: [Entry] = [], capacity: Int = 200) {
        self.entries = entries
        self.capacity = max(1, capacity)
    }

    public mutating func recordVisit(_ path: String, at date: Date) {
        let key = HomePaths.normalized(path)
        if let i = entries.firstIndex(where: { $0.path == key }) {
            entries[i].count += 1
            entries[i].lastVisit = max(entries[i].lastVisit, date)
        } else {
            entries.append(Entry(path: key, count: 1, lastVisit: date))
        }
        while entries.count > capacity {
            guard let worst = entries.indices.min(by: { lessImportant(entries[$0], entries[$1], now: date) }) else { break }
            entries.remove(at: worst)
        }
    }

    public mutating func remove(_ path: String) {
        let key = HomePaths.normalized(path)
        entries.removeAll { $0.path == key }
    }

    /// Follows a renamed or moved folder.
    public mutating func rename(_ old: String, to new: String) {
        let from = HomePaths.normalized(old), to = HomePaths.normalized(new)
        guard let i = entries.firstIndex(where: { $0.path == from }) else { return }
        if let j = entries.firstIndex(where: { $0.path == to }) {
            entries[j].count += entries[i].count
            entries[j].lastVisit = max(entries[j].lastVisit, entries[i].lastVisit)
            entries.remove(at: i)
        } else {
            entries[i].path = to
        }
    }

    public mutating func clear() { entries.removeAll() }

    public static func score(_ entry: Entry, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(entry.lastVisit)) / 86_400
        return Double(entry.count) * pow(0.5, ageDays / halfLifeDays)
    }

    private func lessImportant(_ a: Entry, _ b: Entry, now: Date) -> Bool {
        let sa = Self.score(a, now: now), sb = Self.score(b, now: now)
        if sa != sb { return sa < sb }
        return a.lastVisit < b.lastVisit
    }

    /// Best first; skips folders under `minimumVisits` and those in `excluding` (pinned or removed).
    public func ranked(now: Date, limit: Int, minimumVisits: Int = 2, excluding: Set<String> = []) -> [String] {
        let excluded = Set(excluding.map(HomePaths.normalized))
        return entries
            .filter { $0.count >= minimumVisits && !excluded.contains($0.path) }
            .sorted { a, b in
                let sa = Self.score(a, now: now), sb = Self.score(b, now: now)
                if sa != sb { return sa > sb }
                if a.lastVisit != b.lastVisit { return a.lastVisit > b.lastVisit }
                return a.path < b.path
            }
            .prefix(max(0, limit))
            .map(\.path)
    }
}

// MARK: - Recent files

public struct RecentEntry: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case arbor, spotlight }
    public var path: String
    public var date: Date
    public var source: Source

    public init(path: String, date: Date, source: Source) {
        self.path = HomePaths.normalized(path)
        self.date = date
        self.source = source
    }
}

/// Files opened through Arbor, newest first, bounded.
public struct RecentLog: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var reference: ItemReference
        public var date: Date
    }

    public private(set) var records: [Record]
    public var capacity: Int

    public init(records: [Record] = [], capacity: Int = 100) {
        self.records = records
        self.capacity = max(1, capacity)
    }

    public mutating func record(_ reference: ItemReference, at date: Date) {
        records.removeAll { $0.reference.path == reference.path }
        records.insert(Record(reference: reference, date: date), at: 0)
        if records.count > capacity { records.removeLast(records.count - capacity) }
    }

    public mutating func clear() { records.removeAll() }
}

public enum RecentMerge {
    /// Newest first, keyed by resolved path. `removed`: hidden until used again after removal;
    /// `clearedAt`: hides everything up to then; `cutoff`: oldest date shown.
    public static func merge(_ lists: [[RecentEntry]], removed: [String: Date] = [:], clearedAt: Date? = nil,
                             cutoff: Date, limit: Int) -> [RecentEntry] {
        var newest: [String: RecentEntry] = [:]
        for entry in lists.joined() {
            guard entry.date >= cutoff else { continue }
            if let clearedAt, entry.date <= clearedAt { continue }
            if let removedAt = removed[entry.path], entry.date <= removedAt { continue }
            if let existing = newest[entry.path] {
                // Keep the newest date; on a tie prefer Arbor's own record.
                if entry.date > existing.date || (entry.date == existing.date && entry.source == .arbor) { newest[entry.path] = entry }
            } else {
                newest[entry.path] = entry
            }
        }
        return newest.values
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.path < $1.path }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Drops removal marks older than the cutoff (they hide nothing), keeping the map bounded.
    public static func prune(removed: [String: Date], cutoff: Date, capacity: Int = 500) -> [String: Date] {
        let kept = removed.filter { $0.value >= cutoff }
        guard kept.count > capacity else { return kept }
        return Dictionary(uniqueKeysWithValues: kept.sorted { $0.value > $1.value }.prefix(capacity).map { ($0.key, $0.value) })
    }

    /// Recent never lists hidden items, ~/Library or Trash contents, or apps.
    public static func isEligible(path: String, home: String) -> Bool {
        let p = HomePaths.normalized(path)
        let parts = p.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if p.hasPrefix(HomePaths.normalized(home) + "/Library/") { return false }
        if parts.contains(where: { $0.hasSuffix(".app") }) { return false }
        return true
    }
}
