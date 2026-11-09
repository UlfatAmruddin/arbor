import Foundation

/// The address bar's places (reference §1.1): newest first, no duplicates and no searches.
public struct RecentLocations: Sendable, Equatable {
    /// Keeps the key so nothing recomputes it: that can ask the disk, and a restored entry may name a volume that is gone.
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let location: Location

        /// Nil for anything `record` would not have kept. Strings only, no disk access.
        init?(storedKey key: String) {
            guard RecentLocations.isStorable(key), let location = Location(key: key) else { return nil }
            if case .search = location { return nil }
            if case .folder = location, !Self.isNormalFolderKey(key) { return nil }
            self.key = key
            self.location = location
        }

        fileprivate init(key: String, location: Location) {
            self.key = key
            self.location = location
        }

        /// Nil unless the entry is a folder.
        public var folderPath: String? {
            guard key.hasPrefix(Self.folderPrefix) else { return nil }
            return String(key.dropFirst(Self.folderPrefix.count))
        }

        private static let folderPrefix = "folder:"

        /// `standardizedFileURL` looks up symbolic links to resolve a `..`, so one in a stored key could reach a share.
        private static func isNormalFolderKey(_ key: String) -> Bool {
            let parts = key.dropFirst(folderPrefix.count).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            return key == folderPrefix + "/" || !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
        }
    }

    /// Long enough for any real path, and it keeps the file's size predictable.
    static let keyByteLimit = 4_096

    public private(set) var records: [Entry] = []
    public let limit: Int

    public init(limit: Int = 12) { self.limit = max(1, limit) }

    public var entries: [Location] { records.map(\.location) }

    /// The key that was recorded, or nil when the place isn't one to remember.
    @discardableResult
    public mutating func record(_ location: Location) -> String? {
        if case .search = location { return nil }
        let key = location.key
        guard Self.isStorable(key) else { return nil }
        records.removeAll { $0.key == key }
        records.insert(Entry(key: key, location: location), at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
        return key
    }

    /// Adds places remembered earlier behind what this session already visited.
    public mutating func adoptOlder(_ older: [Entry]) {
        let present = Set(records.map(\.key))
        records += older.lazy.filter { !present.contains($0.key) }.prefix(limit - records.count)
    }

    public mutating func clear() { records.removeAll() }

    static func isStorable(_ key: String) -> Bool {
        key.utf8.count <= keyByteLimit && !key.unicodeScalars.contains(where: PathCompletion.isControl)
    }
}
