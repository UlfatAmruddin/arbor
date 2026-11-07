import Foundation

/// A group (FE-038) or header-filter choice (FE-039). `rank` orders buckets ascending.
public struct GroupBucket: Hashable, Sendable {
    public let id: String
    public let title: String
    public let rank: Double

    public init(id: String, title: String, rank: Double) {
        self.id = id
        self.title = title
        self.rank = rank
    }

    /// Items without a value (folders when grouping by Size). Always listed last.
    public static let unspecified = GroupBucket(id: "~unspecified", title: "Unspecified", rank: .infinity)
    /// Metadata still being read. Listed after everything else.
    public static let loading = GroupBucket(id: "~loading", title: "Loading…", rank: .infinity)

    /// Sorted last whatever the direction.
    public var isTrailing: Bool { id.hasPrefix("~") }
}

/// "Now" and the calendar (time zone, first weekday, locale) used for date buckets. Inject a fixed
/// one in tests.
public struct GroupingContext: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.now = now
        self.calendar = calendar
    }
}

/// Windows' bucket rules (docs/research/windows11-reference.md §6.1).
public enum Buckets {
    // MARK: Dates

    /// Chronological ranks: ascending = oldest first; Downloads uses descending (Today first).
    public static func date(_ date: Date?, _ ctx: GroupingContext) -> GroupBucket {
        guard let date else { return .unspecified }
        let cal = ctx.calendar
        let today = cal.startOfDay(for: ctx.now)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today),
              let yesterday = cal.date(byAdding: .day, value: -1, to: today),
              let thisWeek = cal.dateInterval(of: .weekOfYear, for: ctx.now),
              let lastWeekStart = cal.date(byAdding: .day, value: -7, to: thisWeek.start),
              let nextWeekEnd = cal.date(byAdding: .day, value: 7, to: thisWeek.end),
              let thisMonth = cal.dateInterval(of: .month, for: ctx.now),
              let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonth.start),
              let thisYear = cal.dateInterval(of: .year, for: ctx.now) else { return .unspecified }

        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: id, title: title, rank: rank) }
        if date >= tomorrow {
            if date < thisWeek.end { return b("date.laterThisWeek", "Later this week", 10) }
            if date < nextWeekEnd { return b("date.nextWeek", "Next week", 11) }
            return b("date.future", "In the future", 12)
        }
        if date >= today { return b("date.today", "Today", 9) }
        if date >= yesterday { return b("date.yesterday", "Yesterday", 8) }
        if date >= thisWeek.start { return b("date.earlierThisWeek", "Earlier this week", 7) }
        if date >= lastWeekStart { return b("date.lastWeek", "Last week", 6) }
        if date >= thisMonth.start { return b("date.earlierThisMonth", "Earlier this month", 5) }
        if date >= lastMonthStart { return b("date.lastMonth", "Last month", 4) }
        if date >= thisYear.start { return b("date.earlierThisYear", "Earlier this year", 3) }
        return b("date.longAgo", "A long time ago", 2)
    }

    // MARK: Sizes

    public static let kb: Int64 = 1024
    public static let mb: Int64 = 1024 * 1024
    public static let gb: Int64 = 1024 * 1024 * 1024

    public static func size(_ bytes: Int64?) -> GroupBucket {
        guard let bytes else { return .unspecified }
        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: "size.\(id)", title: title, rank: rank) }
        switch bytes {
        case ...0: return b("empty", "Empty (0 KB)", 0)
        case ...(16 * kb): return b("tiny", "Tiny (0 – 16 KB)", 1)
        case ...mb: return b("small", "Small (16 KB – 1 MB)", 2)
        case ...(128 * mb): return b("medium", "Medium (1 – 128 MB)", 3)
        case ...gb: return b("large", "Large (128 MB – 1 GB)", 4)
        case ...(4 * gb): return b("huge", "Huge (1 – 4 GB)", 5)
        default: return b("gigantic", "Gigantic (> 4 GB)", 6)
        }
    }

    // MARK: Names

    /// A – H · I – P · Q – Z · 0 – 9 · Other, in the reference's display order. Accents are folded (É → E); non-Latin letters are Other.
    public static func alphabet(_ text: String) -> GroupBucket {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return .unspecified }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: "name.\(id)", title: title, rank: rank) }
        if let scalar = folded.unicodeScalars.first, folded.unicodeScalars.count == 1 {
            switch scalar {
            case "a"..."h": return b("ah", "A – H", 0)
            case "i"..."p": return b("ip", "I – P", 1)
            case "q"..."z": return b("qz", "Q – Z", 2)
            case "0"..."9": return b("digits", "0 – 9", 3)
            default: break
            }
        }
        return b("other", "Other", 4)
    }

    // MARK: Durations

    /// Length groups (RECALL-l): Very short (< 1 min) · Short (1 – 5 min) · Medium (5 – 30 min) ·
    /// Long (30 – 60 min) · Very long (> 60 min).
    public static func duration(_ seconds: Double?) -> GroupBucket {
        guard let seconds else { return .unspecified }
        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: "length.\(id)", title: title, rank: rank) }
        switch seconds {
        case ..<60: return b("veryShort", "Very short (under 1 minute)", 0)
        case ..<300: return b("short", "Short (1 – 5 minutes)", 1)
        case ..<1800: return b("medium", "Medium (5 – 30 minutes)", 2)
        case ..<3600: return b("long", "Long (30 – 60 minutes)", 3)
        default: return b("veryLong", "Very long (over 60 minutes)", 4)
        }
    }

    /// One bucket per distinct value. Ranks are filled in by `FileGrouper` after sorting titles.
    public static func distinct(_ text: String) -> GroupBucket {
        text.isEmpty ? .unspecified : GroupBucket(id: "value.\(text)", title: text, rank: 0)
    }

    // MARK: Any column

    /// Every bucket an item falls into for a column. Multi-valued columns (Tags, Authors) give one
    /// bucket per value; grouping uses the first, filters match any.
    public static func buckets(for item: FileItem, column: ColumnID, ctx: GroupingContext,
                               lookup: ColumnValueLookup?) -> [GroupBucket] {
        guard let value = ColumnValues.value(item, column, lookup: lookup) else { return [.loading] }
        let style = ColumnCatalog.descriptor(column)?.groupStyle ?? .distinct
        switch (style, value) {
        case (.date, .date(let d)): return [date(d, ctx)]
        case (.size, .bytes(let n)): return [size(n)]
        case (.duration, .duration(let s)): return [duration(s)]
        case (.alphabet, .text(let s)): return [alphabet(s)]
        case (_, .list(let values)):
            let sorted = values.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return sorted.isEmpty ? [.unspecified] : sorted.map(distinct)
        case (_, let v) where !v.hasValue: return [.unspecified]
        default:
            return [distinct(ColumnValues.text(value, column: column))]
        }
    }
}

/// One group of items, in display order.
public struct ItemGroup: Equatable, Sendable {
    public let bucket: GroupBucket
    public var items: [FileItem]

    public init(bucket: GroupBucket, items: [FileItem]) {
        self.bucket = bucket
        self.items = items
    }
}

/// Partitions already-sorted items into groups (FE-038). Items keep the current sort inside each
/// group. View layouts that want groups call this with the tab's options (docs/features/grouping.md).
public enum FileGrouper {
    public static func group(_ sortedItems: [FileItem], by column: ColumnID, ascending: Bool,
                             context: GroupingContext = GroupingContext(), lookup: ColumnValueLookup? = nil) -> [ItemGroup] {
        var order: [String] = []
        var groups: [String: ItemGroup] = [:]
        for item in sortedItems {
            let bucket = Buckets.buckets(for: item, column: column, ctx: context, lookup: lookup).first ?? .unspecified
            if groups[bucket.id] == nil {
                order.append(bucket.id)
                groups[bucket.id] = ItemGroup(bucket: bucket, items: [])
            }
            groups[bucket.id]?.items.append(item)
        }
        let list = rankDistinct(order.compactMap { groups[$0] }.map(\.bucket))
        let rankByID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        return order.compactMap { id -> ItemGroup? in
            guard let g = groups[id], let bucket = rankByID[id] else { return nil }
            return ItemGroup(bucket: bucket, items: g.items)
        }.sorted { a, b in orderBuckets(a.bucket, b.bucket, ascending: ascending) }
    }

    /// Ascending/descending by rank; Unspecified and Loading stay last; ties by title.
    public static func orderBuckets(_ a: GroupBucket, _ b: GroupBucket, ascending: Bool) -> Bool {
        if a.isTrailing != b.isTrailing { return !a.isTrailing }
        if a.isTrailing { return a.id < b.id }
        if a.rank != b.rank { return ascending ? a.rank < b.rank : a.rank > b.rank }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return ascending ? byTitle == .orderedAscending : byTitle == .orderedDescending }
        return a.id < b.id
    }

    /// Distinct-value buckets get ranks from their natural (numeric-aware) title order.
    static func rankDistinct(_ buckets: [GroupBucket]) -> [GroupBucket] {
        let distinct = buckets.filter { $0.id.hasPrefix("value.") }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var ranks: [String: Double] = [:]
        for (i, b) in distinct.enumerated() { ranks[b.id] = Double(i) }
        return buckets.map { b in ranks[b.id].map { GroupBucket(id: b.id, title: b.title, rank: $0) } ?? b }
    }
}

// MARK: - Column header filters (FE-039)

/// Checked buckets per column. Columns combine with AND; buckets within one column with OR.
public struct ColumnFilters: Equatable, Sendable {
    public private(set) var selections: [ColumnID: Set<String>] = [:]

    public init() {}

    public var isEmpty: Bool { selections.isEmpty }
    public var columns: [ColumnID] { Array(selections.keys) }

    public func isFiltered(_ column: ColumnID) -> Bool { selections[column] != nil }
    public func selected(_ column: ColumnID) -> Set<String> { selections[column] ?? [] }

    /// Sets a column's checked buckets; an empty set removes the column's filter.
    public mutating func set(_ column: ColumnID, _ bucketIDs: Set<String>) {
        selections[column] = bucketIDs.isEmpty ? nil : bucketIDs
    }

    public mutating func toggle(_ column: ColumnID, bucket id: String) {
        var current = selected(column)
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        set(column, current)
    }

    public mutating func clear(_ column: ColumnID? = nil) {
        if let column { selections[column] = nil } else { selections.removeAll() }
    }

    public func matches(_ item: FileItem, ctx: GroupingContext, lookup: ColumnValueLookup?) -> Bool {
        for (column, wanted) in selections {
            let ids = Buckets.buckets(for: item, column: column, ctx: ctx, lookup: lookup).map(\.id)
            if !ids.contains(where: wanted.contains) { return false }
        }
        return true
    }

    public func apply(_ items: [FileItem], ctx: GroupingContext = GroupingContext(), lookup: ColumnValueLookup?) -> [FileItem] {
        isEmpty ? items : items.filter { matches($0, ctx: ctx, lookup: lookup) }
    }

    /// The choices a column's dropdown lists: buckets present in `items`, in ascending order.
    public static func options(for column: ColumnID, items: [FileItem], ctx: GroupingContext = GroupingContext(),
                               lookup: ColumnValueLookup?) -> [GroupBucket] {
        var seen: [String: GroupBucket] = [:]
        for item in items {
            for b in Buckets.buckets(for: item, column: column, ctx: ctx, lookup: lookup) where seen[b.id] == nil { seen[b.id] = b }
        }
        return FileGrouper.rankDistinct(Array(seen.values)).sorted { FileGrouper.orderBuckets($0, $1, ascending: true) }
    }
}
