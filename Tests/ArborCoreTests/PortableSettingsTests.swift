import Foundation
import Testing
@testable import ArborCore

/// Export and import of preferences (FE-208): the allowlist, the file format and what an import would change.
@Suite("Portable settings (FE-208)")
struct PortableSettingsTests {
    private let current: (PortableSetting) -> PortableValue? = { _ in nil }

    private func file(_ settings: String, format: String = #""arbor.settings""#, version: String = "1") -> Data {
        Data(#"{"format":\#(format),"version":\#(version),"settings":\#(settings)}"#.utf8)
    }

    private func plan(_ settings: String, unavailable: Set<String> = []) throws -> PortableImportPlan {
        PortableImportPlan.make(file: try PortableSettingsFile.decode(file(settings)), current: current, unavailable: unavailable)
    }

    private func refusal(_ data: Data) -> PortableSettingsError? {
        do {
            _ = try PortableSettingsFile.decode(data)
            return nil
        } catch {
            return error as? PortableSettingsError
        }
    }

    // MARK: The allowlist

    @Test func everyFolderOptionIsClassifiedExactlyOnce() {
        let portable = Set(PortableSettingsCatalog.portableFolderOptions)
        let local = PortableSettingsCatalog.localOnlyFolderOptions
        let options = FolderOptionsCatalog.all.filter { $0.isAvailable && $0.defaultValue != nil }.map(\.key)
        for key in options { #expect(portable.contains(key) != local.contains(key), "\(key)") }
        #expect(portable.union(local) == Set(options))
        #expect(PortableSettingsCatalog.portableFolderOptions.allSatisfy { PortableSettingsCatalog.setting($0) != nil })
    }

    @Test func theCatalogIsClosedAndWellFormed() {
        let keys = PortableSettingsCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        for setting in PortableSettingsCatalog.all {
            #expect(setting.allows(setting.defaultValue), "\(setting.key)")
            #expect(!setting.key.hasPrefix(Automation.prefix) && !setting.key.hasPrefix("Apple") && !setting.key.hasPrefix("NS"), "\(setting.key)")
            #expect(setting.choices.count >= 2, "\(setting.key)")
            for choice in setting.choices {
                guard case .string(let text) = choice.value else { continue }
                #expect(text.count < 32 && !text.contains { "/~\\".contains($0) }, "\(setting.key): \(text)")
            }
        }
    }

    @Test func sensitiveSettingsAreNeverPortable() {
        let sensitive = ["hideExtensions", "hideProtectedSystemFiles", "hideFolderMergeConflicts", "clickItems", "showRecentFiles", "showFrequentFolders",
                         "restorePreviousWindows", "showPreviewHandlers", "searchFileContents", "displayDeleteConfirmation", "fileOpsVerifyByDefault",
                         "quickAccessPaths", "network.mappedDrives", "searchHistory", "libraries.v1", "gallery.collection.v1", "details.columnSets",
                         "sidePane", "ARBOR_HEADLESS", "ARBOR_SCRIPT", "AppleLanguages"]
        for key in sensitive { #expect(PortableSettingsCatalog.setting(key) == nil, "\(key)") }
    }

    @Test func settingsAnImportCouldNotVisiblyChangeAreNotOffered() {
        let inert = ["viewMode", "sortKey", "sortAscending", "foldersFirst", "underlineTitles", "searchWithoutIndex", "searchIncludeSystemDirectories"]
        for key in inert { #expect(PortableSettingsCatalog.setting(key) == nil, "\(key)") }
    }

    @Test func everyTransferLimitTheMenuOffersCanTravelInAFile() throws {
        let setting = try #require(PortableSettingsCatalog.setting("fileOpsConcurrencyLimit"))
        #expect(setting.choices.map(\.value) == TransferScheduler.concurrencyLimitChoices.map(PortableValue.integer))
        #expect(setting.choices.map(\.title) == TransferScheduler.concurrencyLimitChoices.map(TransferScheduler.concurrencyLimitTitle))
    }

    // MARK: Export

    @Test func exportRoundTripsAndHoldsExactlyTheCatalog() throws {
        let compact = try #require(PortableSettingsCatalog.setting("compactView"))
        let data = try PortableSettingsFile.encoded { $0 == compact ? .bool(true) : nil }
        let decoded = try PortableSettingsFile.decode(data)
        #expect(Set(decoded.entries.keys) == Set(PortableSettingsCatalog.all.map(\.key)))
        #expect(decoded.entries["compactView"] == .value(.bool(true)))

        let same = PortableImportPlan.make(file: decoded, current: { $0 == compact ? .bool(true) : nil })
        #expect(same.changes.isEmpty && same.alreadyMatches && same.ignoredCount == 0)
    }

    @Test func exportReplacesCorruptedLocalValuesWithTheDefault() throws {
        let data = try PortableSettingsFile.encoded { $0.key == "hiddenFiles" ? .string("/Users/me/secret") : nil }
        #expect(!String(decoding: data, as: UTF8.self).contains("/Users/me"))
        #expect(try PortableSettingsFile.decode(data).entries["hiddenFiles"] == .value(.string("hide")))
    }

    @Test func exportHasNoIdentifyingFields() throws {
        let text = String(decoding: try PortableSettingsFile.encoded(reading: current), as: UTF8.self)
        let top = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(top.keys) == ["format", "version", "settings"])
    }

    // MARK: Refused files

    @Test func filesThatAreNotSettingsAreRefused() {
        let refused: [Data] = [
            Data("not json".utf8), Data(), Data("[]".utf8), Data("{}".utf8),
            Data(#"{"format":"arbor.settings","version":1}"#.utf8),
            Data(#"{"version":1,"settings":{}}"#.utf8),
            Data(#"{"format":"arbor.settings","settings":{}}"#.utf8),
            file("{}", format: #""arbor.search""#), file("{}", format: "7"),
            file("{}", version: "0"), file("{}", version: "-1"), file("{}", version: "\(PortableSettingsFile.version - 1)"), file("{}", version: "1.5"), file("{}", version: "true"), file(#"["x"]"#),
            Data((String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)).utf8),
            file(String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)),
        ]
        for data in refused { #expect(refusal(data) == .notSettingsFile) }
    }

    @Test func aNewerVersionIsNamedEvenWhenItsShapeChanged() {
        let newer = "\(PortableSettingsFile.version + 1)"
        #expect(refusal(file("{}", version: newer)) == .newerVersion)
        #expect(refusal(file(#"["x"]"#, version: newer)) == .newerVersion)
        #expect(refusal(Data(#"{"format":"arbor.settings","version":\#(newer)}"#.utf8)) == .newerVersion)
    }

    // MARK: Validation

    @Test(arguments: [#""compactView":1"#, #""hiddenFiles":true"#, #""textSize":116"#, #""textSize":1.5"#, #""textSize":1e400"#,
                      #""compactView":null"#, #""compactView":[true]"#, #""compactView":{"a":true}"#, #""hiddenFiles":"/Users/me""#,
                      #""fileOpsConcurrencyLimit":99999999999999999999"#])
    func aBadValueIsListedByTitleAndTheRestStillApplies(entry: String) throws {
        let result = try plan("{\(entry),\"navigationPaneVisible\":false}")
        #expect(result.changes.map(\.setting.key) == ["navigationPaneVisible"])
        #expect(result.invalidTitles.count == 1)
        #expect(!result.alreadyMatches)
    }

    @Test func aBadValueIsNeverRepeatedInTheNote() throws {
        let result = try plan(#"{"hiddenFiles":"/Users/me","ARBOR_SCRIPT":"quit"}"#)
        #expect(!result.note.contains("/Users/me") && !result.note.contains("ARBOR"))
        #expect(result.note.contains(try #require(PortableSettingsCatalog.setting("hiddenFiles")).title))
    }

    @Test func keysOffTheAllowlistAreOnlyCounted() throws {
        let result = try plan(#"{"ARBOR_SCRIPT":"quit","AppleLanguages":["fr"],"quickAccessPaths":["/Users/me"],"#
                              + #""hideProtectedSystemFiles":false,"hideExtensions":true,"clickItems":"single","unknown\u0000key":1,"compactView":true}"#)
        #expect(result.ignoredCount == 7)
        #expect(result.changes.map(\.setting.key) == ["compactView"])
        #expect(result.invalidTitles.isEmpty)
    }

    // MARK: The plan

    @Test func onlyDifferingValuesAreChangedInCatalogOrder() throws {
        let result = PortableImportPlan.make(
            file: try PortableSettingsFile.decode(file(#"{"textSize":130,"compactView":true,"browseFolders":"own","openTo":"home"}"#)),
            current: { $0.key == "textSize" ? .integer(115) : nil })
        #expect(result.changes.map(\.setting.key) == ["browseFolders", "compactView", "textSize"])
        let size = try #require(result.changes.last)
        #expect(size.currentTitle == TextSizeLevel.larger.title && size.newTitle == TextSizeLevel.large.title && size.new == .integer(130))
    }

    @Test func aCorruptedCurrentValueIsPreviewedAsItsDefault() throws {
        let result = PortableImportPlan.make(file: try PortableSettingsFile.decode(file(#"{"hiddenFiles":"show"}"#)),
                                             current: { _ in .string("/Users/me") })
        let change = try #require(result.changes.first)
        #expect(change.currentTitle == change.setting.title(of: change.setting.defaultValue))
    }

    @Test func unavailableSettingsAreReportedAndNotChanged() throws {
        let result = try plan(#"{"showLibraries":true,"compactView":true}"#, unavailable: ["showLibraries"])
        #expect(result.changes.map(\.setting.key) == ["compactView"])
        #expect(result.unavailableTitles.count == 1)
    }

    @Test func onlyAFullyValidAndEqualFileClaimsToMatch() throws {
        #expect(try plan(#"{"compactView":false}"#).alreadyMatches)
        #expect(try !plan("{}").alreadyMatches)
        #expect(try !plan(#"{"compactView":1}"#).alreadyMatches)
        #expect(try !plan(#"{"compactView":false,"other":1}"#).alreadyMatches)
        #expect(try !plan(#"{"compactView":false,"showLibraries":true}"#, unavailable: ["showLibraries"]).alreadyMatches)
        #expect(try plan("{}").changes.isEmpty)
    }

    @Test func theNoteStaysShortForAFileFullOfBadValues() throws {
        let body = PortableSettingsCatalog.all.map { "\"\($0.key)\":null" }.joined(separator: ",")
        let result = try plan("{\(body)}")
        #expect(result.invalidTitles.count == PortableSettingsCatalog.all.count)
        #expect(result.note.contains("\(PortableSettingsCatalog.all.count - PortableImportPlan.noteTitleLimit) more"))
    }

    // MARK: Reading

    @Test func aFileAtTheLimitIsReadAndOneByteMoreIsRefused() throws {
        let fx = try Fixture()
        let padding = String(repeating: " ", count: PortableSettingsFile.maxBytes - file("{}").count)
        let atLimit = fx.url("limit.json")
        try (file("{}") + Data(padding.utf8)).write(to: atLimit)
        #expect(try PortableSettingsFile.read(from: atLimit).entries.isEmpty)

        let over = fx.url("over.json")
        try (file("{}") + Data(padding.utf8) + Data(" ".utf8)).write(to: over)
        #expect(throws: PortableSettingsError.tooLarge) { try PortableSettingsFile.read(from: over) }
    }

    @Test func aHugeSparseFileIsRefusedFromItsSize() throws {
        let fx = try Fixture()
        let url = try fx.file("huge.json", "")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        #expect(throws: PortableSettingsError.tooLarge) { try PortableSettingsFile.read(from: url) }
    }

    @Test func onlyRegularFilesAreRead() throws {
        let fx = try Fixture()
        let real = fx.url("real.json")
        try file("{}").write(to: real)
        try FileManager.default.createSymbolicLink(at: fx.url("link.json"), withDestinationURL: real)
        #expect(mkfifo(fx.url("pipe.json").path, 0o600) == 0)
        try fx.folder("folder.json")
        for name in ["link.json", "pipe.json", "folder.json", "missing.json"] {
            #expect(throws: PortableSettingsError.unreadable) { try PortableSettingsFile.read(from: fx.url(name)) }
        }
        #expect(throws: PortableSettingsError.unreadable) { try PortableSettingsFile.read(from: URL(fileURLWithPath: "/dev/null")) }
        #expect(try PortableSettingsFile.read(from: real).entries.isEmpty)
    }
}
