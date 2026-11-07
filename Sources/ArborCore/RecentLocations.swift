import Foundation

/// The address bar's "Recent locations" list (the ▾ at its right end, reference §1.1): places visited
/// in this session, most recent first, without duplicates. Search results are left out (they are
/// reached again from the search box).
public struct RecentLocations: Sendable, Equatable {
    public private(set) var entries: [Location] = []
    public let limit: Int

    public init(limit: Int = 12) { self.limit = max(1, limit) }

    public mutating func record(_ location: Location) {
        if case .search = location { return }
        entries.removeAll { $0 == location }
        entries.insert(location, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Drops places that no longer exist (deleted folders, unmounted volumes).
    public mutating func prune(_ stillExists: (Location) -> Bool) {
        entries.removeAll { !stillExists($0) }
    }
}
