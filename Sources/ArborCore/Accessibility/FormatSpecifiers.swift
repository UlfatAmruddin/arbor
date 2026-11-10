import Foundation

/// The arguments a printf-style string consumes, so a translation can be proven safe for `String(format:)` (FE-204).
public enum FormatSpecifiers {
    public enum Argument: Equatable, Sendable {
        case object, int32, uint32, int64, uint64, double, character, cString, pointer
    }

    /// One argument per position, or nil when no call could fill the string safely:
    /// `%n`, `*` widths, modifiers out of order, numbered and unnumbered mixed, or numbers that repeat or skip a position.
    public static func arguments(of format: String) -> [Argument]? {
        let bytes = Array(format.utf8)
        var unnumbered: [Argument] = []
        var numbered: [Int: Argument] = [:]
        var index = 0
        while index < bytes.count {
            guard bytes[index] == percent else { index += 1; continue }
            index += 1
            guard index < bytes.count else { break }
            if bytes[index] == percent { index += 1; continue }
            let start = index
            guard let specifier = specifier(in: bytes, from: start) else { return nil }
            guard let argument = specifier.argument else { index = start; continue }   // "100%)" is literal text
            if let position = specifier.position {
                guard numbered.updateValue(argument, forKey: position) == nil else { return nil }
            } else {
                unnumbered.append(argument)
            }
            index = specifier.end
        }
        guard numbered.isEmpty else {
            let inOrder = numbered.keys.sorted()
            guard unnumbered.isEmpty, inOrder == Array(1...max(inOrder.count, 1)) else { return nil }
            return inOrder.compactMap { numbered[$0] }
        }
        return unnumbered
    }

    /// True when `translation` takes the same arguments, of the same kinds, as its English key.
    public static func compatible(english: String, translation: String) -> Bool {
        guard let expected = arguments(of: english), let found = arguments(of: translation) else { return false }
        return expected == found
    }

    private static let percent = UInt8(ascii: "%")
    private static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let flags = Set("-+ #0".utf8)
    private static let modifiers = Set("-+ #0123456789.$*[hlqzjtL".utf8)
    private static let refused = Set("nP".utf8)
    private static let lengths = Set(["", "h", "hh", "l", "ll", "q", "z", "t", "j"].map { Array($0.utf8) })

    private struct Specifier { var position: Int?; var argument: Argument?; var end: Int }

    /// `String(format:)` takes modifiers in any order, so all are read first. nil is unsafe; a nil `argument` is a literal percent.
    private static func specifier(in bytes: [UInt8], from start: Int) -> Specifier? {
        let end = bytes[start...].firstIndex { !modifiers.contains($0) } ?? bytes.count
        let written = bytes[start..<end]
        guard let parsed = usualOrder(written), end == bytes.count || !refused.contains(bytes[end]) else { return nil }
        guard end < bytes.count, let argument = argument(bytes[end], length: parsed.length) else {
            return written.isEmpty ? Specifier(position: nil, argument: nil, end: start) : nil
        }
        return Specifier(position: parsed.position, argument: argument, end: end + 1)
    }

    /// Position, flags, width, precision, length; anything else, `*` included, is nil.
    private static func usualOrder(_ written: ArraySlice<UInt8>) -> (position: Int?, length: [UInt8])? {
        var rest = written
        var position: Int?
        let number = rest.prefix { digits.contains($0) }
        if rest.dropFirst(number.count).first == UInt8(ascii: "$") {
            guard let value = Int(String(decoding: number, as: UTF8.self)), value > 0 else { return nil }
            position = value
            rest = rest.dropFirst(number.count + 1)
        }
        rest = skippingNumber(rest.drop { flags.contains($0) })
        if rest.first == UInt8(ascii: ".") { rest = skippingNumber(rest.dropFirst()) }
        let length = Array(rest)
        return lengths.contains(length) ? (position, length) : nil
    }

    /// Skips a width or precision; a longer one is left behind to be refused, because a huge width crashes the formatter.
    private static func skippingNumber(_ rest: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        rest.dropFirst(min(rest.prefix { digits.contains($0) }.count, 4))
    }

    private static func argument(_ conversion: UInt8, length: [UInt8]) -> Argument? {
        let wide = length.contains { $0 != UInt8(ascii: "h") }
        switch Character(UnicodeScalar(conversion)) {
        case "@": return .object
        case "d", "i": return wide ? .int64 : .int32
        case "D": return .int64
        case "u", "x", "X", "o": return wide ? .uint64 : .uint32
        case "U", "O": return .uint64
        case "f", "F", "e", "E", "g", "G", "a", "A": return .double
        case "c", "C": return .character
        case "s", "S": return .cString
        case "p": return .pointer
        default: return nil
        }
    }
}
