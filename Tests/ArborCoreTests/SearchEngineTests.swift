import Foundation
import Testing
@testable import ArborCore

@Suite("Search history, saved searches, coverage")
struct SearchSupportTests {
    @Test func historyDedupesRefinesAndCaps() {
        var h = SearchHistory(limit: 3)
        h.record("rep", refining: true)
        h.record("repo", refining: true)
        h.record("report", refining: true)
        #expect(h.entries == ["report"])
        h.record("budget")
        h.record("REPORT")
        #expect(h.entries == ["REPORT", "budget"])
        h.record("a"); h.record("b")
        #expect(h.entries == ["b", "a", "REPORT"])
        h.record("   ")
        #expect(h.entries.count == 3)
        #expect(h.suggestions(for: "") == ["b", "a", "REPORT"])
        #expect(h.suggestions(for: "rep") == ["REPORT"])
        #expect(h.suggestions(for: "report") == [])          // the text itself isn't suggested
        h.clear()
        #expect(h.entries.isEmpty)
    }

    @Test func historyRefiningOnlyReplacesRelatedQueries() {
        var h = SearchHistory()
        h.record("invoice")
        h.record("budget", refining: true)
        #expect(h.entries == ["budget", "invoice"])
    }

    @Test func savedSearchRoundTrip() throws {
        let request = SearchRequest(query: "report kind:document", scope: URL(fileURLWithPath: "/Users/me/Docs"),
                                    recursive: false, options: [.contents, .zipped])
        let saved = SavedSearch(request: request, volumeUUID: "ABC", bookmark: Data([1, 2, 3]),
                                saved: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try saved.encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"format\" : \"arbor.search\""))
        #expect(json.contains("\"query\" : \"report kind:document\""))
        let back = try SavedSearch.decode(data)
        #expect(back == saved)
        #expect(back.request() == request)
        #expect(back.request(resolvedScope: URL(fileURLWithPath: "/Moved")).scope?.path == "/Moved")
    }

    @Test func savedSearchReadsFromAFileAndThroughALink() throws {
        let fixture = try Fixture()
        let saved = SavedSearch(request: SearchRequest(query: "x"))
        let file = fixture.root.appendingPathComponent("a.arborsearch")
        try saved.encoded().write(to: file)
        let link = fixture.root.appendingPathComponent("link.arborsearch")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try SavedSearch.read(from: file).query == "x")
        #expect(try SavedSearch.read(from: link).query == "x")
    }

    @Test func savedSearchRefusesOversizedFilesAndFIFOsWithoutBlocking() throws {
        let fixture = try Fixture()
        let big = fixture.root.appendingPathComponent("big.arborsearch")
        try Data(repeating: 0x20, count: SavedSearch.maxFileBytes + 1).write(to: big)
        #expect(throws: SavedSearch.DecodeError.notASavedSearch) { try SavedSearch.read(from: big) }
        let fifo = fixture.root.appendingPathComponent("pipe.arborsearch")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: SavedSearch.DecodeError.notASavedSearch) { try SavedSearch.read(from: fifo) }
    }

    @Test func savedSearchRejectsOtherFiles() throws {
        #expect(throws: SavedSearch.DecodeError.notASavedSearch) { try SavedSearch.decode(Data("{\"a\":1}".utf8)) }
        #expect(throws: SavedSearch.DecodeError.notASavedSearch) { try SavedSearch.decode(Data("not json".utf8)) }
        var future = SavedSearch(request: SearchRequest(query: "x"))
        future.version = 99
        #expect(throws: SavedSearch.DecodeError.newerVersion(99)) { try SavedSearch.decode(try future.encoded()) }
        #expect(SavedSearch.suggestedFileName(for: "a/b: c") == "a-b- c.arborsearch")
        #expect(SavedSearch.suggestedFileName(for: "  ") == "Search.arborsearch")
    }

    @Test func aTagCollectionIsSavedUnderItsTagName() throws {
        let work = try #require(TagCollectionQuery.request(for: "Work"))
        #expect(SavedSearch.suggestedFileName(for: work) == "Work.arborsearch")
        let path = try #require(TagCollectionQuery.request(for: "a/b"))
        #expect(SavedSearch.suggestedFileName(for: path) == "a-b.arborsearch")
        #expect(SavedSearch.suggestedFileName(for: TagCollectionQuery.allTagged) == "Tags.arborsearch")
        #expect(SavedSearch.suggestedFileName(for: SearchRequest(query: "report")) == "report.arborsearch")
    }

    @Test func searchLocationKeysCarryOptions() {
        let scope = URL(fileURLWithPath: "/Users/me")
        let plain = Location.search(SearchRequest(query: "a&b=c", scope: scope))
        #expect(plain.key == "search?q=a%26b%3Dc&scope=/Users/me&recursive=1")   // unchanged without options
        let withOptions = Location.search(SearchRequest(query: "x", scope: scope, recursive: false, options: [.contents, .systemFiles, .zipped]))
        #expect(withOptions.key.hasSuffix("&opts=csz"))
        #expect(Location(key: withOptions.key) == withOptions)
        if case .search(let r)? = Location(key: withOptions.key) {
            #expect(r.options == [.contents, .systemFiles, .zipped])
            #expect(r.recursive == false)
        } else {
            Issue.record("didn't round-trip")
        }
        #expect(withOptions != .search(SearchRequest(query: "x", scope: scope, recursive: false)))
    }

    @Test func historyReplaceKeepsBackStack() {
        let folder = Location.folder(URL(fileURLWithPath: "/a"))
        var h = NavigationHistory(start: folder)
        h.visit(.search(SearchRequest(query: "re", scope: URL(fileURLWithPath: "/a"))))
        h.replaceCurrent(with: .search(SearchRequest(query: "report", scope: URL(fileURLWithPath: "/a"))))
        #expect(h.backStack.map(\.location) == [folder])
        #expect(h.current.location == .search(SearchRequest(query: "report", scope: URL(fileURLWithPath: "/a"))))
        #expect(h.goBack()?.location == folder)
    }

    @Test func coverageStatusNeverOverclaims() {
        var c = SearchCoverage()
        #expect(c.statusLine == "Searching…")
        c.phase = .finished
        #expect(c.statusLine == "Search complete")
        #expect(c.isComplete)
        c.addDenied("/x/private")
        #expect(c.statusLine == "Search incomplete: 1 folder couldn't be opened (access denied)")
        #expect(!c.isComplete)
        c.indexUnavailable = true
        #expect(c.statusLine.hasSuffix("(+1 more)"))
        #expect(c.details.contains("    /x/private"))
        var stopped = SearchCoverage()
        stopped.phase = .stopped
        #expect(stopped.statusLine == "Search stopped")
        stopped.resultLimit = 10_000
        #expect(stopped.statusLine.hasPrefix("Search stopped: only the first"))
        var offline = SearchCoverage()
        offline.phase = .finished
        offline.scopeUnavailable = "USB"
        #expect(offline.statusLine.contains("isn't available"))
        var failed = SearchCoverage()
        failed.phase = .failed("bad query")
        #expect(failed.statusLine == "Search couldn't run: bad query")
        var fromIndex = SearchCoverage()
        fromIndex.phase = .finished
        fromIndex.contentUnchecked = 4
        fromIndex.contentFromIndex = true
        #expect(fromIndex.isComplete)   // the index covered what couldn't be read directly
        fromIndex.contentFromIndex = false
        #expect(fromIndex.statusLine.contains("4 files' contents couldn't be checked"))
    }
}

@Suite("Identity, content and archives")
struct SearchReaderTests {
    @Test func identityMergesEntriesButKeepsHardLinks() throws {
        let fx = try Fixture()
        let a = try fx.file("a.txt")
        let link = fx.url("b.txt")
        try FileManager.default.linkItem(at: a, to: link)
        let ia = try #require(FileIdentity.of(path: a.path))
        #expect(FileIdentity.of(path: a.path) == ia)
        #expect(FileIdentity.of(path: link.path) != ia)          // same inode, different entry
        #expect(FileIdentity.of(path: link.path)?.inode == ia.inode)
        let dir = try fx.folder("d")
        #expect(FileIdentity.of(path: dir.path)?.entry == nil)
        #expect(FileIdentity.of(path: fx.url("missing").path) == nil)
    }

    @Test func textContentReadsTextOnly() throws {
        let fx = try Fixture()
        let utf8 = try fx.file("n.txt", "Crème brûlée recipe")
        #expect(TextContent(url: utf8, typeIdentifier: nil, size: nil).contains("creme brulee") == true)
        #expect(TextContent(url: utf8, typeIdentifier: nil, size: nil).contains("pizza") == false)
        let utf16 = fx.url("w.txt")
        try "Wide text".write(to: utf16, atomically: true, encoding: .utf16)
        #expect(TextContent(url: utf16, typeIdentifier: nil, size: nil).contains("wide") == true)
        let latin = fx.url("l.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin)   // "café" in Latin-1
        #expect(TextContent(url: latin, typeIdentifier: nil, size: nil).contains("cafe") == true)
        let png = try fx.file("p.png", "invoice")
        #expect(TextContent(url: png, typeIdentifier: "public.png", size: nil).contains("invoice") == nil)
        let big = try fx.file("big.txt", String(repeating: "a", count: 100))
        #expect(TextContent(url: big, typeIdentifier: nil, size: nil, maxBytes: 10).outcome == .tooLarge)
        let source = try fx.file("x.swift", "let invoice = 1")
        #expect(TextContent(url: source, typeIdentifier: "public.swift-source", size: nil).contains("invoice") == true)
    }

    @Test func textContentOpensRegularFilesOnly() throws {
        let fx = try Fixture()
        let real = try fx.file("real.txt", "invoice")
        let fifo = fx.url("notes.txt")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: fx.url("link.txt"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: fx.url("pipe.txt"), withDestinationURL: fifo)
        // A blocking open of the FIFO would hang here.
        #expect(TextContent(url: fifo, typeIdentifier: nil, size: nil).outcome == .notText)
        #expect(TextContent(url: fx.url("pipe.txt"), typeIdentifier: nil, size: nil).outcome == .notText)
        #expect(TextContent(url: fx.url("link.txt"), typeIdentifier: nil, size: nil).outcome == .notText)
        #expect(TextContent(url: real, typeIdentifier: nil, size: nil).contains("invoice") == true)
        #expect(FileHandle.openRegularFile(atPath: fifo.path) == nil)
        #expect(FileHandle.openRegularFile(atPath: fx.url("link.txt").path) == nil)
        #expect(FileHandle.openRegularFile(atPath: fx.root.path) == nil)
        #expect(FileHandle.openRegularFile(atPath: "/dev/null") == nil)
        let handle = try #require(FileHandle.openRegularFile(atPath: real.path))
        #expect(try handle.readToEnd() == Data("invoice".utf8))
        try handle.close()
    }

    @Test func zipDirectoryListsEntries() throws {
        let fx = try Fixture()
        try fx.file("src/top.txt", "a")
        try fx.file("src/inner/deep report.md", "b")
        let zip = fx.url("bundle.zip")
        try runDitto(source: fx.url("src"), zip: zip)
        // Search lists archives with the same reader as archive browsing.
        let entries = try ZipDirectory.read(zip, limit: 20_000)
        let paths = Set(entries.filter { $0.kind == .file }.compactMap(\.path))
        #expect(paths == ["src/top.txt", "src/inner/deep report.md"])
        #expect(entries.first { $0.path == "src/top.txt" }?.size == 1)
        #expect(try ZipDirectory.read(zip, limit: 1).count == 1)
        #expect(ZipDirectory.hasZipName(zip) && !ZipDirectory.hasZipName(fx.url("src/top.txt")))
        let notZip = try fx.file("fake.zip", "hello")
        #expect(throws: ZipDirectory.ReadError.notZip) { try ZipDirectory.read(notZip, limit: 10) }
    }
}

func runDitto(source: URL, zip: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", source.path, zip.path]
    try p.run()
    p.waitUntilExit()
}

// MARK: - Direct scan on fixtures (FE-131, FE-141)

private func scan(_ query: String, in root: URL, options: SearchOptions = [], recursive: Bool = true,
                  configure: (inout DirectSearch.Configuration) -> Void = { _ in }) throws -> (names: [String], hits: [SearchHit], report: DirectSearchReport) {
    let expression = try AQSParser.parse(query).get()
    var config = DirectSearch.Configuration(root: root)
    config.recursive = recursive
    config.includeHidden = options.contains(.systemFiles)
    config.enterPackages = options.contains(.systemFiles)
    config.searchArchives = options.contains(.zipped)
    configure(&config)
    let search = DirectSearch(evaluator: SearchEvaluator(expression, matchContents: options.contains(.contents)), configuration: config)
    let lock = NSLock()
    var hits: [SearchHit] = []
    var report = DirectSearchReport()
    let done = DispatchSemaphore(value: 0)
    search.start(onHits: { batch in lock.lock(); hits += batch; lock.unlock() },
                 completion: { r in report = r; done.signal() })
    #expect(done.wait(timeout: .now() + 30) == .success)
    lock.lock(); defer { lock.unlock() }
    return (hits.map(\.item.name).sorted(), hits, report)
}

@Suite("Direct search on fixtures")
struct DirectSearchTests {
    func tree() throws -> Fixture {
        let fx = try Fixture()
        try fx.file("Docs/Report 2026.txt", "Quarterly invoice summary")
        try fx.file("Docs/notes.md", "nothing to see")
        try fx.file("Docs/Archive/old report.txt", "legacy")
        try fx.file("Docs/Archive/Deep/deeper/report-final.pdf", "%PDF fake")
        try fx.file("Pictures/beach.jpg", "jpg")
        try fx.file("Pictures/.hidden report.txt", "secret")
        try fx.folder("Reports")
        try fx.file("Tool.app/Contents/report inside.txt", "pkg")
        return fx
    }

    @Test func searchesSubfoldersByDefault() throws {
        let fx = try tree()
        let r = try scan("report", in: fx.root)
        #expect(r.names == ["Report 2026.txt", "Reports", "old report.txt", "report-final.pdf"])
        #expect(r.report.cancelled == false)
        #expect(r.report.deniedCount == 0)
        let folders = Set(r.hits.map { $0.item.url.deletingLastPathComponent().lastPathComponent })
        #expect(folders.contains("deeper"))
        #expect(r.hits.allSatisfy { $0.reasons == [.name] })
    }

    @Test func currentFolderOnly() throws {
        let fx = try tree()
        #expect(try scan("report", in: fx.url("Docs"), recursive: false).names == ["Report 2026.txt"])
    }

    @Test func hiddenItemsAndPackagesNeedSystemFiles() throws {
        let fx = try tree()
        let plain = try scan("report", in: fx.root)
        #expect(!plain.names.contains(".hidden report.txt"))
        #expect(!plain.names.contains("report inside.txt"))
        let system = try scan("report", in: fx.root, options: [.systemFiles])
        #expect(system.names.contains(".hidden report.txt"))
        #expect(system.names.contains("report inside.txt"))
        // The package itself is always a candidate.
        #expect(try scan("tool", in: fx.root).names == ["Tool.app"])
    }

    @Test func propertiesAndBooleans() throws {
        let fx = try tree()
        #expect(try scan("ext:txt", in: fx.root).names == ["Report 2026.txt", "old report.txt"])
        #expect(try scan("kind:folder", in: fx.url("Docs")).names == ["Archive", "Deep", "deeper"])
        #expect(try scan("kind:picture", in: fx.root).names == ["beach.jpg"])
        #expect(try scan("report -ext:pdf", in: fx.url("Docs")).names == ["Report 2026.txt", "old report.txt"])
        #expect(try scan("report OR beach AND ext:jpg", in: fx.root).names == ["beach.jpg"])   // left to right
        #expect(try scan("datemodified:today size:<1KB ext:md", in: fx.root).names == ["notes.md"])
        #expect(try scan("folder:archive ext:txt", in: fx.root).names == ["old report.txt"])
    }

    @Test func contentsOfTextFiles() throws {
        let fx = try tree()
        let r = try scan("content:invoice", in: fx.root)
        #expect(r.names == ["Report 2026.txt"])
        #expect(r.hits.first?.reasons == [.contents])
        // The PDF can't be read as text: counted, never reported as a non-match silently.
        #expect(r.report.contentUnchecked >= 1)
        #expect(try scan("invoice", in: fx.root).names == [])
        #expect(try scan("invoice", in: fx.root, options: [.contents]).names == ["Report 2026.txt"])
    }

    @Test func fifosNamedLikeTextOrZipDoNotBlockTheScan() throws {
        let fx = try Fixture()
        try fx.file("box/invoice.txt", "invoice")
        #expect(mkfifo(fx.url("box/notes.txt").path, 0o600) == 0)
        #expect(mkfifo(fx.url("box/a.zip").path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: fx.url("box/pipe.txt"), withDestinationURL: fx.url("box/notes.txt"))
        let r = try scan("content:invoice", in: fx.root, options: [.contents, .zipped])
        #expect(r.names == ["invoice.txt"])
        #expect(r.report.archivesUnreadable == 1)
    }

    @Test func manyFilesArriveInBatches() throws {
        let fx = try Fixture()
        for i in 0..<400 { try fx.file("bulk/\(i % 10)/item \(i).txt", "n") }
        var batches = 0
        let expression = try AQSParser.parse("item").get()
        var config = DirectSearch.Configuration(root: fx.root)
        config.batchSize = 25
        let search = DirectSearch(evaluator: SearchEvaluator(expression), configuration: config)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        var report = DirectSearchReport()
        search.start(onHits: { b in lock.lock(); batches += 1; count += b.count; lock.unlock() }, completion: { report = $0; done.signal() })
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(count == 400)
        #expect(batches > 1)
        #expect(report.hits == 400)
        #expect(report.directories == 12)
    }

    @Test func resultLimitStopsTheScan() throws {
        let fx = try Fixture()
        for i in 0..<120 { try fx.file("many/f\(i).txt") }
        let r = try scan("f", in: fx.root) { $0.resultLimit = 50 }
        #expect(r.hits.count == 50)
        #expect(r.report.limitReached)
    }

    @Test func symlinkLoopsAreNotFollowed() throws {
        let fx = try Fixture()
        try fx.file("a/b/target.txt")
        try FileManager.default.createSymbolicLink(at: fx.url("a/b/loop"), withDestinationURL: fx.url("a"))
        try FileManager.default.createSymbolicLink(at: fx.url("a/self"), withDestinationURL: fx.url("a"))
        let r = try scan("target", in: fx.root)
        #expect(r.names == ["target.txt"])
        #expect(try scan("loop", in: fx.root).names == ["loop"])   // the link itself is a result
    }

    @Test func deniedFoldersAreReported() throws {
        let fx = try Fixture()
        try fx.file("open/report.txt")
        let locked = try fx.folder("locked")
        try fx.file("locked/report secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let r = try scan("report", in: fx.root)
        #expect(r.names == ["report.txt"])
        #expect(r.report.deniedCount == 1)
        #expect(r.report.deniedFolders.count == 1 && r.report.deniedFolders[0].hasSuffix(fx.root.lastPathComponent + "/locked"))
        var coverage = SearchCoverage()
        coverage.phase = .finished
        r.report.apply(to: &coverage)
        #expect(coverage.statusLine.contains("couldn't be opened"))
    }

    @Test func missingRootIsAnError() throws {
        let fx = try Fixture()
        let r = try scan("x", in: fx.url("gone"))
        #expect(r.report.rootError == .notFound(path: fx.url("gone").path))
    }

    @Test func zippedFilesOption() throws {
        let fx = try Fixture()
        try fx.file("src/inner/budget plan.txt", "a")
        try runDitto(source: fx.url("src"), zip: fx.url("data/bundle.zip"))
        try FileManager.default.removeItem(at: fx.url("src"))
        #expect(try scan("budget", in: fx.root).names == [])
        let r = try scan("budget", in: fx.root, options: [.zipped])
        #expect(r.names == ["bundle.zip"])
        #expect(r.hits.first?.reasons == [.archiveEntry("src/inner/budget plan.txt")])
    }

    @Test func cancellationStopsQuickly() throws {
        let fx = try Fixture()
        for i in 0..<300 { try fx.file("d\(i % 30)/x\(i).txt") }
        let expression = try AQSParser.parse("x").get()
        var config = DirectSearch.Configuration(root: fx.root)
        config.concurrency = 1
        let search = DirectSearch(evaluator: SearchEvaluator(expression), configuration: config)
        search.cancel()
        let done = DispatchSemaphore(value: 0)
        var report = DirectSearchReport()
        search.start(onHits: { _ in }, completion: { report = $0; done.signal() })
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(report.cancelled)
        #expect(report.hits < 300)
    }
}
