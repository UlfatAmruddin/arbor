import Foundation

/// Translates a parsed query into an MDQuery string (FE-143). The result is always a superset: untranslatable
/// AND parts are dropped and an untranslatable OR gives nil. Hits are re-checked by `SearchEvaluator`; only
/// with `isExact` may a locally unknown result (e.g. PDF contents) be accepted on Spotlight's word.
public struct SpotlightPredicate: Equatable, Sendable {
    public let query: String
    public let isExact: Bool

    public static func make(_ expression: SearchExpression, matchContents: Bool) -> SpotlightPredicate? {
        translate(expression, matchContents: matchContents).map { SpotlightPredicate(query: $0.0, isExact: $0.1) }
    }

    static func translate(_ e: SearchExpression, matchContents: Bool) -> (String, Bool)? {
        switch e {
        case .term(let t): return term(t, matchContents: matchContents)
        case .and(let a, let b):
            let x = translate(a, matchContents: matchContents)
            let y = translate(b, matchContents: matchContents)
            switch (x, y) {
            case let (x?, y?): return ("(\(x.0) && \(y.0))", x.1 && y.1)
            case let (x?, nil): return (x.0, false)
            case let (nil, y?): return (y.0, false)
            default: return nil
            }
        case .or(let a, let b):
            guard let x = translate(a, matchContents: matchContents), let y = translate(b, matchContents: matchContents) else { return nil }
            return ("(\(x.0) || \(y.0))", x.1 && y.1)
        case .not(let inner):
            return negate(inner, matchContents: matchContents)
        }
    }

    /// Pushes NOT down (MDQuery has no general negation). Only attributes every file has are negated:
    /// `!=` on an optional one (authors, tags, contents) would drop files lacking it.
    static func negate(_ e: SearchExpression, matchContents: Bool) -> (String, Bool)? {
        switch e {
        case .not(let inner): return translate(inner, matchContents: matchContents)
        case .and(let a, let b): return translate(.or(.not(a), .not(b)), matchContents: matchContents)
        case .or(let a, let b): return translate(.and(.not(a), .not(b)), matchContents: matchContents)
        case .term(let t):
            switch (t.property, t.test) {
            case (nil, .text(let v, let mode)) where !matchContents:
                return (comparison("kMDItemFSName", v, mode, negated: true), mode != .wildcard || !v.contains("?"))
            case (.name?, .text(let v, let mode)):
                return (comparison("kMDItemFSName", v, mode, negated: true), mode != .wildcard || !v.contains("?"))
            case (.fileExtension?, .text(let v, let mode)):
                return ("kMDItemFSName != \(quoted("*." + escape(v, keepWildcards: mode == .wildcard)))c", true)
            case (.size?, .sizeRange(let lo, let hi)):
                var parts: [String] = []
                if let lo { parts.append("kMDItemFSSize < \(lo)") }
                if let hi { parts.append("kMDItemFSSize >= \(hi)") }
                guard !parts.isEmpty else { return nil }
                return ("(" + parts.joined(separator: " || ") + ")", false)   // folders have no size
            default:
                return nil
            }
        }
    }

    static func term(_ t: SearchTerm, matchContents: Bool) -> (String, Bool)? {
        switch (t.property, t.test) {
        case (nil, .text(let v, let mode)):
            let name = comparison("kMDItemFSName", v, mode)
            let exact = mode != .wildcard || !v.contains("?")
            guard matchContents, mode != .wildcard else { return (name, exact) }
            return ("(\(name) || \(comparison("kMDItemTextContent", v, .contains)))", exact)
        case (.name?, .text(let v, let mode)):
            return (comparison("kMDItemFSName", v, mode), mode != .wildcard || !v.contains("?"))
        case (.fileExtension?, .text(let v, let mode)):
            switch mode {
            case .equals, .contains: return ("kMDItemFSName == \(quoted("*." + escape(v, keepWildcards: false)))c", true)
            case .wildcard: return ("kMDItemFSName == \(quoted("*." + escape(v, keepWildcards: true)))c", !v.contains("?"))
            case .beginsWith: return ("kMDItemFSName == \(quoted("*." + escape(v, keepWildcards: false) + "*"))c", false)
            }
        case (.contents?, .text(let v, _)):
            return (comparison("kMDItemTextContent", v, .contains), true)
        case (.author?, .text(let v, let mode)):
            return (comparison("kMDItemAuthors", v, mode), true)
        case (.tags?, .text(let v, let mode)):
            return (comparison("kMDItemUserTags", v, mode == .contains ? .equals : mode), true)
        case (.type?, .text(let v, let mode)):
            return (comparison("kMDItemKind", v, mode), false)   // localized kind; re-checked locally
        case (.kind?, .kind(let kind)):
            guard let types = kind.spotlightTypes else { return nil }
            let attribute = kind == .folder ? "kMDItemContentType" : "kMDItemContentTypeTree"
            let parts = types.map { "\(attribute) == \(quoted($0))" }
            return (parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " || ") + ")", false)
        case (.size?, .sizeRange(let lo, let hi)):
            var parts: [String] = []
            if let lo { parts.append("kMDItemFSSize >= \(lo)") }
            if let hi { parts.append("kMDItemFSSize < \(hi)") }
            guard !parts.isEmpty else { return nil }
            return (parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " && ") + ")", true)
        case (.dateModified?, .dateRange(let lo, let hi)):
            return dateRange("kMDItemFSContentChangeDate", lo, hi)
        case (.dateCreated?, .dateRange(let lo, let hi)):
            return dateRange("kMDItemFSCreationDate", lo, hi)
        default:
            return nil   // folder path, empty values: checked locally only
        }
    }

    static func dateRange(_ attribute: String, _ lo: Date?, _ hi: Date?) -> (String, Bool)? {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        var parts: [String] = []
        if let lo { parts.append("\(attribute) >= $time.iso(\(f.string(from: lo)))") }
        if let hi { parts.append("\(attribute) < $time.iso(\(f.string(from: hi)))") }
        guard !parts.isEmpty else { return nil }
        return (parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " && ") + ")", true)
    }

    /// `attr == "*value*"cd` (c = ignore case, d = ignore diacritics).
    static func comparison(_ attribute: String, _ value: String, _ mode: TextMatchMode, negated: Bool = false) -> String {
        let op = negated ? "!=" : "=="
        let pattern: String
        switch mode {
        case .contains: pattern = "*" + escape(value, keepWildcards: false) + "*"
        case .equals: pattern = escape(value, keepWildcards: false)
        case .beginsWith: pattern = escape(value, keepWildcards: false) + "*"
        case .wildcard: pattern = escape(value, keepWildcards: true)
        }
        return "\(attribute) \(op) \(quoted(pattern))cd"
    }

    /// Escapes MDQuery string syntax, including `$`, which would expand `$time.…` inside the quotes. `?` becomes `*` (a superset; re-checked locally).
    /// Works on scalars: a quote joined to a combining mark is one Character, but still ends the string for MDQuery.
    static func escape(_ value: String, keepWildcards: Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\", "\"", "$": out.append("\\"); out.append(scalar)
            case "*" where !keepWildcards: out.append("\\"); out.append("*")
            case "?" where !keepWildcards: out.append("\\"); out.append("?")
            case "?": out.append("*")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    static func quoted(_ s: String) -> String { "\"\(s)\"" }
}

/// Parses `mdutil -s <volume>` output: "Indexing enabled.", "Indexing disabled.", or an error.
public enum SpotlightIndexState: String, Sendable {
    case enabled, disabled, unknown

    public static func parse(mdutilOutput text: String) -> SpotlightIndexState {
        let t = text.lowercased()
        // The startup disk reports this on recent macOS, and Spotlight still answers for it.
        if t.contains("indexing enabled") || t.contains("index is read-only") { return .enabled }
        if t.contains("indexing disabled") || t.contains("indexing and searching disabled") { return .disabled }
        return .unknown
    }
}
