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

    /// No value (e.g. folders by Size); always last.
    public static let unspecified = GroupBucket(id: "~unspecified", title: L10n.tr("Unspecified"), rank: .infinity)
    /// Metadata still loading; always last.
    public static let loading = GroupBucket(id: "~loading", title: L10n.tr("Loading…"), rank: .infinity)

    /// Sorted last whatever the direction.
    public var isTrailing: Bool { id.hasPrefix("~") }
}

/// "Now" and the calendar for date buckets; inject fixed ones in tests.
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
            if date < thisWeek.end { return b("date.laterThisWeek", L10n.tr("Later this week"), 10) }
            if date < nextWeekEnd { return b("date.nextWeek", L10n.tr("Next week"), 11) }
            return b("date.future", L10n.tr("In the future"), 12)
        }
        if date >= today { return b("date.today", L10n.tr("Today"), 9) }
        if date >= yesterday { return b("date.yesterday", L10n.tr("Yesterday"), 8) }
        if date >= thisWeek.start { return b("date.earlierThisWeek", L10n.tr("Earlier this week"), 7) }
        if date >= lastWeekStart { return b("date.lastWeek", L10n.tr("Last week"), 6) }
        if date >= thisMonth.start { return b("date.earlierThisMonth", L10n.tr("Earlier this month"), 5) }
        if date >= lastMonthStart { return b("date.lastMonth", L10n.tr("Last month"), 4) }
        if date >= thisYear.start { return b("date.earlierThisYear", L10n.tr("Earlier this year"), 3) }
        return b("date.longAgo", L10n.tr("A long time ago"), 2)
    }

    // MARK: Sizes

    public static let kb: Int64 = 1024
    public static let mb: Int64 = 1024 * 1024
    public static let gb: Int64 = 1024 * 1024 * 1024

    public static func size(_ bytes: Int64?) -> GroupBucket {
        guard let bytes else { return .unspecified }
        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: "size.\(id)", title: title, rank: rank) }
        switch bytes {
        case ...0: return b("empty", L10n.tr("Empty (0 KB)"), 0)
        case ...(16 * kb): return b("tiny", L10n.tr("Tiny (0 – 16 KB)"), 1)
        case ...mb: return b("small", L10n.tr("Small (16 KB – 1 MB)"), 2)
        case ...(128 * mb): return b("medium", L10n.tr("Medium (1 – 128 MB)"), 3)
        case ...gb: return b("large", L10n.tr("Large (128 MB – 1 GB)"), 4)
        case ...(4 * gb): return b("huge", L10n.tr("Huge (1 – 4 GB)"), 5)
        default: return b("gigantic", L10n.tr("Gigantic (> 4 GB)"), 6)
        }
    }

    // MARK: Names

    /// Accents fold (É → E); non-Latin letters are Other.
    public static func alphabet(_ text: String) -> GroupBucket {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return .unspecified }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: "name.\(id)", title: title, rank: rank) }
        if let scalar = folded.unicodeScalars.first, folded.unicodeScalars.count == 1 {
            switch scalar {
            case "a"..."h": return b("ah", L10n.tr("A – H"), 0)
            case "i"..."p": return b("ip", L10n.tr("I – P"), 1)
            case "q"..."z": return b("qz", L10n.tr("Q – Z"), 2)
            case "0"..."9": return b("digits", L10n.tr("0 – 9"), 3)
            default: break
            }
        }
        return b("other", L10n.tr("Other"), 4)
    }

    // MARK: Durations

    /// Length groups (RECALL-l).
    public static func duration(_ seconds: Double?) -> GroupBucket {
        guard let seconds else { return .unspecified }
        func b(_ id: String, _ title: String, _ rank: Double) -> GroupBucket { GroupBucket(id: "length.\(id)", title: title, rank: rank) }
        switch seconds {
        case ..<60: return b("veryShort", L10n.tr("Very short (under 1 minute)"), 0)
        case ..<300: return b("short", L10n.tr("Short (1 – 5 minutes)"), 1)
        case ..<1800: return b("medium", L10n.tr("Medium (5 – 30 minutes)"), 2)
        case ..<3600: return b("long", L10n.tr("Long (30 – 60 minutes)"), 3)
        default: return b("veryLong", L10n.tr("Very long (over 60 minutes)"), 4)
        }
    }

    /// Ranks are filled in later by `FileGrouper`.
    public static func distinct(_ text: String) -> GroupBucket {
        text.isEmpty ? .unspecified : GroupBucket(id: "value.\(text)", title: text, rank: 0)
    }

    // MARK: Any column

    /// Multi-valued columns (Tags, Authors) give one bucket per value; grouping uses the first, filters any.
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

/// Splits already-sorted items into groups, keeping the sort inside each (FE-038, docs/features/grouping.md).
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

/// Per column, a checked bucket or the date range admits an item; columns combine with AND.
public struct ColumnFilters: Equatable, Sendable {
    private struct Condition: Equatable, Sendable {
        var buckets: Set<String> = []
        var range: DayRange?

        var isEmpty: Bool { buckets.isEmpty && range == nil }

        func matches(_ item: FileItem, column: ColumnID, ctx: GroupingContext, lookup: ColumnValueLookup?) -> Bool {
            // A missing or still-loading date can only match a checked "Unspecified" or "Loading…".
            if let range, case .date(let date)? = ColumnValues.value(item, column, lookup: lookup), range.contains(date) { return true }
            guard !buckets.isEmpty else { return false }
            return Buckets.buckets(for: item, column: column, ctx: ctx, lookup: lookup).contains { buckets.contains($0.id) }
        }
    }

    /// An empty condition is never stored, so a key always means "this column is filtered".
    private var conditions: [ColumnID: Condition] = [:]

    public init() {}

    public var isEmpty: Bool { conditions.isEmpty }
    public var columns: [ColumnID] { Array(conditions.keys) }

    public func isFiltered(_ column: ColumnID) -> Bool { conditions[column] != nil }
    public func selected(_ column: ColumnID) -> Set<String> { conditions[column]?.buckets ?? [] }
    public func dateRange(_ column: ColumnID) -> DayRange? { conditions[column]?.range }

    private mutating func edit(_ column: ColumnID, _ change: (inout Condition) -> Void) {
        var condition = conditions[column] ?? Condition()
        change(&condition)
        conditions[column] = condition.isEmpty ? nil : condition
    }

    /// Sets a column's checked buckets, keeping its date range.
    public mutating func set(_ column: ColumnID, _ bucketIDs: Set<String>) {
        edit(column) { $0.buckets = bucketIDs }
    }

    public mutating func toggle(_ column: ColumnID, bucket id: String) {
        edit(column) { condition in
            if condition.buckets.remove(id) == nil { condition.buckets.insert(id) }
        }
    }

    /// Sets a column's date range, keeping its checked buckets.
    public mutating func setDateRange(_ column: ColumnID, _ range: DayRange?) {
        edit(column) { $0.range = range }
    }

    public mutating func clear(_ column: ColumnID? = nil) {
        if let column { conditions[column] = nil } else { conditions.removeAll() }
    }

    public func matches(_ item: FileItem, ctx: GroupingContext, lookup: ColumnValueLookup?) -> Bool {
        for (column, condition) in conditions where !condition.matches(item, column: column, ctx: ctx, lookup: lookup) {
            return false
        }
        return true
    }

    public func apply(_ items: [FileItem], ctx: GroupingContext = GroupingContext(), lookup: ColumnValueLookup?) -> [FileItem] {
        isEmpty ? items : items.filter { matches($0, ctx: ctx, lookup: lookup) }
    }

    /// A column's dropdown choices: buckets present in `items`, ascending.
    public static func options(for column: ColumnID, items: [FileItem], ctx: GroupingContext = GroupingContext(),
                               lookup: ColumnValueLookup?) -> [GroupBucket] {
        var seen: [String: GroupBucket] = [:]
        for item in items {
            for b in Buckets.buckets(for: item, column: column, ctx: ctx, lookup: lookup) where seen[b.id] == nil { seen[b.id] = b }
        }
        return FileGrouper.rankDistinct(Array(seen.values)).sorted { FileGrouper.orderBuckets($0, $1, ascending: true) }
    }
}
