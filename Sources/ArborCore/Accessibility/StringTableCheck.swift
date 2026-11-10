import Foundation

/// Validates translated string and plural tables against the English base, for `scripts/extract-strings.sh --check` (FE-204).
public enum StringTableCheck {
    public struct Report: Equatable, Sendable {
        public var language: String
        public var errors: [String] = []
        /// English shows for these, per key, so they are counted but aren't failures.
        public var missing = 0
    }

    public static let tableName = "Localizable.strings"
    public static let baseLanguage = "en"

    /// One report per `<language>.lproj` in `resources` other than English.
    public static func check(resources: URL) throws -> [Report] {
        let baseFolder = resources.appendingPathComponent("\(baseLanguage).lproj", isDirectory: true)
        let base = try parse(baseFolder.appendingPathComponent(tableName))
        let pluralBase = baseFolder.appendingPathComponent(PluralTable.tableName)
        let plurals = FileManager.default.fileExists(atPath: pluralBase.path) ? try PluralTable.parse(pluralBase) : [:]
        return try languages(in: resources).filter { $0 != baseLanguage }.map { language in
            let folder = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
            var report = check(language: language, table: folder.appendingPathComponent(tableName), base: base)
            guard isLanguageIdentifier(language) else { return report }
            checkPlurals(of: folder.appendingPathComponent(PluralTable.tableName), base: plurals, into: &report)
            return report
        }
    }

    /// A language without a plural table shows those sentences in English, like a missing key.
    static func checkPlurals(of table: URL, base: [String: PluralTable.Forms], into report: inout Report) {
        guard FileManager.default.fileExists(atPath: table.path) else {
            report.missing += base.count
            return
        }
        do {
            check(plurals: try PluralTable.parse(table), base: base, into: &report)
        } catch {
            report.errors.append(String(describing: error))
        }
    }

    static func check(plurals translated: [String: PluralTable.Forms], base: [String: PluralTable.Forms], into report: inout Report) {
        report.missing += base.keys.filter { translated[$0] == nil }.count
        for (key, forms) in translated.sorted(by: { $0.key < $1.key }) {
            guard base[key] != nil else {
                report.errors.append("unknown key \(quoted(key))")
                continue
            }
            report.errors += PluralTable.problems(key: key, forms: forms).map { "\($0) for \(quoted(key))" }
        }
    }

    public static func languages(in resources: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: resources.path)
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    /// A malformed file is one error and stops there; everything else is reported together.
    static func check(language: String, table: URL, base: [String: String]) -> Report {
        guard isLanguageIdentifier(language) else {
            return Report(language: language, errors: ["“\(language)” is not a language identifier"])
        }
        do {
            return check(language: language, table: try parse(table), base: base)
        } catch {
            return Report(language: language, errors: [String(describing: error)])
        }
    }

    static func check(language: String, table translated: [String: String], base: [String: String]) -> Report {
        var report = Report(language: language)
        report.missing = base.keys.filter { translated[$0] == nil }.count
        for (key, value) in translated.sorted(by: { $0.key < $1.key }) {
            guard base[key] != nil else {
                report.errors.append("unknown key \(quoted(key))")
                continue
            }
            if value.isEmpty {
                report.errors.append("empty value for \(quoted(key))")
            } else if !FormatSpecifiers.compatible(english: key, translation: value) {
                report.errors.append("format specifiers differ for \(quoted(key)): \(quoted(value))")
            }
        }
        return report
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case unreadable(String), notText(String), malformed(String), notStrings(String)

        public var description: String {
            switch self {
            case .unreadable(let name): return "\(name): can't be read"
            case .notText(let name): return "\(name): not UTF-8 or UTF-16 with a byte order mark"
            case .malformed(let name): return "\(name): not a well-formed .strings file"
            case .notStrings(let name): return "\(name): every entry must be \"key\" = \"value\";"
            }
        }
    }

    private static let maximumBytes = 16 * 1024 * 1024

    /// Parsed by the same property-list reader `Bundle` uses, so a file that passes here loads in the app.
    public static func parse(_ url: URL) throws -> [String: String] {
        let name = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumBytes,
              let data = try? Data(contentsOf: url) else { throw ParseError.unreadable(name) }
        return try parse(data, name: name)
    }

    static func parse(_ data: Data, name: String) throws -> [String: String] {
        let hasByteOrderMark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard hasByteOrderMark || String(data: data, encoding: .utf8) != nil else { throw ParseError.notText(name) }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            throw ParseError.malformed(name)
        }
        guard let table = plist as? [String: String] else { throw ParseError.notStrings(name) }
        return table
    }

    /// `fr`, `pt-BR`, `zh_Hant`: safe to use as a folder name and in Info.plist.
    static func isLanguageIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
