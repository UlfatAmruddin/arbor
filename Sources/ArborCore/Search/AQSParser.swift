import Foundation

/// Parses the subset of Windows Advanced Query Syntax that Arbor supports (spec §10.2, FE-134).
///
/// Compatibility table (see docs/features/search.md for the full version):
/// - Free text `report` = name contains "report"; `*.txt` / `re?ort` = DOS wildcards on the whole name.
/// - `"exact phrase"` = name contains the phrase, spaces included.
/// - Property restrictions `prop:value` with mnemonics (`name:`, `ext:`, `kind:`, `type:`, `size:`, `date:`,
///   `datemodified:`, `modified:`, `datecreated:`, `tag:`, `author:`, `content:`, `folder:`) or canonical names
///   (`System.Size:`…). Operators after the colon: `=` `<>` `>` `>=` `<` `<=` `~<` (begins with) `~=` (contains)
///   `~!` (doesn't contain) `~` (wildcard). Ranges `a..b`. Groups `author:(lee OR kim)`. Empty value `:=[]`.
/// - Booleans are uppercase `AND`, `OR`, `NOT`; juxtaposition is AND; `-term` negates. Mixed AND/OR fold
///   strictly left to right: `a AND b OR c` = `(a AND b) OR c`, and `a OR b c` = `(a OR b) AND c` (FE-236).
///   Lowercase `and`/`or` are ordinary words. Parentheses group.
/// - Anything else (unknown properties, stray operators, unbalanced quotes or parentheses, unknown kinds,
///   unreadable sizes or dates) is a `SearchSyntaxError` with a message for the user, never silently dropped.
public struct AQSParser {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Result<SearchExpression, SearchSyntaxError> {
        AQSParser(now: now, calendar: calendar).parse(text)
    }

    public func parse(_ text: String) -> Result<SearchExpression, SearchSyntaxError> {
        do {
            let tokens = try Self.tokenize(text)
            guard !tokens.isEmpty else { throw SearchSyntaxError("Type something to search for.") }
            var state = State(tokens: tokens, parser: self)
            let expression = try state.parseExpression(property: nil)
            if let extra = state.peek {
                if case .rparen = extra.kind { throw SearchSyntaxError("There's a “)” without a matching “(”.") }
                throw SearchSyntaxError("Arbor couldn't read the search from “\(extra.text)” on.")
            }
            return .success(expression)
        } catch let error as SearchSyntaxError {
            return .failure(error)
        } catch {
            return .failure(SearchSyntaxError(error.localizedDescription))
        }
    }

    // MARK: Tokens

    enum Kind: Equatable {
        case word(String)
        case phrase(String)
        /// `prop:` plus whatever followed the colon in the same word (operator and/or value).
        case property(SearchProperty, rest: String, name: String)
        case lparen, rparen, and, or, not
    }

    struct Token {
        var kind: Kind
        var text: String
        var start: Int
        var end: Int
        /// `-word`, `-name:x`, `-"phrase"`, `-(group)`.
        var negated = false
    }

    static func tokenize(_ text: String) throws -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0
        func isSpace(_ c: Character) -> Bool { c.isWhitespace }
        while i < chars.count {
            let c = chars[i]
            if isSpace(c) { i += 1; continue }
            let start = i
            var negated = false
            if c == "-", i + 1 < chars.count, !isSpace(chars[i + 1]), chars[i + 1] != ")" {
                negated = true
                i += 1
            }
            let d = chars[i]
            if d == "(" {
                tokens.append(Token(kind: .lparen, text: "(", start: start, end: i + 1, negated: negated)); i += 1; continue
            }
            if d == ")" {
                tokens.append(Token(kind: .rparen, text: ")", start: start, end: i + 1)); i += 1; continue
            }
            if d == "\"" || d == "“" || d == "”" {
                var j = i + 1
                var value = ""
                while j < chars.count, chars[j] != "\"", chars[j] != "”", chars[j] != "“" { value.append(chars[j]); j += 1 }
                guard j < chars.count else { throw SearchSyntaxError("A quotation mark is missing its closing “\"”.") }
                tokens.append(Token(kind: .phrase(value), text: String(chars[start...j]), start: start, end: j + 1, negated: negated))
                i = j + 1
                continue
            }
            var j = i
            var word = ""
            while j < chars.count, !isSpace(chars[j]), chars[j] != "(", chars[j] != ")", chars[j] != "\"", chars[j] != "“", chars[j] != "”" {
                word.append(chars[j]); j += 1
            }
            let raw = String(chars[start..<j])
            defer { i = j }
            if !negated {
                switch word {
                case "AND": tokens.append(Token(kind: .and, text: word, start: start, end: j)); continue
                case "OR": tokens.append(Token(kind: .or, text: word, start: start, end: j)); continue
                case "NOT": tokens.append(Token(kind: .not, text: word, start: start, end: j)); continue
                default: break
                }
            }
            if let colon = word.firstIndex(of: ":") {
                let name = String(word[..<colon])
                if Self.looksLikePropertyName(name) {
                    guard let property = SearchProperty.lookup(name) else {
                        throw SearchSyntaxError("“\(name):” isn't a search property Arbor supports. Supported: name, ext, kind, type, size, datemodified, datecreated, tags, author, content, folderpath (or System.* names). To search for the text itself, put it in quotes: \"\(word)\".")
                    }
                    let rest = String(word[word.index(after: colon)...])
                    tokens.append(Token(kind: .property(property, rest: rest, name: name), text: raw, start: start, end: j, negated: negated))
                    continue
                }
            }
            tokens.append(Token(kind: .word(word), text: raw, start: start, end: j, negated: negated))
        }
        return tokens
    }

    /// `name`, `System.Size`, `größe` — letters, digits, dots and underscores, starting with a letter.
    /// "12:30" or "C:\\x" are not property names and stay plain text.
    static func looksLikePropertyName(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
    }

    // MARK: Grammar

    struct State {
        var tokens: [Token]
        var index = 0
        let parser: AQSParser

        init(tokens: [Token], parser: AQSParser) {
            self.tokens = tokens
            self.parser = parser
        }

        var peek: Token? { index < tokens.count ? tokens[index] : nil }
        mutating func next() -> Token? {
            defer { index += 1 }
            return peek
        }

        /// expression := unary ((AND | OR | NOT | ε) unary)* — folded left to right.
        mutating func parseExpression(property: SearchProperty?) throws -> SearchExpression {
            var acc = try parseUnary(property: property)
            while let token = peek {
                switch token.kind {
                case .rparen:
                    return acc
                case .and:
                    index += 1
                    acc = .and(acc, try parseUnary(property: property, after: "AND"))
                case .or:
                    index += 1
                    acc = .or(acc, try parseUnary(property: property, after: "OR"))
                case .not:
                    index += 1
                    acc = .and(acc, .not(try parseUnary(property: property, after: "NOT")))
                default:
                    acc = .and(acc, try parseUnary(property: property))
                }
            }
            return acc
        }

        mutating func parseUnary(property: SearchProperty?, after op: String? = nil) throws -> SearchExpression {
            guard let token = peek else {
                if let op { throw SearchSyntaxError("“\(op)” needs a search term after it.") }
                throw SearchSyntaxError("Type something to search for.")
            }
            switch token.kind {
            case .not:
                index += 1
                return .not(try parseUnary(property: property, after: "NOT"))
            case .and, .or:
                throw SearchSyntaxError("“\(token.text)” needs a search term before it.")
            case .rparen:
                if let op { throw SearchSyntaxError("“\(op)” needs a search term after it.") }
                throw SearchSyntaxError("There's a “)” without a matching “(”.")
            default:
                let primary = try parsePrimary(property: property)
                return token.negated ? .not(primary) : primary
            }
        }

        mutating func parsePrimary(property: SearchProperty?) throws -> SearchExpression {
            guard let token = next() else { throw SearchSyntaxError("Type something to search for.") }
            switch token.kind {
            case .lparen:
                let inner = try parseExpression(property: property)
                guard let close = next(), case .rparen = close.kind else {
                    throw SearchSyntaxError("A “(” is missing its closing “)”.")
                }
                return inner
            case .property(let p, let rest, let name):
                if property != nil { throw SearchSyntaxError("“\(name):” can't be used inside another property's value.") }
                return try parseRestriction(p, rest: rest, name: name, token: token)
            case .word(let w):
                if let property { return try parser.restriction(property, op: "", value: w, isPhrase: false) }
                if w.contains("*") || w.contains("?") { return .term(.freeText(w, .wildcard)) }
                return .term(.freeText(w))
            case .phrase(let p):
                if let property { return try parser.restriction(property, op: "", value: p, isPhrase: true) }
                guard !p.trimmingCharacters(in: .whitespaces).isEmpty else { throw SearchSyntaxError("The quotation marks are empty.") }
                return .term(.freeText(p))
            case .rparen, .and, .or, .not:
                throw SearchSyntaxError("Arbor couldn't read the search at “\(token.text)”.")
            }
        }

        mutating func parseRestriction(_ property: SearchProperty, rest: String, name: String, token: Token) throws -> SearchExpression {
            let (op, valueText) = AQSParser.splitOperator(rest)
            let adjacent = peek.map { $0.start == token.end } ?? false
            if valueText.isEmpty {
                if adjacent, let following = peek {
                    switch following.kind {
                    case .phrase(let p):
                        index += 1
                        return try parser.restriction(property, op: op, value: p, isPhrase: true)
                    case .lparen:
                        guard op.isEmpty else {
                            throw SearchSyntaxError("“\(name):\(op)” can't be followed by a group. Use “\(name):(a OR b)”.")
                        }
                        index += 1
                        let inner = try parseExpression(property: property)
                        guard let close = next(), case .rparen = close.kind else {
                            throw SearchSyntaxError("A “(” is missing its closing “)”.")
                        }
                        return inner
                    default: break
                    }
                }
                throw SearchSyntaxError("Type a value right after “\(name):\(op)”, for example \(AQSParser.example(for: property)).")
            }
            var value = valueText
            // Two-word date keywords: `datemodified:last week`.
            if property.valueType == .date, ["this", "last", "past", "next"].contains(value.lowercased()),
               let following = peek, case .word(let w) = following.kind,
               ["week", "month", "year"].contains(w.lowercased()) {
                index += 1
                value += " " + w
            }
            return try parser.restriction(property, op: op, value: value, isPhrase: false)
        }
    }

    static func splitOperator(_ s: String) -> (String, String) {
        for op in [">=", "<=", "<>", "~<", "~=", "~!", ">", "<", "=", "~"] where s.hasPrefix(op) {
            return (op, String(s.dropFirst(op.count)))
        }
        return ("", s)
    }

    static func example(for property: SearchProperty) -> String {
        switch property.valueType {
        case .size: return "size:>1MB or size:large"
        case .date: return "\(property.keyword):today or \(property.keyword):1/1/2026..1/31/2026"
        case .kind: return "kind:picture"
        case .text: return property == .fileExtension ? "ext:pdf" : "\(property.keyword):report"
        }
    }

    // MARK: Values

    /// Builds the expression for one `property:op value`.
    func restriction(_ property: SearchProperty, op: String, value raw: String, isPhrase: Bool) throws -> SearchExpression {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value == "[]" {
            guard op == "=" || op.isEmpty || op == "<>" else { throw SearchSyntaxError("“[]” (no value) only works with “:” or “:=”.") }
            guard property.valueType == .text, property != .name else {
                throw SearchSyntaxError("Every item has a \(property.label.lowercased()); “\(property.keyword):[]” can't match anything.")
            }
            let term = SearchExpression.term(SearchTerm(property, .isEmpty))
            return op == "<>" ? .not(term) : term
        }
        guard !value.isEmpty else { throw SearchSyntaxError("Type a value after “\(property.keyword):”.") }
        switch property.valueType {
        case .text: return try textRestriction(property, op: op, value: value, isPhrase: isPhrase)
        case .kind:
            let kind = try Self.kind(value)
            switch op {
            case "", "=": return .term(SearchTerm(property, .kind(kind)))
            case "<>": return .not(.term(SearchTerm(property, .kind(kind))))
            default: throw SearchSyntaxError("“kind:” only supports “kind:value” or “kind:<>value”.")
            }
        case .size:
            return try rangeRestriction(property, op: op, value: value) { text in
                let r = try Self.sizeInterval(text)
                return (r.lower.map { Double($0) }, r.upper.map { Double($0) }, r.point.map { Double($0) })
            }
        case .date:
            return try rangeRestriction(property, op: op, value: value) { text in
                let r = try dateInterval(text)
                return (r.lower.map(\.timeIntervalSinceReferenceDate), r.upper.map(\.timeIntervalSinceReferenceDate), nil)
            }
        }
    }

    private func textRestriction(_ property: SearchProperty, op: String, value: String, isPhrase: Bool) throws -> SearchExpression {
        var text = value
        if property == .fileExtension, text.hasPrefix("."), !text.contains("*") { text.removeFirst() }
        guard !text.isEmpty else { throw SearchSyntaxError("Type an extension after “ext:”, for example ext:pdf.") }
        let hasWildcard = !isPhrase && (text.contains("*") || text.contains("?"))
        func term(_ mode: TextMatchMode) -> SearchExpression { .term(SearchTerm(property, .text(text, mode))) }
        // Extensions compare whole: `ext:doc` must not match .docx.
        let defaultMode: TextMatchMode = hasWildcard ? .wildcard : (property == .fileExtension ? .equals : .contains)
        switch op {
        case "": return term(defaultMode)
        case "=": return term(.equals)
        case "<>": return .not(term(.equals))
        case "~<": return term(.beginsWith)
        case "~=": return term(.contains)
        case "~!": return .not(term(.contains))
        case "~": return term(text.contains("*") || text.contains("?") ? .wildcard : .contains)   // explicit: even in quotes
        default:
            throw SearchSyntaxError("“\(property.keyword):\(op)” compares numbers or dates. For text, use “\(property.keyword):value”, “~<” (begins with) or “=” (exact).")
        }
    }

    /// Applies an operator to an interval: `:`/`=` → inside, `>` → after it, `>=` → from its start,
    /// `<` → before it, `<=` → up to its end, `<>` → outside, `a..b` → from a's start to b's end.
    /// A numeric size is also a point (`size:>1MB` means more than 1,048,576 bytes, not ≥ 2 MB).
    private func rangeRestriction(_ property: SearchProperty, op: String, value: String,
                                  interval: (String) throws -> (Double?, Double?, Double?)) throws -> SearchExpression {
        var lower: Double?
        var upper: Double?
        if let dots = value.range(of: "..") {
            guard op.isEmpty || op == "=" else { throw SearchSyntaxError("A range like “a..b” can't also have “\(op)”.") }
            let a = String(value[..<dots.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(value[dots.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, !b.isEmpty else { throw SearchSyntaxError("A range needs a value on both sides of “..”, for example \(Self.example(for: property)).") }
            let ia = try interval(a)
            let ib = try interval(b)
            lower = ia.2 ?? ia.0
            upper = ib.2.map { $0 + 1 } ?? ib.1
            if let l = lower, let u = upper, l >= u { throw SearchSyntaxError("The range “\(value)” ends before it starts.") }
        } else {
            let (lo, hi, point) = try interval(value)
            switch op {
            case "", "=": lower = lo; upper = hi
            case ">": lower = point.map { $0 + 1 } ?? hi; upper = nil
            case ">=": lower = point ?? lo; upper = nil
            case "<": lower = nil; upper = point ?? lo
            case "<=": lower = nil; upper = point.map { $0 + 1 } ?? hi
            case "<>":
                return .not(makeRange(property, lo, hi))
            default:
                throw SearchSyntaxError("“\(property.keyword):\(op)” isn't supported. Use =, <>, >, >=, <, <= or a range a..b.")
            }
        }
        return makeRange(property, lower, upper)
    }

    private func makeRange(_ property: SearchProperty, _ lower: Double?, _ upper: Double?) -> SearchExpression {
        if property.valueType == .size {
            return .term(SearchTerm(property, .sizeRange(lower: lower.map { Int64($0) }, upper: upper.map { Int64($0) })))
        }
        return .term(SearchTerm(property, .dateRange(lower: lower.map(Date.init(timeIntervalSinceReferenceDate:)),
                                                     upper: upper.map(Date.init(timeIntervalSinceReferenceDate:)))))
    }

    static func kind(_ value: String) throws -> SearchKind {
        if let kind = SearchKind.lookup(value) { return kind }
        if let windows = SearchKind.windowsOnly[value.lowercased()] {
            throw SearchSyntaxError("“kind:\(value)” (\(windows)) is a Windows kind with no macOS equivalent, so Arbor can't search for it.")
        }
        throw SearchSyntaxError("“kind:\(value)” isn't a kind Arbor knows. Try folder, document, picture, music, video, text, program, link, email, contact, calendar, playlist or unknown.")
    }

    // MARK: Sizes

    /// Explorer's size names (Search options ▸ Size). KB = 1,024 bytes, as Explorer counts.
    public static let sizeNames: [(name: String, title: String, lower: Int64, upper: Int64?)] = [
        ("empty", "Empty (0 KB)", 0, 1),
        ("tiny", "Tiny (0 – 16 KB)", 1, 16 * 1024),
        ("small", "Small (16 KB – 1 MB)", 16 * 1024, 1 << 20),
        ("medium", "Medium (1 – 128 MB)", 1 << 20, 128 << 20),
        ("large", "Large (128 MB – 1 GB)", 128 << 20, 1 << 30),
        ("huge", "Huge (1 – 4 GB)", 1 << 30, 4 << 30),
        ("gigantic", "Gigantic (> 4 GB)", 4 << 30, nil),
    ]

    /// `500` = exactly 500 bytes; `5MB` = 5.0–5.99… MB (what Explorer would display as “5 MB”); `large` = a named band.
    static func sizeInterval(_ text: String) throws -> (lower: Int64?, upper: Int64?, point: Int64?) {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if let named = sizeNames.first(where: { $0.name == t }) { return (named.lower, named.upper, nil) }
        let units: [(String, Double)] = [("bytes", 1), ("byte", 1), ("kb", 1024), ("mb", Double(1 << 20)), ("gb", Double(1 << 30)),
                                         ("tb", Double(1 << 40)), ("k", 1024), ("m", Double(1 << 20)), ("g", Double(1 << 30)),
                                         ("t", Double(1 << 40)), ("b", 1)]
        var number = t
        var multiplier: Double = 1
        for (suffix, factor) in units where t.hasSuffix(suffix) {
            number = String(t.dropLast(suffix.count))
            multiplier = factor
            break
        }
        guard let n = Double(number), n >= 0, n.isFinite else {
            throw SearchSyntaxError("“\(text)” isn't a size Arbor understands. Use a number with KB, MB or GB (like 5MB) or empty, tiny, small, medium, large, huge, gigantic.")
        }
        let lower = n * multiplier
        let point = Int64(lower.rounded(.up))
        if multiplier == 1 { return (point, point + 1, point) }
        let whole = n.rounded(.down) == n
        let step = whole ? multiplier : multiplier / 10
        return (point, Int64((lower + step).rounded(.up)), point)
    }

    // MARK: Dates

    /// Explorer's Date modified menu, in order.
    public static let dateKeywords: [(keyword: String, title: String)] = [
        ("today", "Today"), ("yesterday", "Yesterday"), ("this week", "This week"), ("last week", "Last week"),
        ("this month", "This month"), ("last month", "Last month"), ("this year", "This year"), ("last year", "Last year"),
    ]

    /// Relative words use the injected calendar (week start, time zone); explicit dates are US order
    /// (M/D/Y, like the documented `date:11/13/21`) or ISO (2026-11-07, 2026-11, 2026).
    func dateInterval(_ text: String) throws -> (lower: Date?, upper: Date?) {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let cal = calendar
        func interval(_ unit: Calendar.Component, offset: Int) -> (Date?, Date?) {
            guard let base = cal.dateInterval(of: unit, for: now),
                  let start = cal.date(byAdding: unit, value: offset, to: base.start),
                  let end = cal.date(byAdding: unit, value: 1, to: start) else { return (nil, nil) }
            return (start, end)
        }
        switch t {
        case "today": return interval(.day, offset: 0)
        case "yesterday": return interval(.day, offset: -1)
        case "tomorrow": return interval(.day, offset: 1)
        case "this week": return interval(.weekOfYear, offset: 0)
        case "last week", "past week": return interval(.weekOfYear, offset: -1)
        case "next week": return interval(.weekOfYear, offset: 1)
        case "this month": return interval(.month, offset: 0)
        case "last month", "past month": return interval(.month, offset: -1)
        case "next month": return interval(.month, offset: 1)
        case "this year": return interval(.year, offset: 0)
        case "last year", "past year": return interval(.year, offset: -1)
        case "next year": return interval(.year, offset: 1)
        default: break
        }
        if let parsed = explicitDate(t) { return parsed }
        throw SearchSyntaxError("“\(text)” isn't a date Arbor understands. Use today, yesterday, this week, last week, this month, last month, this year, last year, or a date like 11/13/2026 or 2026-11-13.")
    }

    private func explicitDate(_ t: String) -> (Date?, Date?)? {
        func day(_ y: Int, _ m: Int, _ d: Int) -> (Date?, Date?)? {
            var c = DateComponents()
            c.year = y; c.month = m; c.day = d
            guard (1...12).contains(m), (1...31).contains(d), let start = calendar.date(from: c),
                  calendar.component(.day, from: start) == d,
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return (start, end)
        }
        func year(_ s: Substring) -> Int? {
            guard let n = Int(s) else { return nil }
            if s.count == 2 { return n < 70 ? 2000 + n : 1900 + n }
            return s.count == 4 ? n : nil
        }
        let slash = t.split(separator: "/", omittingEmptySubsequences: false)
        if slash.count == 3, let m = Int(slash[0]), let d = Int(slash[1]), let y = year(slash[2]) { return day(y, m, d) }
        let dash = t.split(separator: "-", omittingEmptySubsequences: false)
        if dash.count == 3, dash[0].count == 4, let y = Int(dash[0]), let m = Int(dash[1]), let d = Int(dash[2]) { return day(y, m, d) }
        if dash.count == 2, dash[0].count == 4, let y = Int(dash[0]), let m = Int(dash[1]), (1...12).contains(m) {
            var c = DateComponents(); c.year = y; c.month = m; c.day = 1
            guard let start = calendar.date(from: c), let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return (start, end)
        }
        if t.count == 4, let y = Int(t), y > 1900 {
            var c = DateComponents(); c.year = y; c.month = 1; c.day = 1
            guard let start = calendar.date(from: c), let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
            return (start, end)
        }
        return nil
    }
}

// MARK: - Editing queries from the Search options menu (FE-136)

/// Adds, replaces or removes one property restriction in the query text, like Explorer's Search options
/// menu (choosing Date modified ▸ Today appends `datemodified:today`, replacing an earlier date filter).
public enum AQSQueryEditor {
    /// Top-level restrictions for `property` in the query text, as (text, value) pairs.
    public static func restrictions(_ property: SearchProperty, in query: String) -> [String] {
        guard let tokens = try? AQSParser.tokenize(query) else { return [] }
        return topLevelRestrictionRanges(property, tokens).map { range in
            let chars = Array(query)
            return String(chars[range])
        }
    }

    /// The query with every top-level `property:` restriction removed and `property:value` appended
    /// (value nil = just remove). Values with spaces are quoted.
    public static func setting(_ property: SearchProperty, to value: String?, in query: String) -> String {
        var chars = Array(query)
        if let tokens = try? AQSParser.tokenize(query) {
            for range in topLevelRestrictionRanges(property, tokens).reversed() { chars.removeSubrange(range) }
        }
        var text = String(chars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let value, !value.isEmpty {
            let shown = value.contains(" ") ? "\"\(value)\"" : value
            text += (text.isEmpty ? "" : " ") + property.keyword + ":" + shown
        }
        return text
    }

    /// Character ranges of top-level restrictions (outside parentheses), including a following
    /// quoted value and the second word of `last week`.
    static func topLevelRestrictionRanges(_ property: SearchProperty, _ tokens: [AQSParser.Token]) -> [Range<Int>] {
        var depth = 0
        var ranges: [Range<Int>] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            switch token.kind {
            case .lparen: depth += 1
            case .rparen: depth = max(0, depth - 1)
            case .property(let p, let rest, _) where p == property && depth == 0 && !token.negated:
                var end = token.end
                let value = AQSParser.splitOperator(rest).1
                if value.isEmpty, i + 1 < tokens.count, tokens[i + 1].start == token.end, case .phrase = tokens[i + 1].kind {
                    end = tokens[i + 1].end
                    i += 1
                } else if property.valueType == .date, ["this", "last", "past", "next"].contains(value.lowercased()),
                          i + 1 < tokens.count, case .word(let w) = tokens[i + 1].kind, ["week", "month", "year"].contains(w.lowercased()) {
                    end = tokens[i + 1].end
                    i += 1
                }
                ranges.append(token.start..<end)
            default: break
            }
            i += 1
        }
        return ranges
    }
}
