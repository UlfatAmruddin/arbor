import Foundation

/// Address bar "Recent locations" (reference §1.1): this session's places, newest first, no duplicates
/// and no searches.
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

    public mutating func clear() { entries.removeAll() }

    public mutating func prune(_ stillExists: (Location) -> Bool) {
        entries.removeAll { !stillExists($0) }
    }
}
