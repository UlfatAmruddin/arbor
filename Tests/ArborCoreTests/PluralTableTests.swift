import Foundation
import Testing
@testable import ArborCore

/// A resources folder with an English plural table and whatever a test adds.
private final class PluralFixture {
    static let english: [String: PluralTable.Forms] = [
        "%lld items": ["one": "%lld item", "other": "%lld items"],
        "%2$@ has %1$lld files": ["one": "%2$@ has %1$lld file", "other": "%2$@ has %1$lld files"],
    ]
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-tests-\(UUID().uuidString)")
        try write(strings: "\"Open\" = \"Open\";\n", language: "en")
        try write(plurals: Self.english, language: "en")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ language: String) throws -> URL {
        let folder = root.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func write(strings: String, language: String) throws {
        try Data(strings.utf8).write(to: try folder(language).appendingPathComponent(StringTableCheck.tableName))
    }

    func write(plurals: [String: PluralTable.Forms], language: String) throws {
        try write(plurals: try PluralTable.data(plurals), language: language)
    }

    func write(plurals data: Data, language: String) throws {
        try data.write(to: try folder(language).appendingPathComponent(PluralTable.tableName))
    }

    /// `language` with its one string translated, so only the plural table can fail.
    func translate(_ plurals: [String: PluralTable.Forms], language: String) throws -> StringTableCheck.Report {
        try write(strings: "\"Open\" = \"Ouvrir\";\n", language: language)
        try write(plurals: plurals, language: language)
        return try #require(try StringTableCheck.check(resources: root).first { $0.language == language })
    }

    /// A bundle holding only the folders of `languages`.
    func bundle(languages: [String]) throws -> Bundle {
        let name = "T-\(languages.joined(separator: "+")).bundle"
        let resources = root.appendingPathComponent("\(name)/Contents/Resources", isDirectory: true)
        if !FileManager.default.fileExists(atPath: resources.path) {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            for language in languages {
                try FileManager.default.copyItem(at: try folder(language), to: resources.appendingPathComponent("\(language).lproj"))
            }
        }
        return try #require(Bundle(url: root.appendingPathComponent(name)))
    }

    func plural(_ count: Int, _ arguments: CVarArg..., key: String = "%lld items", language: String, locale: String) throws -> String {
        let bundle = try bundle(languages: [language])
        let english = try #require(Self.english[key])
        return L10n.plural(one: english["one"] ?? "", other: key, count, arguments, in: bundle,
                           usable: PluralTable.usableKeys(in: bundle, language: language), locale: Locale(identifier: locale))
    }
}

private let arabic: PluralTable.Forms = ["zero": "zero %lld", "one": "one %lld", "two": "two %lld", "few": "few %lld", "many": "many %lld", "other": "other %lld"]

@Suite("Plural tables (FE-204)")
struct PluralTableCheckTests {
    @Test func allSixArabicFormsPass() throws {
        let report = try PluralFixture().translate(["%lld items": arabic], language: "ar")
        #expect(report.errors.isEmpty)
        #expect(report.missing == 1)   // the other plural
    }

    @Test func japaneseWithOnlyOtherPasses() throws {
        #expect(try PluralFixture().translate(["%lld items": ["other": "%lld 項目"]], language: "ja").errors.isEmpty)
    }

    @Test func aReorderedFormPasses() throws {
        let forms = ["one": "%1$lld Datei in %2$@", "other": "%1$lld Dateien in %2$@"]
        #expect(try PluralFixture().translate(["%2$@ has %1$lld files": forms], language: "de").errors.isEmpty)
    }

    @Test func everyFormMustCarryTheSameSpecifiers() throws {
        let forms = ["one": "one item", "few": "%d items", "other": "%lld items %@"]
        let errors = try PluralFixture().translate(["%lld items": forms], language: "ru").errors
        #expect(errors.count == 3)
        #expect(errors.allSatisfy { $0.hasPrefix("format specifiers differ") })
    }

    @Test func otherIsRequiredAndCategoriesAreCLDRs() throws {
        let errors = try PluralFixture().translate(["%lld items": ["one": "%lld item", "dual": "%lld items"]], language: "fr").errors
        #expect(errors.contains { $0.hasPrefix("no \"other\" form") })
        #expect(errors.contains { $0.hasPrefix("unknown plural category \"dual\"") })
    }

    @Test func emptyFormsAndUnknownKeysFail() throws {
        let errors = try PluralFixture().translate(["%lld items": ["other": ""], "%lld itmes": ["other": "%lld"]], language: "fr").errors
        #expect(errors.contains { $0.hasPrefix("empty \"other\" form") })
        #expect(errors.contains { $0 == "unknown key \"%lld itmes\"" })
    }

    @Test func anyOtherShapeIsRefused() throws {
        let fx = try PluralFixture()
        try fx.write(strings: "\"Open\" = \"Ouvrir\";\n", language: "fr")
        let twoVariables = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>%lld items</key><dict>
        <key>NSStringLocalizedFormatKey</key><string>%#@count@ %#@more@</string><key>count</key><dict>
        <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string><key>NSStringFormatValueTypeKey</key><string>lld</string>
        <key>other</key><string>%lld</string></dict></dict></dict></plist>
        """
        try fx.write(plurals: Data(twoVariables.utf8), language: "fr")
        let errors = try #require(try StringTableCheck.check(resources: fx.root).first { $0.language == "fr" }).errors
        #expect(errors.first?.contains("must hold one plural rule") == true)
        try fx.write(plurals: Data("not a plist".utf8), language: "fr")
        #expect(try StringTableCheck.check(resources: fx.root).first { $0.language == "fr" }?.errors == ["fr.lproj/Localizable.stringsdict: not a well-formed property list"])
    }

    @Test func aLanguageWithoutAPluralTableCountsItsSentencesAsMissing() throws {
        let fx = try PluralFixture()
        try fx.write(strings: "\"Open\" = \"Ouvrir\";\n", language: "fr")
        let report = try #require(try StringTableCheck.check(resources: fx.root).first { $0.language == "fr" })
        #expect(report.errors.isEmpty)
        #expect(report.missing == 2)   // both plurals
    }

    /// Foundation would expand the variable inside its own form until it crashed.
    @Test func aFormThatNamesTheCountVariableIsRefused() throws {
        let key = "%lld items copied to “%@”."
        for form in ["%lld éléments copiés dans « %#@count@ »", "%1$lld éléments copiés dans « %2$#@count@ »"] {
            #expect(PluralTable.problems(key: key, forms: ["other": form]).contains { $0.hasPrefix("format specifiers differ") }, "\(form)")
        }
        let errors = try PluralFixture().translate(["%lld items": ["other": "%#@count@"]], language: "fr").errors
        #expect(errors.contains { $0.hasPrefix("format specifiers differ") })
    }

    @Test func theCountMustComeFirst() {
        #expect(PluralTable.problems(key: "%@ has %lld files", forms: ["other": "%@ has %lld files"]).contains("the count must be the first argument, %lld"))
    }
}

@Suite("Plural lookup (FE-204)")
struct PluralLookupTests {
    @Test func arabicPicksEachOfItsSixCategories() throws {
        let fx = try PluralFixture()
        try fx.write(plurals: ["%lld items": arabic], language: "ar")
        let shown = try [0, 1, 2, 3, 11, 100].map { try fx.plural($0, language: "ar", locale: "ar_EG@numbers=latn") }
        #expect(shown == ["zero 0", "one 1", "two 2", "few 3", "many 11", "other 100"])
    }

    @Test func japaneseUsesItsOneFormForEveryCount() throws {
        let fx = try PluralFixture()
        try fx.write(plurals: ["%lld items": ["other": "%lld 項目"]], language: "ja")
        #expect(try fx.plural(1, language: "ja", locale: "ja_JP") == "1 項目")
        #expect(try fx.plural(5, language: "ja", locale: "ja_JP") == "5 項目")
    }

    @Test func aReorderedTranslationFillsByPosition() throws {
        let fx = try PluralFixture()
        try fx.write(plurals: ["%2$@ has %1$lld files": ["one": "%1$lld Datei in %2$@", "other": "%1$lld Dateien in %2$@"]], language: "de")
        #expect(try fx.plural(3, "Docs", key: "%2$@ has %1$lld files", language: "de", locale: "de_DE") == "3 Dateien in Docs")
    }

    @Test func aMissingOrUnsafeTranslationShowsEnglish() throws {
        let fx = try PluralFixture()
        try fx.write(plurals: ["%2$@ has %1$lld files": ["other": "%1$lld %2$@ %3$@"]], language: "fr")
        #expect(try fx.plural(1, language: "fr", locale: "fr_FR") == "1 item")
        #expect(try fx.plural(2, "Docs", key: "%2$@ has %1$lld files", language: "fr", locale: "fr_FR") == "Docs has 2 files")
    }

    @Test func aLanguageWithoutItsOwnTableUsesNoneOfTheEnglishKeys() throws {
        let fx = try PluralFixture()
        try fx.write(strings: "\"%lld items\" = \"%@ éléments\";\n", language: "fr")
        let bundle = try fx.bundle(languages: ["en", "fr"])
        #expect(PluralTable.usableKeys(in: bundle, language: "fr").isEmpty)
        #expect(PluralTable.usableKeys(in: bundle, language: "en") == Set(PluralFixture.english.keys))
    }

    /// `Bundle` returns the `.strings` entry instead of the plural rule, and that entry was never checked.
    @Test func aStringsEntryWithThePluralKeyShowsEnglish() throws {
        let fx = try PluralFixture()
        try fx.write(plurals: ["%lld items": ["one": "%lld élément", "other": "%lld éléments"],
                               "%2$@ has %1$lld files": ["other": "%1$lld fichiers dans %2$@"]], language: "fr")
        try fx.write(strings: "\"%lld items\" = \"%@ éléments\";\n", language: "fr")
        #expect(try fx.plural(3, language: "fr", locale: "fr_FR") == "3 items")
        #expect(try fx.plural(2, "Docs", key: "%2$@ has %1$lld files", language: "fr", locale: "fr_FR") == "2 fichiers dans Docs")
    }

    @Test func aStringsTableThatCantBeReadLeavesNoPluralUsable() throws {
        let fx = try PluralFixture()
        try fx.write(plurals: ["%lld items": ["other": "%lld éléments"]], language: "fr")
        try fx.write(strings: "\"%lld items\" = ", language: "fr")
        #expect(PluralTable.usableKeys(in: try fx.bundle(languages: ["fr"]), language: "fr").isEmpty)
    }

    @Test func withoutATableTheEnglishFormsShow() {
        let locale = Locale(identifier: "en_US")
        let english = { (n: Int) in L10n.plural(one: "%lld item", other: "%lld items", n, [], in: .main, usable: [], locale: locale) }
        #expect([english(0), english(1), english(2), english(1234)] == ["0 items", "1 item", "2 items", "1,234 items"])
    }

    @Test func aLanguageChosenApartFromTheRegionGetsItsOwnRuleWithTheRegionsDigits() throws {
        let locale = L10n.pluralLocale(language: "ar-XB", current: Locale(identifier: "en_CA"))
        #expect(locale.language.languageCode?.identifier == "ar")
        #expect(locale.region?.identifier == "CA")
        let fx = try PluralFixture()
        try fx.write(plurals: ["%lld items": arabic], language: "ar")
        #expect(try fx.plural(2, language: "ar", locale: locale.identifier) == "two 2")
    }

    @Test func theSameLanguageKeepsTheUsersLocale() {
        let current = Locale(identifier: "de_CH")
        #expect(L10n.pluralLocale(language: "de", current: current) == current)
    }
}

@Suite("Plural pseudo-languages (FE-204)")
struct PluralPseudoTests {
    @Test func theGeneratedFormsAreAValidTranslation() throws {
        for style in PseudoLocalization.Style.allCases {
            let forms = PseudoLocalization.plurals(from: PluralFixture.english, style: style)
            var report = StringTableCheck.Report(language: style.rawValue)
            StringTableCheck.check(plurals: forms, base: PluralFixture.english, into: &report)
            #expect(report.errors.isEmpty, "\(report.errors)")
            #expect(report.missing == 0)
        }
    }

    @Test func rightToLeftExercisesAllSixCategoriesAndMarksEach() throws {
        let forms = try #require(PseudoLocalization.plurals(from: PluralFixture.english, style: .rightToLeft)["%lld items"])
        #expect(Set(forms.keys) == Set(PluralTable.categories))
        #expect(forms["two"]?.hasPrefix("②") == true)
        #expect(forms["one"]?.contains("%lld") == true)
        let accented = PseudoLocalization.plurals(from: PluralFixture.english, style: .accented)["%lld items"] ?? [:]
        #expect(Set(accented.keys) == ["one", "other"])
    }
}
