import Foundation
import Testing
@testable import ArborCore

/// A resources folder to break on purpose: `en.lproj` plus whatever a test writes.
private final class StringFixture {
    let root: URL

    init(english: String = "\"Open\" = \"Open\";\n\"Cut\" = \"Cut\";\n\"%@ items\" = \"%@ items\";\n\"%@ of %d\" = \"%@ of %d\";\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-tests-\(UUID().uuidString)")
        try write(english, language: "en")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, language: String) throws {
        try write(Data(text.utf8), language: language)
    }

    func write(_ data: Data, language: String) throws {
        let folder = root.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("Localizable.strings"))
    }

    func report(_ language: String) throws -> StringTableCheck.Report {
        try #require(try StringTableCheck.check(resources: root).first { $0.language == language })
    }

    /// A bundle whose only language is `language`, for lookups.
    func bundle(language: String) throws -> Bundle {
        let resources = root.appendingPathComponent("T.bundle/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("\(language).lproj"),
                                         to: resources.appendingPathComponent("\(language).lproj"))
        return try #require(Bundle(url: root.appendingPathComponent("T.bundle")))
    }
}

@Suite("Format specifiers (FE-204)")
struct FormatSpecifierTests {
    @Test func readsEveryKindInOrder() {
        #expect(FormatSpecifiers.arguments(of: "%@ then %d, %ld, %lld, %.1f and %u") == [.object, .int32, .int64, .int64, .double, .uint32])
        #expect(FormatSpecifiers.arguments(of: "plain text") == [])
    }

    @Test func aDoubledPercentAndALiteralPercentTakeNoArgument() {
        #expect(FormatSpecifiers.arguments(of: "%@%% complete") == [.object])
        #expect(FormatSpecifiers.arguments(of: "Default (100%)") == [])
        #expect(FormatSpecifiers.arguments(of: "ends in %") == [])
    }

    @Test func numberedArgumentsGoByPositionNotByOrderInTheText() {
        #expect(FormatSpecifiers.arguments(of: "%2$d von %1$@") == [.object, .int32])
        #expect(FormatSpecifiers.compatible(english: "%@ of %d", translation: "%2$d von %1$@"))
    }

    @Test func anyMismatchInKindOrCountIsRefused() {
        #expect(!FormatSpecifiers.compatible(english: "%@ items", translation: "%d items"))
        #expect(!FormatSpecifiers.compatible(english: "%@ items", translation: "items"))
        #expect(!FormatSpecifiers.compatible(english: "%@ items", translation: "%@ items %@"))
        #expect(!FormatSpecifiers.compatible(english: "%d items", translation: "%ld items"))
        #expect(!FormatSpecifiers.compatible(english: "%@ of %d", translation: "%1$d von %2$@"))
    }

    @Test func aSpaceFlagIsASpecifierSoAStrayPercentIsCaught() {
        #expect(FormatSpecifiers.arguments(of: "50 % done") == [.int32])
        #expect(!FormatSpecifiers.compatible(english: "Half", translation: "50 % done"))
    }

    @Test func formsThatCannotBeFilledSafelyAreRefused() {
        for format in ["%n", "%1$n", "%*d", "%.*f", "%1$@ %@", "%1$@ %1$@", "%2$@", "%1$@ %3$@", "%0$@", "%Lf"] {
            #expect(FormatSpecifiers.arguments(of: format) == nil, "\(format)")
        }
    }

    @Test func modifiersOutOfOrderAreRefusedBecauseTheFormatterStillReadsThem() {
        for format in ["%l*@", "%h*@", "%.-*@", "%l5@", "%5-d", "%.2.2f", "%1$2$@", "%lh@", "%$@"] {
            #expect(FormatSpecifiers.arguments(of: format) == nil, "\(format)")
            #expect(!FormatSpecifiers.compatible(english: "%@ items", translation: "%@ " + format), "\(format)")
        }
    }

    @Test func aPercentFollowedByModifiersWithNoConversionIsRefused() {
        // "% %" is one literal to the formatter, so the "%@" after it would read an argument the text seems not to have.
        for format in ["% %%@", "%5%%@", "%5)", "ends in %5"] {
            #expect(FormatSpecifiers.arguments(of: format) == nil, "\(format)")
        }
    }

    @Test func formsTheFormatterTreatsSpeciallyAreRefused() {
        for format in ["%P", "%[x]@", "%[:e %@", "%2147483648d", "%.99999f"] {
            #expect(FormatSpecifiers.arguments(of: format) == nil, "\(format)")
        }
    }

    @Test func modifiersInTheUsualOrderStillCount() {
        #expect(FormatSpecifiers.arguments(of: "%1$-5.2f and %2$hhd") == [.double, .int32])
        #expect(FormatSpecifiers.arguments(of: "%05lld %+.1f %#x") == [.int64, .double, .uint32])
    }

    @Test func anApostropheIsNotAModifierSoItsPercentIsLiteral() {
        #expect(FormatSpecifiers.arguments(of: "%'d") == [])
    }
}

@Suite("Translated string tables (FE-204)")
struct StringTableCheckTests {
    @Test func aPartialTranslationPassesAndCountsWhatIsMissing() throws {
        let fx = try StringFixture()
        try fx.write("\"Open\" = \"Ouvrir\";\n\"%@ items\" = \"%@ éléments\";\n", language: "fr")
        let report = try fx.report("fr")
        #expect(report.errors.isEmpty)
        #expect(report.missing == 2)
    }

    @Test func aNumberedTranslationPasses() throws {
        let fx = try StringFixture()
        try fx.write("\"%@ of %d\" = \"%2$d von %1$@\";\n", language: "de")
        #expect(try fx.report("de").errors.isEmpty)
    }

    @Test func anUnknownKeyFails() throws {
        let fx = try StringFixture()
        try fx.write("\"Opne\" = \"Ouvrir\";\n", language: "fr")
        #expect(try fx.report("fr").errors == ["unknown key \"Opne\""])
    }

    @Test func anEmptyValueFails() throws {
        let fx = try StringFixture()
        try fx.write("\"Cut\" = \"\";\n", language: "fr")
        #expect(try fx.report("fr").errors == ["empty value for \"Cut\""])
    }

    @Test func wrongSpecifiersFail() throws {
        let fx = try StringFixture()
        try fx.write("\"%@ items\" = \"%d éléments\";\n\"Open\" = \"100 % ouvert\";\n", language: "fr")
        let errors = try fx.report("fr").errors
        #expect(errors.count == 2)
        #expect(errors.allSatisfy { $0.hasPrefix("format specifiers differ") })
    }

    @Test func malformedFilesFail() throws {
        for broken in ["\"Open\" = \"Ouvrir\"\n\"Cut\" = \"Couper\";\n", "\"Open\" = \"unterminated;\n", "Open = ;"] {
            let fx = try StringFixture()
            try fx.write(broken, language: "fr")
            #expect(try fx.report("fr").errors == ["fr.lproj/Localizable.strings: not a well-formed .strings file"], "\(broken)")
        }
    }

    @Test func aNestedValueFails() throws {
        let fx = try StringFixture()
        try fx.write("\"Open\" = { \"a\" = \"b\"; };\n", language: "fr")
        #expect(try fx.report("fr").errors.first?.contains("every entry must be") == true)
    }

    @Test func invalidUTF8Fails() throws {
        let fx = try StringFixture()
        try fx.write(Data([0x22, 0x4F, 0x22, 0x20, 0x3D, 0x20, 0x22, 0xFF, 0xC0, 0x22, 0x3B]), language: "fr")
        #expect(try fx.report("fr").errors.first?.contains("not UTF-8") == true)
    }

    @Test func utf16WithAByteOrderMarkPasses() throws {
        let fx = try StringFixture()
        let data = try #require("\u{FEFF}\"Open\" = \"Ouvrir\";\n".data(using: .utf16LittleEndian))
        try fx.write(data, language: "fr")
        #expect(try fx.report("fr").errors.isEmpty)
    }

    @Test func aFolderWithoutATableFails() throws {
        let fx = try StringFixture()
        try FileManager.default.createDirectory(at: fx.root.appendingPathComponent("fr.lproj"), withIntermediateDirectories: true)
        #expect(try fx.report("fr").errors == ["fr.lproj/Localizable.strings: can't be read"])
    }

    @Test func aBadFolderNameFails() throws {
        let fx = try StringFixture()
        try fx.write("\"Open\" = \"Ouvrir\";\n", language: "not a language")
        #expect(try fx.report("not a language").errors.first?.contains("not a language identifier") == true)
    }

    @Test func regionAndScriptIdentifiersAreAccepted() {
        for name in ["fr", "pt-BR", "zh_Hant", "zh-Hant-TW", "ar-XB", "fil"] {
            #expect(StringTableCheck.isLanguageIdentifier(name), "\(name)")
        }
    }

    @Test func englishIsNotCheckedAgainstItself() throws {
        let fx = try StringFixture()
        #expect(try StringTableCheck.check(resources: fx.root).isEmpty)
    }
}

@Suite("String lookup (FE-204)")
struct StringLookupTests {
    @Test func aMissingKeyFallsBackToEnglish() throws {
        let fx = try StringFixture()
        try fx.write("\"Open\" = \"Ouvrir\";\n", language: "fr")
        let bundle = try fx.bundle(language: "fr")
        #expect(L10n.tr("Open", in: bundle) == "Ouvrir")
        #expect(L10n.tr("Cut", in: bundle) == "Cut")
    }

    @Test func aTranslationThatWouldCrashFallsBackToEnglish() throws {
        let fx = try StringFixture()
        try fx.write("\"%@ items\" = \"%@ %d %s\";\n", language: "fr")
        #expect(L10n.template("%@ items", in: try fx.bundle(language: "fr")) == "%@ items")
    }

    @Test func aReorderedTranslationFillsByPosition() throws {
        let fx = try StringFixture()
        try fx.write("\"%@ of %d\" = \"%2$d von %1$@\";\n", language: "de")
        let template = L10n.template("%@ of %d", in: try fx.bundle(language: "de"))
        #expect(String(format: template, "Akten", 3) == "3 von Akten")
    }

    @Test func englishFormatsAreUnchanged() {
        #expect(L10n.tr("Navigation pane") == "Navigation pane")
        #expect(L10n.format("%@ items selected", "12") == "12 items selected")
    }
}

@Suite("Pseudo-languages (FE-204)")
struct PseudoLocalizationTests {
    @Test func accentsLettersAndMarksBothEnds() {
        let text = PseudoLocalization.transform("Open the folder", style: .accented)
        #expect(text.hasPrefix("[Öþéñ ţĥé"))
        #expect(text.hasSuffix("·]"))
    }

    @Test func growsByAboutFortyPercent() {
        for style in PseudoLocalization.Style.allCases {
            let english = "Do this for all current items in the destination folder"
            let ratio = Double(PseudoLocalization.transform(english, style: style).count) / Double(english.count)
            #expect((1.3...1.5).contains(ratio), "\(ratio)")
        }
    }

    @Test func paddingIsNonLatin() {
        let text = PseudoLocalization.transform("Do this for all current items", style: .accented)
        #expect(text.contains("ก") && text.contains("中"))
        #expect(PseudoLocalization.transform("Do this for all current items", style: .rightToLeft).contains("م"))
    }

    @Test func rightToLeftHasNoLatinLettersLeft() {
        let text = PseudoLocalization.transform("Move Items Here", style: .rightToLeft)
        #expect(text.range(of: "[A-Za-z]", options: .regularExpression) == nil)
        #expect(BidiText.hasRightToLeftLetters(text))
    }

    @Test func keepsSpecifiersAndShortcutGlyphs() {
        for style in PseudoLocalization.Style.allCases {
            let english = "%@ items selected (%1$@, %lld, %.1f, 50%%) ⌘⇧"
            let text = PseudoLocalization.transform(english, style: style)
            for piece in ["%@", "%1$@", "%lld", "%.1f", "%%", "⌘⇧"] { #expect(text.contains(piece), "\(piece)") }
        }
    }

    @Test func everySpecifierStaysUsable() {
        for style in PseudoLocalization.Style.allCases {
            let text = PseudoLocalization.transform("%@ of %d", style: style)
            #expect(FormatSpecifiers.compatible(english: "%@ of %d", translation: text))
            #expect(String(format: text, "x", 9).contains("9"))
        }
    }

    @Test func aPlainPercentStaysLiteral() {
        let text = PseudoLocalization.transform("Default (100%)", style: .accented)
        #expect(text.contains("100%)"))
    }

    @Test func theGeneratedTableIsAValidTranslation() throws {
        let english = ["Open": "Open", "Say \"hi\"\nthere\\now": "Say \"hi\"\nthere\\now", "%@ items": "%@ items"]
        for style in PseudoLocalization.Style.allCases {
            let table = try StringTableCheck.parse(Data(PseudoLocalization.table(from: english, style: style).utf8), name: "pseudo")
            #expect(Set(table.keys) == Set(english.keys))
            #expect(StringTableCheck.check(language: style.rawValue, table: table, base: english).errors.isEmpty)
        }
    }
}

@Suite("Direction isolation (FE-204)")
struct BidiTextTests {
    private let firstStrong = "\u{2068}", leftToRight = "\u{2066}", pop = "\u{2069}"

    @Test func latinTextInALeftToRightInterfaceIsLeftAlone() {
        #expect(BidiText.isolated("report (1).txt", rightToLeftInterface: false) == "report (1).txt")
        #expect(BidiText.path("/Users/me/a.txt", rightToLeftInterface: false) == "/Users/me/a.txt")
    }

    @Test func aRightToLeftInterfaceIsolatesEveryName() {
        #expect(BidiText.isolated("report (1).txt", rightToLeftInterface: true) == firstStrong + "report (1).txt" + pop)
    }

    @Test func aRightToLeftNameIsIsolatedInAnyInterface() {
        #expect(BidiText.isolated("שלום.txt", rightToLeftInterface: false) == firstStrong + "שלום.txt" + pop)
    }

    @Test func aPathReadsRootFirst() {
        #expect(BidiText.path("/Users/me", rightToLeftInterface: true) == leftToRight + "/Users/me" + pop)
    }

    @Test func eachRightToLeftComponentIsItsOwnIsolate() {
        #expect(BidiText.path("/a/שלום/עולם", rightToLeftInterface: false)
                == leftToRight + "/a/" + firstStrong + "שלום" + pop + "/" + firstStrong + "עולם" + pop + pop)
    }

    @Test func emptyTextStaysEmpty() {
        #expect(BidiText.isolated("", rightToLeftInterface: true).isEmpty)
        #expect(BidiText.path("", rightToLeftInterface: true).isEmpty)
    }

    @Test func anOverrideInANameCannotReverseALeftToRightSentence() {
        #expect(BidiText.isolated("a\u{202E}b.txt", rightToLeftInterface: false) == "ab.txt")
        #expect(L10n.format("%@ items", "a\u{202E}b") == "ab items")
    }

    @Test func aNameCannotCloseItsOwnIsolate() {
        #expect(BidiText.isolated("x\u{2069}\u{202E}y", rightToLeftInterface: true) == firstStrong + "xy" + pop)
    }

    @Test func anUnclosedIsolateInANameIsDropped() {
        #expect(BidiText.isolated("a\u{2066}b", rightToLeftInterface: true) == firstStrong + "ab" + pop)
        #expect(BidiText.isolated("\u{2069}a\u{2068}", rightToLeftInterface: false) == "a")
    }

    @Test func aPathComponentCannotEscapeEither() {
        #expect(BidiText.path("/a/x\u{2069}\u{202E}y/b", rightToLeftInterface: true) == leftToRight + "/a/xy/b" + pop)
        #expect(BidiText.path("/a/x\u{202E}y", rightToLeftInterface: false) == "/a/xy")
    }

    @Test func textAlreadyIsolatedKeepsItsMarksWhenNested() {
        let inner = BidiText.isolated("שלום", rightToLeftInterface: false)
        #expect(BidiText.isolated(inner, rightToLeftInterface: false) == firstStrong + inner + pop)
        let path = BidiText.path("/a/שלום", rightToLeftInterface: true)
        #expect(BidiText.isolated(path, rightToLeftInterface: true) == firstStrong + path + pop)
    }

    @Test func copiedTextHasNoIsolateMarks() {
        #expect(BidiText.withoutIsolates(BidiText.path("/a/שלום/b", rightToLeftInterface: true)) == "/a/שלום/b")
    }
}

@Suite("Sentences drawn as views (FE-204)")
struct SentencePartsTests {
    @Test func splitsInTheOrderTheTemplateGives() {
        #expect(SentenceParts.split("Copying %@ from %@ to %@") == [.text("Copying "), .argument(0), .text(" from "), .argument(1), .text(" to "), .argument(2)])
    }

    @Test func numberedArgumentsKeepTheirPosition() {
        #expect(SentenceParts.split("%3$@ von %1$@") == [.argument(2), .text(" von "), .argument(0)])
    }

    @Test func aDoubledPercentIsText() {
        #expect(SentenceParts.split("50%% of %@") == [.text("50% of "), .argument(0)])
    }

    @Test func anythingElseStaysText() {
        #expect(SentenceParts.split("100% done") == [.text("100% done")])
        #expect(SentenceParts.split("%0$@") == [.text("%0$@")])
    }
}

@Suite("Dialog tab rows (FE-204)")
struct TabRowFitTests {
    @Test func aRowThatFitsIsUnchanged() {
        #expect(TabRowFit.widths([50, 60], padding: 16, available: 200) == [50, 60])
    }

    @Test func aRowWithNoWidthYetIsUnchanged() {
        #expect(TabRowFit.widths([50, 60], padding: 16, available: 0) == [50, 60])
    }

    @Test func aSlightlyLongRowGivesUpPadding() {
        let widths = TabRowFit.widths([100, 100], padding: 16, available: 190)
        #expect(widths == [95, 95])
    }

    @Test func aVeryLongRowStillEndsInsideTheWindow() {
        let widths = TabRowFit.widths([200, 300, 100], padding: 16, available: 200)
        #expect(abs(widths.reduce(0, +) - 200) < 0.01)
        #expect(widths.allSatisfy { $0 > 0 })
    }
}

@Suite("Locale-aware numbers (FE-204)")
struct LocaleFormatTests {
    @Test func clockUsesTheLocaleDigits() {
        #expect(PropertyFormat.clock(3725, locale: Locale(identifier: "en_US")) == "01:02:05")
        #expect(PropertyFormat.clock(3725, locale: Locale(identifier: "ar_SA")).contains("٠١"))
    }

    @Test func sizeNumbersUseTheLocaleSeparator() {
        #expect(SizeUnit.number(4.88, decimals: 2, locale: Locale(identifier: "en_US")) == "4.88")
        #expect(SizeUnit.number(4.88, decimals: 2, locale: Locale(identifier: "de_DE")) == "4,88")
    }

    @Test func sizeNumbersDoNotDriftOnBinaryFractions() {
        #expect(SizeUnit.number(15.9, decimals: 1, locale: Locale(identifier: "en_US")) == "15.9")
    }

    @Test func compactNumbersKeepOnlySignificantDigits() {
        #expect(PropertyFormat.compact(44.1).hasPrefix("44"))
        #expect(!PropertyFormat.compact(1.5000001).contains("000"))
    }

    @Test func englishWordingIsUnchanged() {
        #expect(PropertyFormat.filesAndFolders(files: 1, folders: 2) == "1 File, 2 Folders")
        #expect(CapacityText.size(512) == "512 bytes")
        #expect(CapacityText.size(1) == "1 byte")
    }
}
