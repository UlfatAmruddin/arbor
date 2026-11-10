import Foundation
import Testing
@testable import ArborCore

/// The repository's own sources and English tables (FE-204): new user-visible text must go through `L10n`.
@Suite("String coverage (FE-204)")
struct StringCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let english = root.appendingPathComponent("Resources/en.lproj", isDirectory: true)

    @Test func noLiteralReachesAShownSinkWithoutL10n() throws {
        let sources = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var findings: [UserVisibleLiteralScan.Finding] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(Self.root.path.count + 1))
            guard !UserVisibleLiteralScan.isExcluded(path) else { continue }
            findings += UserVisibleLiteralScan.scan(try String(contentsOf: url, encoding: .utf8), file: path)
            scanned += 1
        }
        #expect(scanned > 300)
        #expect(findings.isEmpty, "route these through L10n.tr, L10n.format or L10n.plural:\n\(findings.map(\.description).joined(separator: "\n"))")
    }

    @Test func everyEnglishPluralIsValidAndHasItsTwoForms() throws {
        let plurals = try PluralTable.parse(Self.english.appendingPathComponent(PluralTable.tableName))
        #expect(!plurals.isEmpty)
        for (key, forms) in plurals {
            #expect(PluralTable.problems(key: key, forms: forms).isEmpty, "\(key)")
            #expect(Set(forms.keys) == ["one", "other"] && forms["other"] == key, "\(key)")
        }
    }

    /// "1 item" next to "%@ items" is a plural written by hand; it belongs in the plural table.
    @Test func noCountedSentenceIsAPairOfStrings() throws {
        let strings = try StringTableCheck.parse(Self.english.appendingPathComponent(StringTableCheck.tableName))
        let plurals = try PluralTable.parse(Self.english.appendingPathComponent(PluralTable.tableName))
        let keys = Set(strings.keys)
        var pairs: [String] = []
        for key in keys {
            for specifier in ["%@", "%d", "%ld", "%lld"] {
                let many = key.replacingOccurrences(of: #"(?<![\w.,%$/])1(?![\w.,/])"#, with: specifier, options: .regularExpression)
                if many != key, keys.contains(many) { pairs.append("\(key) / \(many)") }
            }
        }
        #expect(pairs.isEmpty, "\(pairs)")
        #expect(keys.isDisjoint(with: plurals.keys))
    }
}

@Suite("User-visible literal scan (FE-204)")
struct UserVisibleLiteralScanTests {
    private func found(_ source: String) -> [String] { UserVisibleLiteralScan.scan(source, file: "x.swift").map(\.text) }

    @Test func aLiteralAtEachKindOfSinkIsFound() {
        #expect(found(#"label.stringValue = "Ready""#) == ["Ready"])
        #expect(found(#"alert.messageText = flag ? "One thing" : "Another""#) == ["One thing", "Another"])
        #expect(found("label.toolTip = a\n    ? \"Long\"\n    : nil") == ["Long"])
        #expect(found(#"NSAlert.show("It failed.", in: window)"#) == ["It failed."])
        #expect(found(#"let l = SheetLabel.make("Owner")"#) == ["Owner"])
        #expect(found(#"throw SearchSyntaxError("Type “\(name)” again.")"#) == ["Type “ ” again."])
        #expect(found("statusBar.setMessage(\n    n == 1 ? \"Done\" : \"All done\")") == ["Done", "All done"])
        #expect(found(#"ChromeButton(symbol: "x", tooltip: "Close \(name)")"#) == ["Close  "])
        #expect(found(#"throw SearchSyntaxError(L10n.tr("“kind:\(value)” isn't known."))"#) == ["“kind: ” isn't known."])
        #expect(found(#"let s = L10n.format("Moved \(n) items to %@", name)"#) == ["Moved   items to %@"])
    }

    @Test func routedTextIdentifiersAndComparisonsAreLeftAlone() {
        #expect(found(#"label.stringValue = L10n.format("Copied “%@”.", name)"#).isEmpty)
        #expect(found(#"label.stringValue = L10n.format("Copied “%@”.", "\(a)/\(b)")"#).isEmpty)
        #expect(found(#"NSAlert.show(L10n.plural(one: "%lld item", other: "%lld items", n), "", in: nil)"#).isEmpty)
        #expect(found(#"table.setAccessibilityLabel(id == "recent" ? L10n.tr("Recent") : L10n.tr("Favorites"))"#).isEmpty)
        #expect(found(#"label.stringValue = name.replacingOccurrences(of: ".app", with: "")"#).isEmpty)
        #expect(found(#"make(table, id: "search.folder")"#).isEmpty)
        #expect(found(#"if item.title == "Window" { }"#).isEmpty)
        #expect(found(#"label.stringValue = "\(a) — \(b)""#).isEmpty)
        #expect(found("// label.stringValue = \"Old\"\nlabel.stringValue = text").isEmpty)
        #expect(found(#"ChromeButton(symbol: "x", tooltip: "Close")"#).isEmpty)   // collected by extract-strings.sh
    }

    @Test func rawAndMultiLineStringsAreRead() {
        #expect(found("label.stringValue = #\"Say \"hi\"\"#") == [#"Say "hi""#])
        #expect(found("label.stringValue = \"\"\"\n    Two lines\n    \"\"\"") == ["\n    Two lines\n    "])
    }

    @Test func debugOutputAndScriptedChecksAreNotScanned() {
        #expect(UserVisibleLiteralScan.isExcluded("Sources/Arbor/Features/Trash/TrashDebug.swift"))
        #expect(UserVisibleLiteralScan.isExcluded("Sources/Arbor/Features/Performance/IdleProfiler.swift"))
        #expect(!UserVisibleLiteralScan.isExcluded("Sources/Arbor/Features/Trash/TrashActions.swift"))
    }
}
