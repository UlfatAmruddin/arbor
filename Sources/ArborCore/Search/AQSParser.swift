import Foundation

/// Arbor's subset of Windows AQS (spec §10.2, FE-134; table in docs/features/search.md). Only uppercase
/// AND/OR/NOT are operators, folded strictly left to right (FE-236). Anything unreadable is a
/// `SearchSyntaxError`, never silently dropped.
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
            guard !tokens.isEmpty else { throw SearchSyntaxError(L10n.tr("Type something to search for.")) }
            try Self.checkComplexity(tokens)
            var state = State(tokens: tokens, parser: self)
            let expression = try state.parseExpression(property: nil)
            if let extra = state.peek {
                if case .rparen = extra.kind { throw SearchSyntaxError(L10n.tr("There's a “)” without a matching “(”.")) }
                throw SearchSyntaxError(L10n.format("Arbor couldn't read the search from “%@” on.", extra.text))
            }
            return .success(expression)
        } catch let error as SearchSyntaxError {
            return .failure(error)
        } catch {
            return .failure(SearchSyntaxError(error.localizedDescription))
        }
    }

    /// Recursion limits; thousands of pasted "(" or NOTs used to overflow the stack.
    public static let maxTerms = 256
    public static let maxNesting = 32

    static func checkComplexity(_ tokens: [Token]) throws {
        guard tokens.count <= maxTerms else {
            throw SearchSyntaxError(L10n.plural(one: "This search is too long. Use at most %lld word or operator.", other: "This search is too long. Use at most %lld words and operators.", maxTerms))
        }
        var nesting = 0, nots = 0, deepest = 0
        for token in tokens {
            switch token.kind {
            case .lparen: nesting += 1
            case .rparen: nesting = max(nesting - 1, 0)
            default: break
            }
            if case .not = token.kind { nots += 1 } else { nots = 0 }
            deepest = max(deepest, nesting + nots)
        }
        guard deepest <= maxNesting else {
            throw SearchSyntaxError(L10n.tr("This search nests too deeply. Use fewer parentheses or NOTs."))
        }
    }

    // MARK: Tokens

    enum Kind: Equatable {
        case word(String)
        case phrase(String)
        /// `rest` is what followed the colon in the same word.
        case property(SearchProperty, rest: String, name: String)
        case lparen, rparen, and, or, not
    }

    struct Token {
        var kind: Kind
        var text: String
        var start: Int
        var end: Int
        /// Leading `-`.
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
                guard j < chars.count else { throw SearchSyntaxError(L10n.tr("A quotation mark is missing its closing “\"”.")) }
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
                        throw SearchSyntaxError(L10n.format("“%@:” isn't a search property Arbor supports. Supported: name, ext, kind, type, size, datemodified, datecreated, tags, author, content, folderpath (or System.* names). To search for the text itself, put it in quotes: \"%@\".", name, word))
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

    /// Starts with a letter, so "12:30" or "C:\\x" stay plain text.
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

        /// unary ((AND | OR | NOT | ε) unary)*, folded left to right.
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
                if let op { throw SearchSyntaxError(L10n.format("“%@” needs a search term after it.", op)) }
                throw SearchSyntaxError(L10n.tr("Type something to search for."))
            }
            switch token.kind {
            case .not:
                index += 1
                return .not(try parseUnary(property: property, after: "NOT"))
            case .and, .or:
                throw SearchSyntaxError(L10n.format("“%@” needs a search term before it.", token.text))
            case .rparen:
                if let op { throw SearchSyntaxError(L10n.format("“%@” needs a search term after it.", op)) }
                throw SearchSyntaxError(L10n.tr("There's a “)” without a matching “(”."))
            default:
                let primary = try parsePrimary(property: property)
                return token.negated ? .not(primary) : primary
            }
        }

        mutating func parsePrimary(property: SearchProperty?) throws -> SearchExpression {
            guard let token = next() else { throw SearchSyntaxError(L10n.tr("Type something to search for.")) }
            switch token.kind {
            case .lparen:
                let inner = try parseExpression(property: property)
                guard let close = next(), case .rparen = close.kind else {
                    throw SearchSyntaxError(L10n.tr("A “(” is missing its closing “)”."))
                }
                return inner
            case .property(let p, let rest, let name):
                if property != nil { throw SearchSyntaxError(L10n.format("“%@:” can't be used inside another property's value.", name)) }
                return try parseRestriction(p, rest: rest, name: name, token: token)
            case .word(let w):
                if let property { return try parser.restriction(property, op: "", value: w, isPhrase: false) }
                if w.contains("*") || w.contains("?") { return .term(.freeText(w, .wildcard)) }
                return .term(.freeText(w))
            case .phrase(let p):
                if let property { return try parser.restriction(property, op: "", value: p, isPhrase: true) }
                guard !p.trimmingCharacters(in: .whitespaces).isEmpty else { throw SearchSyntaxError(L10n.tr("The quotation marks are empty.")) }
                return .term(.freeText(p))
            case .rparen, .and, .or, .not:
                throw SearchSyntaxError(L10n.format("Arbor couldn't read the search at “%@”.", token.text))
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
                            throw SearchSyntaxError(L10n.format("“%@:%@” can't be followed by a group. Use “%@:(a OR b)”.", name, op, name))
                        }
                        index += 1
                        let inner = try parseExpression(property: property)
                        guard let close = next(), case .rparen = close.kind else {
                            throw SearchSyntaxError(L10n.tr("A “(” is missing its closing “)”."))
                        }
                        return inner
                    default: break
                    }
                }
                throw SearchSyntaxError(L10n.format("Type a value right after “%@:%@”, for example %@.", name, op, AQSParser.example(for: property)))
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
        case .date: return L10n.format("%@:today or %@:1/1/2026..1/31/2026", "\(property.keyword)", "\(property.keyword)")
        case .kind: return "kind:picture"
        case .text: return property == .fileExtension ? "ext:pdf" : "\(property.keyword):report"
        }
    }

    // MARK: Values

    func restriction(_ property: SearchProperty, op: String, value raw: String, isPhrase: Bool) throws -> SearchExpression {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value == "[]" {
            guard op == "=" || op.isEmpty || op == "<>" else { throw SearchSyntaxError(L10n.tr("“[]” (no value) only works with “:” or “:=”.")) }
            guard property.valueType == .text, property != .name else {
                throw SearchSyntaxError(L10n.format("Every item has a %@; “%@:[]” can't match anything.", property.label.lowercased(), property.keyword))
            }
            let term = SearchExpression.term(SearchTerm(property, .isEmpty))
            return op == "<>" ? .not(term) : term
        }
        guard !value.isEmpty else { throw SearchSyntaxError(L10n.format("Type a value after “%@:”.", property.keyword)) }
        switch property.valueType {
        case .text: return try textRestriction(property, op: op, value: value, isPhrase: isPhrase)
        case .kind:
            let kind = try Self.kind(value)
            switch op {
            case "", "=": return .term(SearchTerm(property, .kind(kind)))
            case "<>": return .not(.term(SearchTerm(property, .kind(kind))))
            default: throw SearchSyntaxError(L10n.tr("“kind:” only supports “kind:value” or “kind:<>value”."))
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
        guard !text.isEmpty else { throw SearchSyntaxError(L10n.tr("Type an extension after “ext:”, for example ext:pdf.")) }
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
            throw SearchSyntaxError(L10n.format("“%@:%@” compares numbers or dates. For text, use “%@:value”, “~<” (begins with) or “=” (exact).", property.keyword, op, property.keyword))
        }
    }

    /// Numeric sizes also act as points: `size:>1MB` means over 1,048,576 bytes, not ≥ 2 MB.
    private func rangeRestriction(_ property: SearchProperty, op: String, value: String,
                                  interval: (String) throws -> (Double?, Double?, Double?)) throws -> SearchExpression {
        var lower: Double?
        var upper: Double?
        if let dots = value.range(of: "..") {
            guard op.isEmpty || op == "=" else { throw SearchSyntaxError(L10n.format("A range like “a..b” can't also have “%@”.", op)) }
            let a = String(value[..<dots.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(value[dots.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, !b.isEmpty else { throw SearchSyntaxError(L10n.format("A range needs a value on both sides of “..”, for example %@.", Self.example(for: property))) }
            let ia = try interval(a)
            let ib = try interval(b)
            lower = ia.2 ?? ia.0
            upper = ib.2.map { $0 + 1 } ?? ib.1
            if let l = lower, let u = upper, l >= u { throw SearchSyntaxError(L10n.format("The range “%@” ends before it starts.", value)) }
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
                throw SearchSyntaxError(L10n.format("“%@:%@” isn't supported. Use =, <>, >, >=, <, <= or a range a..b.", property.keyword, op))
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
            // The same Windows kind names the Kind menu shows.
            throw SearchSyntaxError(L10n.format("“kind:%@” (%@) is a Windows kind with no macOS equivalent, so Arbor can't search for it.", value, L10n.tr(windows)))
        }
        throw SearchSyntaxError(L10n.format("“kind:%@” isn't a kind Arbor knows. Try folder, document, picture, music, video, text, program, link, email, contact, calendar, playlist or unknown.", value))
    }

    // MARK: Sizes

    /// Explorer's size bands; KB = 1,024 bytes.
    public static let sizeNames: [(name: String, title: String, lower: Int64, upper: Int64?)] = [
        ("empty", L10n.tr("Empty (0 KB)"), 0, 1),
        ("tiny", L10n.tr("Tiny (0 – 16 KB)"), 1, 16 * 1024),
        ("small", L10n.tr("Small (16 KB – 1 MB)"), 16 * 1024, 1 << 20),
        ("medium", L10n.tr("Medium (1 – 128 MB)"), 1 << 20, 128 << 20),
        ("large", L10n.tr("Large (128 MB – 1 GB)"), 128 << 20, 1 << 30),
        ("huge", L10n.tr("Huge (1 – 4 GB)"), 1 << 30, 4 << 30),
        ("gigantic", L10n.tr("Gigantic (> 4 GB)"), 4 << 30, nil),
    ]

    /// `500` = exactly 500 bytes; `5MB` = 5.0–5.99… MB (Explorer's “5 MB”).
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
            throw SearchSyntaxError(L10n.format("“%@” isn't a size Arbor understands. Use a number with KB, MB or GB (like 5MB) or empty, tiny, small, medium, large, huge, gigantic.", text))
        }
        let lower = n * multiplier
        // Beyond 1 EB converting to Int64 would trap.
        guard lower + multiplier < Double(1 << 60) else {
            throw SearchSyntaxError(L10n.format("“%@” is larger than any file can be. Use a smaller size, like 5GB or gigantic.", text))
        }
        let point = Int64(lower.rounded(.up))
        if multiplier == 1 { return (point, point + 1, point) }
        let whole = n.rounded(.down) == n
        let step = whole ? multiplier : multiplier / 10
        return (point, Int64((lower + step).rounded(.up)), point)
    }

    // MARK: Dates

    public static let dateKeywords: [(keyword: String, title: String)] = [
        ("today", L10n.tr("Today")), ("yesterday", L10n.tr("Yesterday")), ("this week", L10n.tr("This week")), ("last week", L10n.tr("Last week")),
        ("this month", L10n.tr("This month")), ("last month", L10n.tr("Last month")), ("this year", L10n.tr("This year")), ("last year", L10n.tr("Last year")),
    ]

    /// Relative words use the injected calendar; explicit dates are M/D/Y or ISO.
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
        throw SearchSyntaxError(L10n.format("“%@” isn't a date Arbor understands. Use today, yesterday, this week, last week, this month, last month, this year, last year, or a date like 11/13/2026 or 2026-11-13.", text))
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

/// Sets or removes one property restriction in the query text, as Explorer's Search options menu does.
public enum AQSQueryEditor {
    /// Top-level restriction texts for `property`.
    public static func restrictions(_ property: SearchProperty, in query: String) -> [String] {
        guard let tokens = try? AQSParser.tokenize(query) else { return [] }
        return topLevelRestrictionRanges(property, tokens).map { range in
            let chars = Array(query)
            return String(chars[range])
        }
    }

    /// Replaces top-level `property:` restrictions with `property:value` (nil only removes).
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

    /// Includes a following quoted value and the second word of `last week`.
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
