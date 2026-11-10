import Foundation

/// Finds English text handed straight to something the user reads (FE-204). Narrow on purpose: it knows the
/// sinks below, so text built elsewhere and passed in as a variable is left to `l10naudit:`.
enum UserVisibleLiteralScan {
    struct Finding: Equatable, CustomStringConvertible {
        var file: String
        var line: Int
        var text: String
        var description: String { "\(file):\(line): \(text)" }
    }

    /// Properties whose value is shown or read aloud; the assigned expression is checked.
    static let properties: Set<String> = [
        "stringValue", "title", "placeholderString", "toolTip", "messageText", "informativeText", "prompt", "nameFieldLabel",
    ]

    /// Calls whose arguments are shown: labels, buttons, menu items, alerts, status text and error messages.
    /// `Type.name` only counts when called on that type.
    static let calls: Set<String> = [
        "NSTextField", "NSButton", "NSMenuItem", "ClosureMenuItem", "FluentButton", "SheetLabel.make", "SheetLabel.wrapping",
        "addButton", "addItem", "show", "showError", "showMessage", "setMessage", "drawPair", "present",
        "setAccessibilityLabel", "setAccessibilityHelp", "setAccessibilityTitle", "setAccessibilityValue",
        "SearchSyntaxError", "failed", "skipped", "invalid", "invalidValue", "unreadable", "unavailable", "toolFailed", "expansion",
        "message", "copiedButSourceRemains", "fail",
    ]

    /// Parameters whose plain literals `scripts/extract-strings.sh` collects, or that carry a sentence; a literal with
    /// `\(…)` can't be a table key, so it never reaches a translation.
    static let interpolatedParameters: Set<String> = ["title", "tooltip", "info", "verb"]

    /// Debug output and scripted checks compare fixed English, and developer diagnostics are for contributors.
    static func isExcluded(_ path: String) -> Bool {
        ["Debug", "Script", "Audit", "FakeNetwork", "ExtensionCatalog", "ExtensionPoint", "FeatureGraph", "/Performance/"]
            .contains { path.contains($0) }
    }

    static func scan(_ source: String, file: String) -> [Finding] {
        var lexer = Lexer(source)
        let tokens = lexer.tokens()
        var findings: [Finding] = []
        for (index, token) in tokens.enumerated() {
            guard case .word(let word) = token.kind, index + 2 < tokens.count else { continue }
            let next = tokens[index + 1].kind, afterNext = tokens[index + 2].kind
            let owner = index >= 2 && tokens[index - 1].kind == .punctuation(".") ? tokens[index - 2].kind : nil
            if word == "L10n", index + 4 < tokens.count, next == .punctuation("."), tokens[index + 3].kind == .punctuation("("),
               case .string(let text, interpolated: true) = tokens[index + 4].kind {
                // A key built with `\(…)` never matches a table entry, so it always shows in English.
                findings.append(Finding(file: file, line: tokens[index + 4].line, text: text))
            } else if properties.contains(word), owner != nil, next == .punctuation("="), afterNext != .punctuation("=") {
                findings += literals(in: tokens, from: index + 2, untilEndOfStatement: true, file: file)
            } else if next == .punctuation("("), calls.contains(word) || owner.map({ calls.contains("\(name($0)).\(word)") }) == true {
                findings += literals(in: tokens, from: index + 2, untilEndOfStatement: false, file: file)
            } else if interpolatedParameters.contains(word), next == .punctuation(":"),
                      case .string(let text, interpolated: true) = afterNext, hasWords(text) {
                findings.append(Finding(file: file, line: tokens[index + 2].line, text: text))
            }
        }
        return findings
    }

    private static func name(_ kind: Token.Kind) -> String {
        if case .word(let word) = kind { return word }
        return ""
    }

    /// Text with no run of Latin letters is punctuation or a placeholder: nothing to translate.
    private static func hasWords(_ text: String) -> Bool {
        text.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
    }

    /// Calls and labels whose literals aren't shown (paths, identifiers, images), or are already routed.
    private static let skipped: Set<String> = [
        "L10n", "contains", "hasPrefix", "hasSuffix", "replacingOccurrences", "fileURLWithPath", "NSImage", "systemSymbolName", "id",
    ]

    private static func literals(in tokens: [Token], from start: Int, untilEndOfStatement: Bool, file: String) -> [Finding] {
        var findings: [Finding] = []
        var depth = 0
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .punctuation(let c) where "([{".contains(c): depth += 1
            case .punctuation(let c) where ")]}".contains(c):
                if depth == 0 { return findings }
                depth -= 1
            case .newline where untilEndOfStatement && depth == 0 && !continues(after: index, tokens):
                return findings
            case .word(let word) where skipped.contains(word):
                index = skipping(tokens, at: index)
                continue
            case .string(let text, _) where hasWords(text) && !isCompared(tokens, at: index):
                findings.append(Finding(file: file, line: token.line, text: text))
            default: break
            }
            index += 1
        }
        return findings
    }

    /// `x == "recent"`: a value tested, not shown.
    private static func isCompared(_ tokens: [Token], at index: Int) -> Bool {
        guard index >= 2, tokens[index - 1].kind == .punctuation("=") else { return false }
        return tokens[index - 2].kind == .punctuation("=") || tokens[index - 2].kind == .punctuation("!")
    }

    /// A statement continues on the next line when that line starts with an operator.
    private static func continues(after newline: Int, _ tokens: [Token]) -> Bool {
        guard newline + 1 < tokens.count, case .punctuation(let c) = tokens[newline + 1].kind else { return false }
        return "?:+.".contains(c)
    }

    /// Past a skipped call (`L10n.tr(…)`, `contains(…)`) or a skipped label and its value (`id: "…"`).
    private static func skipping(_ tokens: [Token], at start: Int) -> Int {
        var index = start + 1
        while index + 1 < tokens.count, tokens[index].kind == .punctuation("."), case .word = tokens[index + 1].kind { index += 2 }
        guard index < tokens.count else { return index }
        if tokens[index].kind == .punctuation(":") { return min(index + 2, tokens.count) }
        guard tokens[index].kind == .punctuation("(") else { return index }
        var depth = 0
        while index < tokens.count {
            if tokens[index].kind == .punctuation("(") { depth += 1 }
            if tokens[index].kind == .punctuation(")") {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return index
    }

    struct Token {
        enum Kind: Equatable { case word(String), string(String, interpolated: Bool), punctuation(Character), newline }
        var kind: Kind
        var line: Int
    }

    /// Just enough of Swift's lexical structure: comments, strings (raw, multi-line, interpolated), words, punctuation.
    struct Lexer {
        private let characters: [Character]
        private var index = 0
        private var line = 1

        init(_ source: String) { characters = Array(source) }

        mutating func tokens() -> [Token] {
            var out: [Token] = []
            while index < characters.count {
                let c = characters[index]
                if c == "\n" {
                    out.append(Token(kind: .newline, line: line))
                    line += 1
                    index += 1
                } else if c.isWhitespace {
                    index += 1
                } else if c == "/", peek(1) == "/" {
                    skipLineComment()
                } else if c == "/", peek(1) == "*" {
                    skipBlockComment()
                } else if c == "\"" || (c == "#" && isRawString()) {
                    out.append(string())
                } else if c.isLetter || c == "_" {
                    let start = index
                    while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" { index += 1 }
                    out.append(Token(kind: .word(String(characters[start..<index])), line: line))
                } else {
                    out.append(Token(kind: .punctuation(c), line: line))
                    index += 1
                }
            }
            return out
        }

        private func peek(_ offset: Int) -> Character? { index + offset < characters.count ? characters[index + offset] : nil }

        private func isRawString() -> Bool {
            var offset = 0
            while peek(offset) == "#" { offset += 1 }
            return peek(offset) == "\""
        }

        private mutating func skipLineComment() {
            while index < characters.count, characters[index] != "\n" { index += 1 }
        }

        private mutating func skipBlockComment() {
            index += 2
            var depth = 1
            while index < characters.count, depth > 0 {
                if characters[index] == "\n" { line += 1 }
                if characters[index] == "/", peek(1) == "*" { depth += 1; index += 2; continue }
                if characters[index] == "*", peek(1) == "/" { depth -= 1; index += 2; continue }
                index += 1
            }
        }

        /// One string literal; an interpolation reads as a space, and whatever it holds is skipped.
        private mutating func string() -> Token {
            let startLine = line
            var pounds = 0
            while index < characters.count, characters[index] == "#" { pounds += 1; index += 1 }
            let quotes = peek(1) == "\"" && peek(2) == "\"" ? 3 : 1
            index += quotes
            var text = ""
            var interpolated = false
            while index < characters.count {
                let c = characters[index]
                if c == "\n" { line += 1 }
                if c == "\"", (1..<quotes).allSatisfy({ peek($0) == "\"" }), (0..<pounds).allSatisfy({ peek(quotes + $0) == "#" }) {
                    index += quotes + pounds
                    break
                }
                if c == "\\", (0..<pounds).allSatisfy({ peek(1 + $0) == "#" }) {
                    let after = 1 + pounds
                    if peek(after) == "(" {
                        index += after
                        skipInterpolation()
                        text += " "
                        interpolated = true
                    } else {
                        index += after + 1
                    }
                    continue
                }
                text.append(c)
                index += 1
            }
            return Token(kind: .string(text, interpolated: interpolated), line: startLine)
        }

        /// Balances the parentheses of `\(…)`, stepping over nested string literals.
        private mutating func skipInterpolation() {
            var depth = 0
            repeat {
                let c = characters[index]
                if c == "\n" { line += 1 }
                if c == "\"" {
                    _ = string()
                    continue
                }
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                index += 1
            } while index < characters.count && depth > 0
        }
    }
}
