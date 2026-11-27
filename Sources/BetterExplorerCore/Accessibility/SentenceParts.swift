import Foundation

/// A sentence whose arguments are drawn as views (links), cut up in the order the translation puts them (FE-204).
public enum SentenceParts {
    public enum Part: Equatable, Sendable {
        case text(String)
        /// Zero-based position in the argument list.
        case argument(Int)
    }

    /// Understands `%@`, `%1$@` and `%%`, the forms such a template may use; anything else stays text.
    public static func split(_ template: String) -> [Part] {
        var parts: [Part] = []
        var text = ""
        var nextArgument = 0
        var rest = Substring(template)
        func flush() {
            if !text.isEmpty { parts.append(.text(text)) }
            text = ""
        }
        while let character = rest.first {
            guard character == "%" else {
                text.append(character)
                rest = rest.dropFirst()
                continue
            }
            let after = rest.dropFirst()
            if after.first == "%" {
                text.append("%")
                rest = after.dropFirst()
            } else if after.first == "@" {
                flush()
                parts.append(.argument(nextArgument))
                nextArgument += 1
                rest = after.dropFirst()
            } else if let dollar = after.firstIndex(of: "$"), let number = Int(after[..<dollar]), number > 0,
                      after[after.index(after: dollar)...].first == "@" {
                flush()
                parts.append(.argument(number - 1))
                rest = after[after.index(after: dollar)...].dropFirst()
            } else {
                text.append(character)
                rest = after
            }
        }
        flush()
        return parts
    }
}
