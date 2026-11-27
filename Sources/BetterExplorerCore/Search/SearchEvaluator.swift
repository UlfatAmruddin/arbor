import Foundation

/// Unread values are nil and test as "unknown", not false, so a scan never claims a non-match it couldn't check.
public struct SearchCandidate {
    public var name: String
    /// Containing folder.
    public var folderPath: String
    public var isFolder: Bool
    public var isPackage: Bool
    public var isSymbolicLink: Bool
    /// nil for folders.
    public var size: Int64?
    public var modified: Date?
    public var created: Date?
    public var typeIdentifier: String?
    public var typeDescription: String?
    public var tags: [String]?
    /// From Spotlight.
    public var authors: [String]?
    /// Returns nil when the contents can't be checked.
    public var contentContains: ((String) -> Bool?)?

    public init(name: String, folderPath: String, isFolder: Bool, isPackage: Bool = false, isSymbolicLink: Bool = false,
                size: Int64? = nil, modified: Date? = nil, created: Date? = nil, typeIdentifier: String? = nil,
                typeDescription: String? = nil, tags: [String]? = nil, authors: [String]? = nil,
                contentContains: ((String) -> Bool?)? = nil) {
        self.name = name
        self.folderPath = folderPath
        self.isFolder = isFolder
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.created = created
        self.typeIdentifier = typeIdentifier
        // The Type column's wording, so `type:` finds what the column shows.
        let windowsShortcut = isSymbolicLink ? nil : WindowsShortcutKind(itemName: name, isFolder: isFolder, isPackage: isPackage)
        self.typeDescription = windowsShortcut?.typeName ?? typeDescription
        self.tags = tags
        self.authors = authors
        self.contentContains = contentContains
    }

    /// Folders have none; packages do.
    public var fileExtension: String {
        guard !isFolder || isPackage else { return "" }
        return (name as NSString).pathExtension
    }
}

/// Three-valued truth (Kleene logic).
public enum SearchTruth: Equatable, Sendable { case yes, no, unknown }

/// Shown in the Match column (FE-137).
public enum SearchReason: Hashable, Sendable, Comparable {
    case name
    case contents
    case property(SearchProperty)
    case archiveEntry(String)

    public var label: String {
        switch self {
        case .name: return L10n.tr("Name")
        case .contents: return L10n.tr("Contents")
        case .property(let p): return p.label
        case .archiveEntry(let path): return L10n.format("In archive: %@", "\(path)")
        }
    }

    var rank: Int {
        switch self {
        case .name: return 0
        case .contents: return 1
        case .property(let p): return 2 + (SearchProperty.allCases.firstIndex(of: p) ?? 0)
        case .archiveEntry: return 100
        }
    }

    public static func < (a: SearchReason, b: SearchReason) -> Bool { a.rank < b.rank }
}

public struct SearchMatch: Equatable {
    public var truth: SearchTruth
    public var reasons: Set<SearchReason>

    public static let no = SearchMatch(truth: .no, reasons: [])
    public static let unknown = SearchMatch(truth: .unknown, reasons: [])
    public static func yes(_ reasons: Set<SearchReason> = []) -> SearchMatch { SearchMatch(truth: .yes, reasons: reasons) }
}

public struct SearchEvaluator {
    public let expression: SearchExpression
    /// "File contents" option: free text also matches contents.
    public var matchContents: Bool

    public init(_ expression: SearchExpression, matchContents: Bool = false) {
        self.expression = expression
        self.matchContents = matchContents
    }

    public func evaluate(_ candidate: SearchCandidate) -> SearchMatch {
        Self.evaluate(expression, candidate, matchContents: matchContents)
    }

    public var needsContents: Bool {
        expression.terms.contains { $0.property == .contents || ($0.property == nil && matchContents) }
    }

    /// Authors are only available from Spotlight.
    public var needsIndexOnlyMetadata: Bool { expression.properties.contains(.author) }

    static func evaluate(_ e: SearchExpression, _ c: SearchCandidate, matchContents: Bool) -> SearchMatch {
        switch e {
        case .term(let t):
            return term(t, c, matchContents: matchContents)
        case .and(let a, let b):
            let x = evaluate(a, c, matchContents: matchContents)
            if x.truth == .no { return .no }
            let y = evaluate(b, c, matchContents: matchContents)
            if y.truth == .no { return .no }
            let truth: SearchTruth = (x.truth == .yes && y.truth == .yes) ? .yes : .unknown
            return SearchMatch(truth: truth, reasons: x.reasons.union(y.reasons))
        case .or(let a, let b):
            // Short-circuits so a name match never reads the file's contents.
            let x = evaluate(a, c, matchContents: matchContents)
            if x.truth == .yes { return x }
            let y = evaluate(b, c, matchContents: matchContents)
            if y.truth == .yes { return y }
            if x.truth == .no && y.truth == .no { return .no }
            return .unknown
        case .not(let inner):
            switch evaluate(inner, c, matchContents: matchContents).truth {
            case .yes: return .no
            case .no: return .yes()
            case .unknown: return .unknown
            }
        }
    }

    static func term(_ t: SearchTerm, _ c: SearchCandidate, matchContents: Bool) -> SearchMatch {
        guard let property = t.property else {
            // Free text: name, plus contents with the File contents option.
            guard case .text(let value, let mode) = t.test else { return .no }
            if TextMatcher.matches(c.name, value, mode) { return .yes([.name]) }
            guard matchContents, mode != .wildcard, !c.isFolder else { return .no }
            return content(c, value)
        }
        let reason = SearchReason.property(property)
        func bool(_ b: Bool) -> SearchMatch { b ? .yes([property == .name ? .name : reason]) : .no }
        switch (property, t.test) {
        case (.name, .text(let v, let mode)): return bool(TextMatcher.matches(c.name, v, mode))
        case (.fileExtension, .text(let v, let mode)): return bool(TextMatcher.matches(c.fileExtension, v, mode))
        case (.folderPath, .text(let v, let mode)): return bool(TextMatcher.matches(c.folderPath, v, mode))
        case (.type, .text(let v, let mode)):
            // Like Explorer, `type:txt` also matches the extension.
            let ext = v.hasPrefix(".") ? String(v.dropFirst()) : v
            if !c.fileExtension.isEmpty, TextMatcher.matches(c.fileExtension, ext, mode == .contains ? .equals : mode) { return .yes([reason]) }
            guard let description = c.typeDescription else { return .unknown }
            return bool(TextMatcher.matches(description, v, mode))
        case (.kind, .kind(let kind)):
            return bool(kind.matches(typeIdentifier: c.typeIdentifier, isFolder: c.isFolder, isPackage: c.isPackage,
                                     isSymbolicLink: c.isSymbolicLink, name: c.name))
        case (.size, .sizeRange(let lo, let hi)):
            guard let size = c.size, !c.isFolder || c.isPackage else { return .no }   // folders have no size
            return bool((lo.map { size >= $0 } ?? true) && (hi.map { size < $0 } ?? true))
        case (.dateModified, .dateRange(let lo, let hi)):
            guard let d = c.modified else { return .unknown }
            return bool((lo.map { d >= $0 } ?? true) && (hi.map { d < $0 } ?? true))
        case (.dateCreated, .dateRange(let lo, let hi)):
            guard let d = c.created else { return .unknown }
            return bool((lo.map { d >= $0 } ?? true) && (hi.map { d < $0 } ?? true))
        case (.tags, .text(let v, let mode)):
            guard let tags = c.tags else { return .unknown }
            return bool(tags.contains { TextMatcher.matches($0, v, mode == .contains ? .equals : mode) })
        case (.tags, .isEmpty):
            guard let tags = c.tags else { return .unknown }
            return bool(tags.isEmpty)
        case (.author, .text(let v, let mode)):
            guard let authors = c.authors else { return .unknown }
            return bool(authors.contains { TextMatcher.matches($0, v, mode) })
        case (.author, .isEmpty):
            guard let authors = c.authors else { return .unknown }
            return bool(authors.isEmpty)
        case (.contents, .text(let v, _)):
            guard !c.isFolder else { return .no }
            return content(c, v)
        case (_, .isEmpty):
            return .unknown
        default:
            return .no
        }
    }

    static func content(_ c: SearchCandidate, _ value: String) -> SearchMatch {
        guard let check = c.contentContains, let found = check(value) else { return .unknown }
        return found ? .yes([.contents]) : .no
    }
}

/// Case-, diacritic- and width-insensitive comparison, plus DOS wildcards.
public enum TextMatcher {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public static func matches(_ text: String, _ value: String, _ mode: TextMatchMode) -> Bool {
        switch mode {
        case .contains: return value.isEmpty || text.range(of: value, options: options) != nil
        case .equals: return text.compare(value, options: options) == .orderedSame
        case .beginsWith: return text.range(of: value, options: options.union(.anchored)) != nil
        case .wildcard: return wildcard(text, value)
        }
    }

    public static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    /// Whole-string match.
    public static func wildcard(_ text: String, _ pattern: String) -> Bool {
        let t = fold(text)
        let p = fold(pattern)
        var ti = 0, pi = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                ti += 1; pi += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
