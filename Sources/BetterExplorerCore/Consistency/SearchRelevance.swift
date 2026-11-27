import Foundation

/// Explorer's search order (FE-145): name equals, starts with, contains, then content, then other matches.
/// Lower ranks are more relevant.
public enum SearchRelevance {
    /// Not a Details column; offered in Sort ▾ for search results.
    public static let column: ColumnID = "search.relevance"

    public enum Tier: Int, Comparable, Sendable {
        case exactName = 0, namePrefix, nameContains, contents, other
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// Free text and `name:` words, without wildcards; NOT terms are ignored.
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

    static func tier(name: String, word: String) -> Tier? {
        let base = (name as NSString).deletingPathExtension
        if name.compare(word, options: options) == .orderedSame || base.compare(word, options: options) == .orderedSame {
            return .exactName
        }
        if name.range(of: word, options: options.union(.anchored)) != nil { return .namePrefix }
        if name.range(of: word, options: options) != nil { return .nameContains }
        return nil
    }

    /// `reasons` nil means unknown (treated as name only).
    public static func tier(name: String, words: [String], reasons: Set<SearchReason>?) -> Tier {
        let best = words.compactMap { tier(name: name, word: $0) }.min()
        if let best, reasons?.contains(.name) ?? true { return best }
        if let reasons, reasons.contains(.contents) { return .contents }
        if let best { return best }
        return .other
    }

    /// Tier first; within a tier, more matched words first.
    public static func score(name: String, words: [String], reasons: Set<SearchReason>?) -> Double {
        let tier = tier(name: name, words: words, reasons: reasons)
        let matched = words.filter { self.tier(name: name, word: $0) != nil }.count
        return Double(tier.rawValue) * 1000 - Double(min(matched, 999))
    }

    /// Relevance with folders mixed in, as Explorer does.
    public static var defaultOrder: FileSortOrder {
        var order = FileSortOrder(key: .name, ascending: true, foldersFirst: false)
        order.column = column
        return order
    }

    public static func isRelevance(_ order: FileSortOrder) -> Bool { order.column == column }
}
