import Foundation

public enum SortKey: String, CaseIterable, Sendable {
    case name, dateModified, type, size

    public var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

public struct FileSortOrder: Equatable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    /// Folders stay above files regardless of sort column and direction (proposed improvement, FE-053).
    public var foldersFirst: Bool
    /// Sort by a Details column that isn't a `SortKey` (Date created, Dimensions…). Overrides `key`.
    public var column: ColumnID?
    /// Further keys for ties, most important first (FE-235). The previous primary column becomes
    /// the first of these when the user sorts by another column.
    public var thenBy: [SortCriterion] = []

    public init(key: SortKey = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    /// The column the order is primarily by.
    public var primaryColumn: ColumnID { column ?? ColumnID(key.rawValue) }

    /// Sorts by `column`. With `keepPrevious`, the old primary key becomes the first tie-breaker
    /// (at most `maxSecondary` are kept).
    public mutating func setPrimary(_ column: ColumnID, ascending: Bool, keepPrevious: Bool = true, maxSecondary: Int = 2) {
        let previous = SortCriterion(primaryColumn, ascending: self.ascending)
        if let key = SortKey(rawValue: column.rawValue) {
            self.key = key
            self.column = nil
        } else {
            self.column = column
        }
        self.ascending = ascending
        var rest = thenBy.filter { $0.column != column && $0.column != previous.column }
        if keepPrevious, previous.column != column { rest.insert(previous, at: 0) }
        thenBy = Array(rest.prefix(maxSecondary))
    }
}

/// One sort key with its direction.
public struct SortCriterion: Equatable, Sendable, Codable {
    public var column: ColumnID
    public var ascending: Bool
    public init(_ column: ColumnID, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// Deterministic ordering. Comparisons only use values already in memory, never disk I/O.
///
/// Names use Finder-style natural ordering (`localizedStandardCompare`). That is NOT a
/// claim of exact parity with Explorer's comparator; see spec §6.3.
public enum FileSorter {
    /// Values for columns that aren't in the listing (set by the app to its metadata cache).
    /// Missing values (still loading) sort last.
    nonisolated(unsafe) public static var columnValues: ColumnValueLookup?

    public static func sorted(_ items: [FileItem], by order: FileSortOrder) -> [FileItem] {
        items.sorted { precedes($0, $1, order) }
    }

    public static func precedes(_ a: FileItem, _ b: FileItem, _ order: FileSortOrder) -> Bool {
        if order.foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
        switch compareKey(a, b, order) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: break
        }
        for criterion in order.thenBy {
            switch compareColumn(a, b, criterion.column, ascending: criterion.ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        // Stable tie-breakers, always ascending.
        let byName = a.name.localizedStandardCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        if a.name != b.name { return a.name < b.name }
        return a.url.path < b.url.path
    }

    /// Result already accounts for direction. Missing values always sort last.
    static func compareKey(_ a: FileItem, _ b: FileItem, _ order: FileSortOrder) -> ComparisonResult {
        func directed(_ r: ComparisonResult) -> ComparisonResult { order.ascending ? r : r.reversed }
        if let column = order.column { return compareColumn(a, b, column, ascending: order.ascending) }
        switch order.key {
        case .name: return directed(a.name.localizedStandardCompare(b.name))
        case .type: return directed(a.typeDescription.localizedStandardCompare(b.typeDescription))
        case .dateModified: return compareOptional(a.modified, b.modified, directed)
        case .size: return compareOptional(a.size, b.size, directed)
        }
    }

    /// Any catalog column, via `columnValues` for non-listing columns.
    static func compareColumn(_ a: FileItem, _ b: FileItem, _ column: ColumnID, ascending: Bool) -> ComparisonResult {
        if let key = SortKey(rawValue: column.rawValue) {
            return compareKey(a, b, FileSortOrder(key: key, ascending: ascending, foldersFirst: false))
        }
        let x = ColumnValues.sortValue(ColumnValues.value(a, column, lookup: columnValues))
        let y = ColumnValues.sortValue(ColumnValues.value(b, column, lookup: columnValues))
        return compareOptional(x, y) { ascending ? $0 : $0.reversed }
    }

    static func compareOptional<T: Comparable>(
        _ x: T?, _ y: T?, _ directed: (ComparisonResult) -> ComparisonResult
    ) -> ComparisonResult {
        switch (x, y) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?):
            if x < y { return directed(.orderedAscending) }
            if x > y { return directed(.orderedDescending) }
            return .orderedSame
        }
    }
}

/// Filters the current folder by name. This is a filter, not a recursive search.
public enum FileFilter {
    public static func matches(_ item: FileItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return item.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    public static func apply(_ items: [FileItem], query: String) -> [FileItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return items }
        return items.filter { matches($0, query: q) }
    }
}

extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
