import Foundation
import Testing
@testable import ArborCore

@Suite("Search per location (consistency)")
struct ScopedSearchTests {
    let home = URL(fileURLWithPath: "/Users/me")

    @Test func extraScopesAndOriginSurviveTheKey() {
        let request = SearchRequest(query: "report", scope: URL(fileURLWithPath: "/Users/me/Documents"),
                                    extraScopes: [URL(fileURLWithPath: "/Volumes/Work/Docs"), URL(fileURLWithPath: "/Shared/a b&c.txt")],
                                    originKey: Location.library("Documents").key)
        let location = Location.search(request)
        let back = Location(key: location.key)
        #expect(back == location)
        guard case .search(let parsed)? = back else { Issue.record("not a search"); return }
        #expect(parsed.extraScopes.map(\.path) == ["/Volumes/Work/Docs", "/Shared/a b&c.txt"])
        #expect(parsed.originKey == "library?name=Documents")
        #expect(parsed.origin == .library("Documents"))
    }

    @Test func originTitlesTheResultsAndIsWhereUpGoes() {
        let request = ScopedSearch.home(userFolder: home, pinnedFolders: [], files: [])
        var withQuery = request
        withQuery.query = "x"
        #expect(Location.search(withQuery).displayName == "Search Results in Home")
        #expect(Location.search(withQuery).parent() == .home)
        // A plain folder search is unchanged.
        let plain = SearchRequest(query: "x", scope: home)
        #expect(Location.search(plain).parent() == .folder(home))
        #expect(Location.search(plain).key.contains("also") == false)
    }

    @Test func homeCoversPinnedFoldersAndFilesOutsideTheUserFolder() {
        let request = ScopedSearch.home(
            userFolder: home,
            pinnedFolders: [URL(fileURLWithPath: "/Users/me/Documents"), URL(fileURLWithPath: "/Volumes/Data/Projects"),
                            URL(fileURLWithPath: "/Applications")],
            files: [URL(fileURLWithPath: "/Users/me/Desktop/a.txt"), URL(fileURLWithPath: "/Volumes/Data/Projects/plan.md"),
                    URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(request.scope?.path == "/Users/me")
        #expect(request.extraScopes.map(\.path) == ["/Volumes/Data/Projects", "/Applications", "/tmp/notes.txt"])
        #expect(request.originKey == "home")
    }

    @Test func extrasDropNestedPlacesAndAreBounded() {
        let urls = [URL(fileURLWithPath: "/a/b/c.txt"), URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/z")]
        #expect(ScopedSearch.extras(urls, excluding: nil).map(\.path) == ["/a", "/z"])
        let many = (0..<200).map { URL(fileURLWithPath: "/f\($0)") }
        #expect(ScopedSearch.extras(many, excluding: nil).count == ScopedSearch.extraLimit)
    }

    @Test func libraryCoversEveryFolder() throws {
        let request = try #require(ScopedSearch.library("Music", folders: [URL(fileURLWithPath: "/Users/me/Music"),
                                                                           URL(fileURLWithPath: "/Volumes/NAS/Music"),
                                                                           URL(fileURLWithPath: "/Users/me/Music/Live")]))
        #expect(request.scope?.path == "/Users/me/Music")
        #expect(request.extraScopes.map(\.path) == ["/Volumes/NAS/Music"])
        #expect(request.origin == .library("Music"))
        #expect(ScopedSearch.library("Empty", folders: []) == nil)
    }

    @Test func thisMacScansOtherLocalDrives() {
        let request = ScopedSearch.allDrives(localVolumes: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes/USB")])
        #expect(request.scope == nil)
        #expect(request.extraScopes.map(\.path) == ["/Volumes/USB"])
        #expect(Location.search(request).parent() == .thisMac)
    }
}

@Suite("Relevance ordering for search results (FE-145)")
struct SearchRelevanceTests {
    @Test func exactThenPrefixThenSubstringThenContents() {
        let words = SearchRelevance.nameWords("report")
        #expect(words == ["report"])
        func tier(_ name: String, _ reasons: Set<SearchReason>? = [.name]) -> SearchRelevance.Tier {
            SearchRelevance.tier(name: name, words: words, reasons: reasons)
        }
        #expect(tier("Report.pdf") == .exactName)
        #expect(tier("report") == .exactName)
        #expect(tier("Reports 2026.xlsx") == .namePrefix)
        #expect(tier("Annual report.docx") == .nameContains)
        #expect(tier("notes.txt", [.contents]) == .contents)
        #expect(tier("photo.jpg", [.property(.kind)]) == .other)
        // A content match whose name also contains the word ranks by the name.
        #expect(tier("report-draft.txt", [.name, .contents]) == .namePrefix)
    }

    @Test func scoresSortMostRelevantFirst() {
        let words = ["report"]
        let names: [(String, Set<SearchReason>)] = [
            ("notes.txt", [.contents]), ("Annual report.docx", [.name]), ("report.pdf", [.name]), ("Reports.xlsx", [.name]),
        ]
        let sorted = names.sorted { SearchRelevance.score(name: $0.0, words: words, reasons: $0.1) < SearchRelevance.score(name: $1.0, words: words, reasons: $1.1) }
        #expect(sorted.map(\.0) == ["report.pdf", "Reports.xlsx", "Annual report.docx", "notes.txt"])
    }

    @Test func queryWordsIgnoreNegationsAndWildcards() {
        #expect(SearchRelevance.nameWords("name:budget NOT draft") == ["budget"])
        #expect(SearchRelevance.nameWords("rep*") == ["rep"])
        #expect(SearchRelevance.nameWords("kind:picture").isEmpty)
    }

    @Test func defaultOrderIsRelevance() {
        let order = SearchRelevance.defaultOrder
        #expect(SearchRelevance.isRelevance(order))
        #expect(order.primaryColumn == SearchRelevance.column)
        #expect(!SearchRelevance.isRelevance(FileSortOrder()))
    }
}

@Suite("Drive file system capabilities (FE-188)")
struct VolumeCapabilityTests {
    @Test func readsTheStartupVolume() throws {
        let report = try #require(VolumeCapabilityReport.read(URL(fileURLWithPath: "/")))
        #expect(!report.format.typeName.isEmpty)
        #expect(report.rows.count == 13)
        #expect(report.rows.first?.label == "File system:")
        #expect(report.caseSensitive != nil)
        #expect(report.supportsExtendedAttributes == true)
    }

    @Test func ntfsReadOnlyIsExplained() {
        var report = VolumeCapabilityReport(format: FileSystemCapabilities(typeName: "ntfs", isReadOnly: true))
        report.supportsTrash = false
        #expect(report.readOnlyExplanation?.contains("can't write to them") == true)
        #expect(report.notes.first == report.readOnlyExplanation)
        // The generic read-only sentence isn't repeated, and Trash isn't mentioned twice.
        #expect(report.notes.filter { $0.contains("read") && $0.contains("NTFS") }.count == 1)
        #expect(report.rows.first { $0.label == "Access:" }?.value == "Read-only")
    }

    @Test func fatLimitsAndUnknownValues() {
        let report = VolumeCapabilityReport(format: FileSystemCapabilities(typeName: "msdos", isReadOnly: false))
        #expect(report.rows.first { $0.label == "Maximum file size:" }?.value == "4 GB (minus 1 byte)")
        #expect(report.rows.first { $0.label == "Supports the Trash:" }?.value == "Unknown")
        #expect(report.notes.contains { $0.contains("4 GB") })
        #expect(VolumeCapabilityReport.sizeText(Int64.max) == "No practical limit")
    }
}

@Suite("Saved searches open from Finder")
struct SavedSearchDocumentTypeTests {
    @Test func infoPlistRegistersTheSavedSearchType() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let saved = try #require(types.first { ($0["CFBundleTypeExtensions"] as? [String])?.contains(SavedSearch.fileExtension) == true })
        #expect(saved["CFBundleTypeRole"] as? String == "Viewer")
        #expect(saved["LSHandlerRank"] as? String == "Owner")
        let identifier = try #require((saved["LSItemContentTypes"] as? [String])?.first)
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(exported.first { $0["UTTypeIdentifier"] as? String == identifier })
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String]) == [SavedSearch.fileExtension])
    }
}
