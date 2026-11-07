import Foundation

/// Parses `bsdtar -tv --numeric-owner` output (run with `LC_ALL=en_US.UTF-8`).
///
/// Each line is `mode nlink uid gid size Mon day HH:MM|YYYY name[ -> target| link to target]`.
/// bsdtar escapes unprintable characters in names (`\n`, `\\`, `\ooo`), so a name never spans lines.
/// The date is minute-precise (or year-only for old entries) and in local time, as bsdtar prints it.
public enum BsdtarListing {
    public struct Result: Sendable {
        public var entries: [ArchiveEntry]
        /// Lines that didn't match the expected shape (reported, never guessed at).
        public var malformedLines: Int
    }

    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Result {
        var entries: [ArchiveEntry] = []
        var malformed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseLine(line, now: now, timeZone: timeZone) { entries.append(entry) } else { malformed += 1 }
        }
        return Result(entries: entries, malformedLines: malformed)
    }

    public static func parseLine(_ line: Substring, now: Date = Date(), timeZone: TimeZone = .current) -> ArchiveEntry? {
        var rest = line[...]
        var fields: [Substring] = []
        // Eight whitespace-separated fields, then exactly one space, then the (escaped) name.
        for _ in 0..<8 {
            rest = rest.drop(while: { $0 == " " })
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        guard rest.first == " " else { return nil }
        rest = rest.dropFirst()
        guard !rest.isEmpty else { return nil }

        let mode = fields[0]
        guard mode.count >= 10, let typeChar = mode.first else { return nil }
        var kind: ArchiveEntry.Kind
        switch typeChar {
        case "-": kind = .file
        case "d": kind = .directory
        case "l": kind = .symlink
        case "h": kind = .hardlink
        case "c", "b", "p", "s": kind = .special
        default: return nil
        }

        var namePart = rest
        var target: Substring?
        if kind == .symlink, let r = namePart.range(of: " -> ") {
            target = namePart[r.upperBound...]
            namePart = namePart[..<r.lowerBound]
        } else if kind == .hardlink, let r = namePart.range(of: " link to ") {
            target = namePart[r.upperBound...]
            namePart = namePart[..<r.lowerBound]
        }
        let name = unescape(namePart)
        guard !name.isEmpty else { return nil }
        let size = Int64(fields[4])
        return ArchiveEntry(rawPath: name, kind: kind, size: kind == .file ? size : nil,
                            modified: date(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now, timeZone: timeZone),
                            linkTarget: target.map(unescape))
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// bsdtar prints "%b %e %H:%M" within six months of now, otherwise "%b %e  %Y".
    static func date(month: Substring, day: Substring, timeOrYear: Substring, now: Date, timeZone: TimeZone) -> Date? {
        guard let m = months.firstIndex(of: String(month)), let d = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var c = DateComponents()
        c.month = m + 1
        c.day = d
        if let colon = timeOrYear.firstIndex(of: ":") {
            guard let h = Int(timeOrYear[..<colon]), let min = Int(timeOrYear[timeOrYear.index(after: colon)...]) else { return nil }
            c.hour = h
            c.minute = min
            // The year is implied: the one that puts the date within six months of now.
            let year = calendar.component(.year, from: now)
            c.year = year
            guard var result = calendar.date(from: c) else { return nil }
            if result.timeIntervalSince(now) > 183 * 86_400 {
                c.year = year - 1
                result = calendar.date(from: c) ?? result
            } else if now.timeIntervalSince(result) > 183 * 86_400 {
                c.year = year + 1
                result = calendar.date(from: c) ?? result
            }
            return result
        }
        guard let year = Int(timeOrYear) else { return nil }
        c.year = year
        return calendar.date(from: c)
    }

    /// Reverses bsdtar's `safe_fprintf` escaping. Octal escapes are bytes, decoded as UTF-8.
    public static func unescape(_ s: Substring) -> String {
        guard s.contains("\\") else { return String(s) }
        var bytes: [UInt8] = []
        let utf8 = Array(s.utf8)
        var i = 0
        while i < utf8.count {
            let b = utf8[i]
            guard b == UInt8(ascii: "\\"), i + 1 < utf8.count else { bytes.append(b); i += 1; continue }
            let next = utf8[i + 1]
            switch next {
            case UInt8(ascii: "\\"): bytes.append(0x5C); i += 2
            case UInt8(ascii: "n"): bytes.append(0x0A); i += 2
            case UInt8(ascii: "t"): bytes.append(0x09); i += 2
            case UInt8(ascii: "r"): bytes.append(0x0D); i += 2
            case UInt8(ascii: "a"): bytes.append(0x07); i += 2
            case UInt8(ascii: "b"): bytes.append(0x08); i += 2
            case UInt8(ascii: "f"): bytes.append(0x0C); i += 2
            case UInt8(ascii: "v"): bytes.append(0x0B); i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var j = i + 1
                while j < utf8.count, j < i + 4, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(utf8[j]) {
                    value = value * 8 + Int(utf8[j] - UInt8(ascii: "0"))
                    j += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                i = j
            default:
                bytes.append(b); i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// An inclusion pattern that matches `name` literally (libarchive treats `* ? [ ] \` as wildcards).
    /// A pattern also matches everything below it, so a folder pattern selects its whole subtree.
    public static func literalPattern(_ name: String) -> String {
        var out = ""
        var trimmed = Substring(name)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        for ch in trimmed {
            if "*?[]\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
