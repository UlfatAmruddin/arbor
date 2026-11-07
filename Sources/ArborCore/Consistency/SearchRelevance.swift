import Foundation

/// Explorer's default order for search results (FE-145): items whose name equals a searched word come
/// first, then names starting with it, then names containing it, then items found by their contents,
/// then items found only by another property. Lower ranks are more relevant.
public enum SearchRelevance {
    /// The sort column for relevance (not a Details column; offered in Sort ▾ for search results).
    public static let column: ColumnID = "search.relevance"

    public enum Tier: Int, Comparable, Sendable {
        case exactName = 0, namePrefix, nameContains, contents, other
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// The words of a query that are compared with names: free text and `name:` terms, without
    /// wildcards. Terms under NOT are ignored (they never make an item relevant).
    public static func nameWords(_ query: String) -> [String] {
        guard case .success(let expression) = AQSParser.parse(query) else {
            return query.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return words(expression)
    }

    static func words(_ expression: SearchExpression) -> [String] {
        switch expression {
        case .term(let term):
            guard term.property == nil || term.property == .name, case .text(let value, _) = term.test else { return [] }
            let cleaned = value.replacingOccurrences(of: "*", with: " ").replacingOccurrences(of: "?", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? [] : [cleaned]
        case .and(let a, let b), .or(let a, let b): return words(a) + words(b)
        case .not: return []
        }
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// How well a name matches one word.
    static func tier(name: String, word: String) -> Tier? {
        let base = (name as NSString).deletingPathExtension
        if name.compare(word, options: options) == .orderedSame || base.compare(word, options: options) == .orderedSame {
            return .exactName
        }
        if name.range(of: word, options: options.union(.anchored)) != nil { return .namePrefix }
        if name.range(of: word, options: options) != nil { return .nameContains }
        return nil
    }

    /// The tier of a result. `reasons` are what the search matched on (nil = unknown: name only).
    public static func tier(name: String, words: [String], reasons: Set<SearchReason>?) -> Tier {
        let best = words.compactMap { tier(name: name, word: $0) }.min()
        if let best, reasons?.contains(.name) ?? true { return best }
        if let reasons, reasons.contains(.contents) { return .contents }
        if let best { return best }
        return .other
    }

    /// A sortable score: the tier first; within a tier, names matching more words come first.
    public static func score(name: String, words: [String], reasons: Set<SearchReason>?) -> Double {
        let tier = tier(name: name, words: words, reasons: reasons)
        let matched = words.filter { self.tier(name: name, word: $0) != nil }.count
        return Double(tier.rawValue) * 1000 - Double(min(matched, 999))
    }

    /// The default order of a search tab: relevance, folders not grouped first (Explorer mixes them).
    public static var defaultOrder: FileSortOrder {
        var order = FileSortOrder(key: .name, ascending: true, foldersFirst: false)
        order.column = column
        return order
    }

    public static func isRelevance(_ order: FileSortOrder) -> Bool { order.column == column }
}
