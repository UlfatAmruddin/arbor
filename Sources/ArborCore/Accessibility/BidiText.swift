import Foundation

/// Keeps names and paths in one piece inside text of the other direction (FE-204). Display only: never store the result.
public enum BidiText {
    private static let firstStrongIsolate = "\u{2068}"
    private static let leftToRightIsolate = "\u{2066}"
    private static let popIsolate = "\u{2069}"

    /// Text inserted into a sentence or shown on its own: it keeps its own direction and can't reorder what's around it.
    public static func isolated(_ text: String, rightToLeftInterface: Bool = L10n.isRightToLeft) -> String {
        let safe = contained(text)
        guard !safe.isEmpty, rightToLeftInterface || hasRightToLeftLetters(safe) else { return safe }
        return firstStrongIsolate + safe + popIsolate
    }

    /// A path always reads root first; each component keeps its own direction, so "/" can't join two right-to-left names.
    public static func path(_ path: String, rightToLeftInterface: Bool = L10n.isRightToLeft) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(contained)
        guard !path.isEmpty, rightToLeftInterface || parts.contains(where: hasRightToLeftLetters) else { return parts.joined(separator: "/") }
        let held = parts.map { hasRightToLeftLetters($0) ? firstStrongIsolate + $0 + popIsolate : $0 }
        return leftToRightIsolate + held.joined(separator: "/") + popIsolate
    }

    /// Shown text as it should leave the app: copied without the marks that only hold its direction.
    public static func withoutIsolates(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) })
        return String(kept)
    }

    /// Drops what could escape an isolate, overrides and unpaired marks; paired marks stay so text already isolated can be nested.
    private static func contained<S: StringProtocol>(_ text: S) -> String {
        guard text.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
            return String(text)
        }
        var kept: [Unicode.Scalar?] = []
        var unclosed: [Int] = []
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x202A...0x202E: continue
            case 0x2066...0x2068:
                unclosed.append(kept.count)
                kept.append(scalar)
            case 0x2069:
                if unclosed.popLast() != nil { kept.append(scalar) }
            default: kept.append(scalar)
            }
        }
        unclosed.forEach { kept[$0] = nil }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: kept.compactMap { $0 })
        return String(result)
    }

    static func hasRightToLeftLetters<S: StringProtocol>(_ text: S) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFC, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
            default: return false
            }
        }
    }
}
