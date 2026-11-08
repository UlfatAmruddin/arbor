import Testing
import Foundation
@testable import ArborCore

/// Regressions from places, search, archive and dialog QA (docs/features/qa-places.md).

@Suite struct ArchiveLinkChainTests {
    /// "self" is ".", so "self/.." escapes the tree; links must be resolved through other links.
    let chained = [
        ArchiveEntry(rawPath: "self", kind: .symlink, linkTarget: "."),
        ArchiveEntry(rawPath: "esc", kind: .symlink, linkTarget: "self/../outside.txt"),
        ArchiveEntry(rawPath: "up", kind: .symlink, linkTarget: "self/self/../.."),
        ArchiveEntry(rawPath: "SELFCASE", kind: .symlink, linkTarget: "SELF/../x"),
        ArchiveEntry(rawPath: "dir/", kind: .directory),
        ArchiveEntry(rawPath: "dir/parent", kind: .symlink, linkTarget: ".."),
        ArchiveEntry(rawPath: "dir/esc", kind: .symlink, linkTarget: "parent/../y"),
        ArchiveEntry(rawPath: "loop1", kind: .symlink, linkTarget: "loop2/x"),
        ArchiveEntry(rawPath: "loop2", kind: .symlink, linkTarget: "loop1/x"),
        ArchiveEntry(rawPath: "fine", kind: .symlink, linkTarget: "self/dir/parent/dir"),
    ]

    @Test func plannerRejectsLinksThatEscapeThroughOtherLinks() {
        let plan = ExtractionPlanner.plan(entries: chained, roots: [""])
        let rejected = Set(plan.rejected.filter { $0.reason == .linkOutside }.map(\.entry.rawPath))
        #expect(rejected == ["esc", "up", "SELFCASE", "dir/esc", "loop1", "loop2"])
        #expect(Set(plan.included.map(\.rawPath)) == ["self", "dir/parent", "fine"])
    }

    @Test func verifierRemovesLinksThatEscapeThroughOtherLinks() throws {
        let fx = try Fixture()
        let staging = try fx.folder("stage")
        try fx.folder("stage/dir")
        let fm = FileManager.default
        for entry in chained where entry.kind == .symlink {
            try fm.createSymbolicLink(atPath: fx.url("stage/" + entry.rawPath).path, withDestinationPath: entry.linkTarget!)
        }
        let report = ExtractionVerifier.verify(staging: staging, base: [], quarantine: nil)
        #expect(Set(report.removed) == ["esc", "up", "SELFCASE", "dir/esc", "loop1", "loop2"])
        #expect(fx.names("stage") == ["dir", "fine", "self"])
    }
}

@Suite struct HistorySelectionTests {
    /// Back into search results with one of two "same.txt" selected brought both back selected.
    @Test func backAndForwardKeepTheSelectedItemsNotJustNames() {
        let results = Location.search(SearchRequest(query: "same", scope: URL(fileURLWithPath: "/tmp/qa"), recursive: true))
        let chosen = URL(fileURLWithPath: "/tmp/qa/b/same.txt")
        var history = NavigationHistory(start: results)
        history.saveState(selectedNames: ["same.txt"], selectedURLs: [chosen], topVisibleName: nil)
        history.visit(URL(fileURLWithPath: "/tmp/qa/a"))
        #expect(history.peekBack()?.selectedURLs == [chosen])
        #expect(history.goBack()?.selectedURLs == [chosen])
        #expect(history.peekForward()?.selectedURLs == [])
    }
}

@Suite struct AQSRobustnessTests {
    /// Odd and broken queries must parse to an expression or a syntax error, never crash or hang.
    static let queries = [
        "", " ", "\"", "\"\"", "\"unterminated", "(", ")", "(((", ")))", "()", "( )", "a AND", "OR", "AND OR NOT",
        "NOT", "NOT NOT a", "-", "--a", "+", "*", "?", "**", "*?*", "a OR OR b", "name:", "name:\"\"", "size:", "size:>",
        "size:<>", "size:>-1", "size:99999999999999999999999 GB", "size:1..", "size:..5", "size:5..1", "size:gigantic2",
        "date:", "date:>", "date:31/02/2026", "date:2026-13-45", "date:..", "date:today..yesterday", "date:9999999999",
        "datemodified:last year..", "kind:", "kind:nonsense", "ext:", "ext:.", "ext:..txt", "type:\"", "tag:(a OR",
        "author:", ":", "::", "a:b:c", "name:(a OR b", "name:~<", "name:~=", "name:=", "name:<>", "~", "~~", "=", "<>",
        "😀", "名前:テスト", "\u{0}", "a\u{0}b", "\\", "/", "../..", "%", String(repeating: "(", count: 2000),
        String(repeating: "a OR ", count: 2000) + "b", String(repeating: "NOT ", count: 5000) + "x",
        String(repeating: "\"", count: 1001), "size:>1KB AND date:this week OR kind:folder NOT ext:tmp",
    ]

    @Test func oddQueriesParseOrFailCleanly() {
        let candidate = SearchCandidate(name: "Report 2026.txt", folderPath: "/tmp/x", isFolder: false, size: 10,
                                        modified: Date(), created: Date(), typeIdentifier: "public.plain-text",
                                        typeDescription: "Plain Text", tags: ["Red"], authors: ["Ann"])
        for query in Self.queries {
            switch AQSParser.parse(query) {
            case .success(let expression):
                _ = SearchEvaluator(expression).evaluate(candidate)
                _ = SearchEvaluator(expression, matchContents: true).evaluate(candidate)
            case .failure(let error):
                #expect(!error.message.isEmpty, "\(query.prefix(40))")
            }
        }
    }

    @Test func wildcardsDoNotBlowUp() {
        let long = String(repeating: "a", count: 4000)
        #expect(!TextMatcher.wildcard(long + "b", String(repeating: "*a", count: 200) + "*c"))
        #expect(TextMatcher.wildcard("", "*"))
        #expect(!TextMatcher.wildcard("", "?"))
    }
}

@Suite struct GalleryDateEdgeTests {
    let now = Date(timeIntervalSince1970: 1_794_000_000)   // November 2026

    @Test func photosWithOnlyImplausibleFileDatesAreStillShown() {
        let future = Date(timeIntervalSince1970: 4_102_444_800)   // 2100
        let ancient = Date(timeIntervalSince1970: -2_300_000_000)  // before 1900
        #expect(GalleryTimeline.bestDate(taken: nil, created: future, modified: ancient, now: now) == ancient)
        #expect(GalleryTimeline.bestDate(taken: future, created: future, modified: nil, now: now) == future)
    }

    @Test func impossibleExifDatesAreRejected() {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(GalleryTimeline.parseExifDate("2024:02:31 10:00:00", timeZone: utc) == nil)
        #expect(GalleryTimeline.parseExifDate("2024:03:15 25:61:00", timeZone: utc) == nil)
        #expect(GalleryTimeline.parseExifDate("2024:02:29 23:59:59", timeZone: utc) != nil)
    }
}

@Suite struct AddressInputTests {
    let resolver = PathResolver(homeDirectory: URL(fileURLWithPath: "/Users/test"), probe: { _ in nil })

    /// "smb://" with no server used to be handed to the system's connect flow (Finder's Connect to Server).
    @Test func serverAddressWithoutAServerIsInvalid() {
        for text in ["smb://", "smb:///share", "afp://", "SMB://  ", #"\\"#, #"\\\share"#] {
            guard case .failure = resolver.resolve(text, relativeTo: nil) else {
                Issue.record("\(text) should be rejected"); continue
            }
        }
        #expect(resolver.resolve("smb://nas", relativeTo: nil) == .success(.network(URL(string: "smb://nas")!)))
        #expect(resolver.resolve("smb://user@nas/share", relativeTo: nil) == .success(.network(URL(string: "smb://user@nas/share")!)))
    }
}

@Suite struct OddNameArchiveTests {
    static let names = ["-C", "--help", "line\nbreak.txt", "tab\there.txt", "back\\slash.txt", "star*?.txt", "[x].txt",
                        "üñí.txt", "space .txt", "a -> b.txt", " lead.txt", "#hash", "x link to y"]

    /// Compress to ▸ ZIP / 7z / TAR with odd names, then list and extract only the selected item and everything.
    @Test(arguments: [ArchiveCreateFormat.zip, .sevenZip, .tar])
    func oddNamesRoundTrip(_ format: ArchiveCreateFormat) throws {
        let fx = try Fixture()
        try fx.folder("src")
        for name in Self.names { try fx.file("src/" + name, name) }
        try fx.folder("out")
        let archive = fx.url("out/odd.\(format.fileExtension)")
        try ArchiveTool.create(format: format, sources: Self.names.map { fx.url("src/" + $0) }, output: archive, process: ToolProcess())
        let listing = try ArchiveTool.listWithBsdtar(archive)
        // libarchive reads "\" in ZIP names as a separator (like Windows); every other name survives.
        let expected = Set(Self.names.map { format == .zip ? $0.replacingOccurrences(of: "\\", with: "/") : $0 })
        #expect(Set(listing.entries.compactMap(\.path)) == expected, "\(format)")

        // Names as the browsing view shows them (bsdtar stores decomposed Unicode, like the disk).
        let shown = ArchiveIndex(entries: listing.entries).children(of: "")?.map(\.name) ?? []
        for name in shown where name != "back" {
            let plan = ExtractionPlanner.plan(entries: listing.entries, roots: [name])
            let staging = try fx.folder("one-\(UUID().uuidString)")
            try ArchiveTool.extract(archive, plan: plan, into: staging, process: ToolProcess())
            let found = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            #expect(found == [name], "\(format): extracting \(name.debugDescription) gave \(found)")
        }
    }
}

@Suite struct ArchiveErrorTextTests {
    /// A damaged ZIP's alert listed every extracted name ("x top/ / x top/sub/ / …") before the error.
    @Test func progressLinesAreNotPartOfTheError() {
        let stderr = "x top/\nx top/sub/\nx top/sub/b.txt\nx top/sub/._b.txt: ZIP decompression failed (-5)\nbsdtar: Error exit delayed from previous errors.\n"
        #expect(ArchiveError.summarize(stderr) == "top/sub/._b.txt: ZIP decompression failed (-5)")
        #expect(ArchiveError.summarize("bsdtar: Error opening archive: Unrecognized archive format\n") == "Error opening archive: Unrecognized archive format")
    }
}

@Suite(.serialized) struct NestedArchiveTests {
    @Test func upFromANestedArchiveReturnsIntoTheOuterArchive() {
        NestedArchives.removeAll()
        defer { NestedArchives.removeAll() }
        let outer = URL(fileURLWithPath: "/tmp/qa/outer.zip")
        let copy = URL(fileURLWithPath: "/tmp/qa-session/1234/inner.zip")
        #expect(Location.archive(copy, innerPath: "").parent() == .folder(URL(fileURLWithPath: "/tmp/qa-session/1234")))
        NestedArchives.register(copy: copy, parent: .archive(outer, innerPath: "docs"))
        #expect(Location.archive(copy, innerPath: "").parent() == .archive(outer, innerPath: "docs"))
        #expect(Location.archive(copy, innerPath: "a/b").parent() == .archive(copy, innerPath: "a"))
        #expect(Location.archive(outer, innerPath: "").parent() == .folder(URL(fileURLWithPath: "/tmp/qa")))
    }
}
