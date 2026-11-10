import Foundation

/// Counted sentences in `Localizable.stringsdict`, Foundation's standard plural format (FE-204).
/// Keys are the English plural; each form is a whole sentence with the count as its first argument.
public enum PluralTable {
    public typealias Forms = [String: String]

    public static let tableName = "Localizable.stringsdict"
    public static let categories = ["zero", "one", "two", "few", "many", "other"]

    private static let variable = "count"
    /// The format of every entry, and the text `Bundle` returns for an entry it read from this table.
    static let ruleFormat = "%#@\(variable)@"
    private static let formatKey = "NSStringLocalizedFormatKey"
    private static let specTypeKey = "NSStringFormatSpecTypeKey"
    private static let valueTypeKey = "NSStringFormatValueTypeKey"
    private static let pluralRule = "NSStringPluralRuleType"
    private static let countType = "lld"
    private static let maximumBytes = 16 * 1024 * 1024

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case unreadable(String), malformed(String), wrongShape(file: String, key: String)

        public var description: String {
            switch self {
            case .unreadable(let name): return "\(name): can't be read"
            case .malformed(let name): return "\(name): not a well-formed property list"
            case .wrongShape(let file, let key): return "\(file): \"\(key)\" must hold one plural rule, %#@count@ with an integer value, in plain strings"
            }
        }
    }

    /// Reads the same property list `Bundle` does and refuses any shape other than one plural rule per key.
    public static func parse(_ url: URL) throws -> [String: Forms] {
        let name = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumBytes,
              let data = try? Data(contentsOf: url) else { throw ParseError.unreadable(name) }
        return try parse(data, name: name)
    }

    static func parse(_ data: Data, name: String) throws -> [String: Forms] {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw ParseError.malformed(name)
        }
        var table: [String: Forms] = [:]
        for (key, value) in plist {
            guard let forms = forms(from: value) else { throw ParseError.wrongShape(file: name, key: key) }
            table[key] = forms
        }
        return table
    }

    private static func forms(from value: Any) -> Forms? {
        guard let entry = value as? [String: Any], Set(entry.keys) == [formatKey, variable], entry[formatKey] as? String == ruleFormat,
              let rule = entry[variable] as? [String: String], rule[specTypeKey] == pluralRule, rule[valueTypeKey] == countType else { return nil }
        return rule.filter { $0.key != specTypeKey && $0.key != valueTypeKey }
    }

    /// Every way a translated entry could be unsafe or incomplete; empty when it can reach `String(format:)`.
    public static func problems(key: String, forms: Forms) -> [String] {
        var found: [String] = []
        if forms["other"] == nil { found.append("no \"other\" form") }
        if FormatSpecifiers.arguments(of: key)?.first != .int64 { found.append("the count must be the first argument, %lld") }
        for (category, form) in forms.sorted(by: { $0.key < $1.key }) {
            if !categories.contains(category) {
                found.append("unknown plural category \"\(category)\"")
            } else if form.isEmpty {
                found.append("empty \"\(category)\" form")
            } else if !FormatSpecifiers.compatible(english: key, translation: form) {
                found.append("format specifiers differ in the \"\(category)\" form: \"\(form)\"")
            }
        }
        return found
    }

    /// Safe keys of `language`'s own table (a plain lookup falls back to English's); anything else shows English.
    public static func usableKeys(in bundle: Bundle, language: String) -> Set<String> {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: language),
              let table = try? parse(url), let shadowing = stringsKeys(in: bundle, language: language) else { return [] }
        return Set(table.filter { !shadowing.contains($0.key) && problems(key: $0.key, forms: $0.value).isEmpty }.keys)
    }

    /// `Bundle` prefers a `.strings` entry to the plural rule of the same key, unchecked; nil when that table can't be read.
    private static func stringsKeys(in bundle: Bundle, language: String) -> Set<String>? {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language) else { return [] }
        return (try? StringTableCheck.parse(url)).map { Set($0.keys) }
    }

    /// The whole table as a `.stringsdict` property list.
    public static func data(_ entries: [String: Forms]) throws -> Data {
        let plist = entries.mapValues { forms -> [String: Any] in
            let rule = forms.merging([specTypeKey: pluralRule, valueTypeKey: countType]) { form, _ in form }
            return [formatKey: ruleFormat, variable: rule]
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
