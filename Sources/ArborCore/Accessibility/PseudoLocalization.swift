import Foundation

/// Generates the test-only pseudo-languages (FE-204). Their tables are written to a scratch copy of the app and never shipped.
public enum PseudoLocalization {
    public enum Style: String, CaseIterable, Sendable {
        /// Accented Latin, padded with non-Latin letters: shows length, glyph height and font fallback problems.
        case accented = "en-XA"
        /// Hebrew letters in a right-to-left language: shows mirroring and direction problems.
        case rightToLeft = "ar-XB"
    }

    public static let expansion = 0.4

    private static let accented: [Character: Character] = [
        "a": "á", "b": "ƀ", "c": "ç", "d": "ð", "e": "é", "f": "ƒ", "g": "ĝ", "h": "ĥ", "i": "í", "j": "ĵ",
        "k": "ķ", "l": "ļ", "m": "ɱ", "n": "ñ", "o": "ö", "p": "þ", "q": "ǫ", "r": "ŕ", "s": "š", "t": "ţ",
        "u": "ü", "v": "ṽ", "w": "ŵ", "x": "ẋ", "y": "ý", "z": "ž",
        "A": "Å", "B": "Ɓ", "C": "Ç", "D": "Ð", "E": "É", "F": "Ƒ", "G": "Ĝ", "H": "Ĥ", "I": "Í", "J": "Ĵ",
        "K": "Ķ", "L": "Ļ", "M": "Ṁ", "N": "Ñ", "O": "Ö", "P": "Þ", "Q": "Ǫ", "R": "Ŕ", "S": "Š", "T": "Ţ",
        "U": "Ü", "V": "Ṽ", "W": "Ŵ", "X": "Ẋ", "Y": "Ý", "Z": "Ž",
    ]

    private static let hebrew: [Character: Character] = {
        let letters = Array("אבגדהוזחטיכלמנסעפצקרשתםןףץ")
        var table: [Character: Character] = [:]
        for (latin, letter) in zip("abcdefghijklmnopqrstuvwxyz", letters) {
            table[latin] = letter
            if let upper = latin.uppercased().first { table[upper] = letter }
        }
        return table
    }()

    private static let padding: [Style: [Character]] = [
        .accented: ["ก", "·", "中", "·", "न", "·", "Ж", "·"],
        .rightToLeft: ["م", "·", "ش", "·", "ب", "·", "ע", "·"],
    ]

    /// Letters are replaced and the text grows by about 40 percent; "[…·]" shows when an end is cut off.
    public static func transform(_ text: String, style: Style) -> String {
        guard !text.isEmpty else { return text }
        let table = style == .accented ? accented : hebrew
        var out = ""
        var letters = 0
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "%", let end = endOfSpecifier(characters, from: index) {
                out += String(characters[index..<end])
                index = end
                continue
            }
            out.append(table[character] ?? character)
            if character.isLetter { letters += 1 }
            index += 1
        }
        return "[" + out + pad(letters: letters, style: style) + "·]"
    }

    /// The whole table as `.strings` text.
    public static func table(from english: [String: String], style: Style) -> String {
        english.keys.sorted().map { "\(quoted($0)) = \(quoted(transform($0, style: style)));\n" }.joined()
    }

    private static func pad(letters: Int, style: Style) -> String {
        let cycle = padding[style] ?? ["·"]
        // The brackets and the final dot count toward the growth.
        let count = max(0, Int((Double(letters) * expansion).rounded(.up)) - 3)
        return String((0..<count).map { cycle[$0 % cycle.count] })
    }

    /// Copies a specifier whole ("%1$@", "%.1f", "%lld", "%%"); nil when the percent sign is plain text.
    private static func endOfSpecifier(_ characters: [Character], from start: Int) -> Int? {
        var index = start + 1
        while index < characters.count, "0123456789$.-+ #'lhqzjt".contains(characters[index]) { index += 1 }
        guard index < characters.count, "@dDiuUxXoOfFeEgGaAcCsSp%".contains(characters[index]) else { return nil }
        return index + 1
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
