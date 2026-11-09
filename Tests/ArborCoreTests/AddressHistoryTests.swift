import Foundation
import Testing
@testable import ArborCore

private func folder(_ path: String) -> Location { .folder(URL(fileURLWithPath: path, isDirectory: true)) }

private func keys(_ load: AddressHistoryLoad) -> [String] { load.entries.map(\.key) }

private func parse(_ json: String, limit: Int = 100) -> AddressHistoryLoad {
    AddressHistoryFile.parse(Data(json.utf8), limit: limit)
}

@Suite("Address history: the list (FE-006)")
struct RecentLocationsPersistenceTests {
    @Test func aRestoredEntryAsksNoDiskForItsURL() throws {
        // A URL built with a disk check comes back without a directory path when the folder doesn't exist.
        let entry = try #require(RecentLocations.Entry(storedKey: "folder:/Volumes/Gone Away/Reports"))
        guard case .folder(let url) = entry.location else { Issue.record("not a folder"); return }
        #expect(url.hasDirectoryPath)
        #expect(entry.folderPath == "/Volumes/Gone Away/Reports")
    }

    @Test func everyURLFromAKeySaysWhatItIs() throws {
        guard case .archive(let file, _)? = Location(key: "archive?file=/Volumes/Gone/a.zip&inner=x") else { Issue.record("not an archive"); return }
        #expect(!file.hasDirectoryPath)
        guard case .search(let request)? = Location(key: "search?q=a&scope=/Volumes/Gone&recursive=1&also=/Volumes/Other") else { Issue.record("not a search"); return }
        #expect(try #require(request.scope).hasDirectoryPath)
        #expect(try #require(request.extraScopes.first).hasDirectoryPath)
    }

    @Test func storedKeysMustBeThingsTheListKeeps() {
        for bad in ["", "nonsense", "folder:relative", "folder:/a/../b", "folder:/a/./b", "folder:/a//b", "folder:/a/",
                    "folder:/a\nb", "search?q=x&recursive=1", "%73earch?q=x&scope=/a", "folder:/" + String(repeating: "a", count: 5_000)] {
            #expect(RecentLocations.Entry(storedKey: bad) == nil, "\(bad)")
        }
        for good in ["folder:/", "folder:/a/b", "home", "thismac", "trash", "library?name=Documents", "server?url=smb://nas/share"] {
            #expect(RecentLocations.Entry(storedKey: good) != nil, "\(good)")
        }
    }

    @Test func oversizedKeysAreNotRememberedAtAll() {
        var recent = RecentLocations()
        #expect(recent.record(folder("/" + String(repeating: "a", count: 5_000))) == nil)
        #expect(recent.entries.isEmpty)
    }

    @Test func aPasswordInATypedAddressIsNeverStored() throws {
        let url = try #require(URL(string: "smb://me:hunter2@nas/share"))
        let address = try #require(NetworkAddress(url: url))
        var recent = RecentLocations()
        let key = recent.record(.server(address))
        #expect(key?.contains("nas") == true)
        #expect(key?.contains("hunter2") == false)
    }

    @Test func thisSessionStaysAheadOfWhatWasRemembered() throws {
        var recent = RecentLocations(limit: 3)
        recent.record(folder("/b"))
        recent.adoptOlder(try ["folder:/a", "folder:/b", "folder:/c", "folder:/d"].map { try #require(RecentLocations.Entry(storedKey: $0)) })
        #expect(recent.records.map(\.key) == ["folder:/b", "folder:/a", "folder:/c"])
    }
}

@Suite("Address history: the file (FE-006)")
struct AddressHistoryFileTests {
    @Test func writesAVersionAndReadsItBack() throws {
        let entries = try ["folder:/Users/me/My Files", "home"].map { try #require(RecentLocations.Entry(storedKey: $0)) }
        let data = try #require(AddressHistoryFile.encoded(entries))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == #"{"entries":["folder:/Users/me/My Files","home"],"version":1}"#)
        let load = AddressHistoryFile.parse(data, limit: 100)
        #expect(keys(load) == ["folder:/Users/me/My Files", "home"])
        #expect(!load.isNewerVersion)
    }

    @Test func aFullListOfTheLongestEntriesFitsTheReadLimit() throws {
        // Quotes escape to two bytes, the worst an accepted key can do.
        let entries = try (0..<AddressHistoryStore.storedLimit).map { index -> RecentLocations.Entry in
            let name = "\(index)" + String(repeating: "\"", count: RecentLocations.keyByteLimit - 20)
            return try #require(RecentLocations.Entry(storedKey: "folder:/" + name))
        }
        let data = try #require(AddressHistoryFile.encoded(entries))
        #expect(AddressHistoryFile.parse(data, limit: 100).entries.count == entries.count)
    }

    @Test func damageNeverThrowsAndGivesAnEmptyList() {
        for bad in ["", "not json", "[]", "3", "\"x\"", #"{"version":"#] {
            #expect(parse(bad) == AddressHistoryLoad(), "\(bad)")
        }
    }

    @Test func oneBadEntryLeavesItsNeighbors() {
        let load = parse(#"{"version":1,"entries":[3,"folder:/a",null,"folder:/a/../x","home",{"k":1}]}"#)
        #expect(keys(load) == ["folder:/a", "home"])
    }

    @Test func duplicatesAndOverflowAreDropped() {
        #expect(keys(parse(#"{"version":1,"entries":["home","home","trash","network"]}"#, limit: 2)) == ["home", "trash"])
    }

    @Test func aMissingOrOddVersionIsReadAsTheCurrentOne() {
        #expect(keys(parse(#"{"entries":["home"]}"#)) == ["home"])
        #expect(!parse(#"{"version":"x","entries":["home"]}"#).isNewerVersion)
    }

    @Test func aNewerFileIsReadAndMarked() {
        let load = parse(#"{"version":99,"entries":["home"],"more":true}"#)
        #expect(load.isNewerVersion)
        #expect(keys(load) == ["home"])
    }

    @Test func aSymbolicLinkOrAnOversizedFileIsNotRead() throws {
        let fixture = try Fixture()
        let real = try fixture.file("real.json", #"{"version":1,"entries":["home"]}"#)
        let link = fixture.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(AddressHistoryFile.load(at: link, limit: 100) == AddressHistoryLoad())
        #expect(keys(AddressHistoryFile.load(at: real, limit: 100)) == ["home"])
        let big = try fixture.file("big.json", String(repeating: " ", count: AddressHistoryFile.byteLimit + 1))
        #expect(AddressHistoryFile.load(at: big, limit: 100) == AddressHistoryLoad())
    }
}

/// Runs a store on private queues, so each step can wait for the work it started.
private final class StoreHarness {
    let files = DispatchQueue(label: "test.history.files")
    let callbacks = DispatchQueue(label: "test.history.callbacks")
    let checks = DispatchQueue(label: "test.history.checks")
    let store: AddressHistoryStore
    private let lock = NSLock()
    private var asked: [String] = []
    var missing: Set<String> = []

    init(_ url: URL?) {
        var answer: (String) -> Bool = { _ in false }
        store = AddressHistoryStore(fileURL: url, queue: files, callbackQueue: callbacks, checkQueue: checks, saveDelay: 3_600) { answer($0) }
        answer = { [unowned self] path in
            self.lock.withLock {
                self.asked.append(path)
                return self.missing.contains(path)
            }
        }
    }

    var questions: [String] { lock.withLock { asked } }

    func onStore<T>(_ body: () -> T) -> T { callbacks.sync(execute: body) }

    /// Lets a load that was started reach the store.
    func settle() {
        files.sync {}
        callbacks.sync {}
    }

    func load() {
        onStore { store.loadIfNeeded() }
        settle()
    }

    func check() {
        onStore { store.checkFolders() }
        checks.sync {}
        callbacks.sync {}
    }

    func flush() { onStore { store.flush() } }

    var list: [Location] { onStore { store.list } }
}

@Suite("Address history: the store (FE-006)")
struct AddressHistoryStoreTests {
    @Test func survivesARelaunch() throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("state/AddressHistory.json")
        let first = StoreHarness(url)
        first.load()
        first.onStore { first.store.record(folder("/a")); first.store.record(.home) }
        first.flush()

        let second = StoreHarness(url)
        second.load()
        #expect(second.list == [.home, folder("/a")])
    }

    @Test func loadingAsksNothingAboutTheRememberedFolders() throws {
        let fixture = try Fixture()
        let url = try fixture.file("h.json", #"{"version":1,"entries":["folder:/Volumes/Gone/x","folder:/net/nas/y"]}"#)
        let harness = StoreHarness(url)
        harness.load()
        #expect(harness.list == [folder("/Volumes/Gone/x"), folder("/net/nas/y")])
        #expect(harness.questions.isEmpty)
    }

    @Test func aVisitBeforeTheLoadFinishesKeepsBothAndDoesNotOverwrite() throws {
        let fixture = try Fixture()
        let url = try fixture.file("h.json", #"{"version":1,"entries":["folder:/old"]}"#)
        let harness = StoreHarness(url)
        harness.onStore {
            harness.store.loadIfNeeded()
            harness.store.record(folder("/new"))
            harness.store.flush()
        }
        harness.settle()
        #expect(harness.list == [folder("/new"), folder("/old")])
        harness.flush()
        #expect(keys(AddressHistoryFile.load(at: url, limit: 100)) == ["folder:/new", "folder:/old"])
    }

    @Test func clearErasesTheFileAndTheList() throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("h.json")
        let harness = StoreHarness(url)
        harness.load()
        harness.onStore { harness.store.record(folder("/a")) }
        harness.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        harness.onStore { harness.store.clear() }
        harness.flush()
        #expect(harness.list.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aClearDuringTheLoadWins() throws {
        let fixture = try Fixture()
        let url = try fixture.file("h.json", #"{"version":1,"entries":["folder:/old"]}"#)
        let harness = StoreHarness(url)
        harness.onStore {
            harness.store.loadIfNeeded()
            harness.store.clear()
        }
        harness.settle()
        #expect(harness.list.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aPendingSaveCannotBringBackAClearedFile() throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("h.json")
        let harness = StoreHarness(url)
        harness.load()
        harness.onStore {
            harness.store.record(folder("/a"))
            harness.store.clear()
            harness.store.flush()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aCheckFromBeforeAClearChangesNothing() throws {
        let harness = StoreHarness(nil)
        harness.load()
        harness.missing = ["/a"]
        harness.onStore { harness.store.record(folder("/a")) }
        harness.checks.suspend()
        harness.onStore { harness.store.checkFolders() }
        harness.onStore {
            harness.store.clear()
            harness.store.record(folder("/a"))
        }
        harness.checks.resume()
        harness.checks.sync {}
        harness.callbacks.sync {}
        #expect(harness.list == [folder("/a")])
    }

    @Test func aFileFromANewerVersionIsLeftAloneUntilClear() throws {
        let fixture = try Fixture()
        let original = #"{"version":99,"entries":["home"]}"#
        let url = try fixture.file("h.json", original)
        let harness = StoreHarness(url)
        harness.load()
        harness.onStore { harness.store.record(folder("/a")) }
        harness.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(harness.list == [folder("/a"), .home])
        harness.onStore { harness.store.clear() }
        harness.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aDamagedFileIsReplacedByTheNextSave() throws {
        let fixture = try Fixture()
        let url = try fixture.file("h.json", "not json")
        let harness = StoreHarness(url)
        harness.load()
        #expect(harness.list.isEmpty)
        harness.onStore { harness.store.record(.home) }
        harness.flush()
        #expect(keys(AddressHistoryFile.load(at: url, limit: 100)) == ["home"])
    }

    @Test func aMissingFolderIsHiddenNotForgotten() {
        let harness = StoreHarness(nil)
        harness.load()
        harness.onStore {
            harness.store.record(folder("/a"))
            harness.store.record(folder("/b"))
        }
        harness.missing = ["/a"]
        harness.check()
        #expect(harness.list == [folder("/b")])
        #expect(harness.onStore { harness.store.folderPaths } == ["/b"])
        harness.missing = []
        harness.check()
        #expect(harness.list == [folder("/b"), folder("/a")])
    }

    @Test func aVisitShowsAFolderAgainAtOnce() {
        let harness = StoreHarness(nil)
        harness.load()
        harness.onStore { harness.store.record(folder("/a")) }
        harness.missing = ["/a"]
        harness.check()
        #expect(harness.list.isEmpty)
        harness.onStore { harness.store.record(folder("/a")) }
        #expect(harness.list == [folder("/a")])
    }

    @Test func theListIsShorterThanWhatIsKept() {
        let harness = StoreHarness(nil)
        harness.load()
        harness.onStore { (0..<150).forEach { harness.store.record(folder("/f\($0)")) } }
        #expect(harness.list.count == AddressHistoryStore.listLimit)
        #expect(harness.list.first == folder("/f149"))
        #expect(harness.onStore { harness.store.folderPaths.count } == AddressHistoryStore.storedLimit)
    }

    @Test func onlyAFolderOnALocalPathIsAskedAbout() throws {
        let fixture = try Fixture()
        let there = try fixture.folder("here")
        #expect(!AddressHistoryStore.folderIsMissing(there.path))
        #expect(AddressHistoryStore.folderIsMissing(there.appendingPathComponent("gone").path))
        #expect(!AddressHistoryStore.folderIsMissing("/net/nas/share"))
        #expect(!AddressHistoryStore.folderIsMissing("/Network/Servers/nas"))
    }
}

@Suite("Address history: completion rows (FE-006)")
struct AddressHistoryCompletionTests {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func query(_ text: String) throws -> PathCompletionQuery {
        try #require(PathCompletionQuery.parse(text, base: home, homeDirectory: home))
    }

    private func row(_ name: String, in prefix: String) -> PathCompletionCandidate {
        PathCompletionCandidate(text: prefix + name + "/", name: name, isFolder: true)
    }

    private func rows(_ paths: [String], _ text: String, listed: [PathCompletionCandidate] = [], hasMore: Bool = false,
                      includeHidden: Bool = false) throws -> (rows: [PathCompletionCandidate], hasMore: Bool) {
        PathCompletion.addingHistory(paths, to: (listed, hasMore), for: try query(text), includeHidden: includeHidden)
    }

    @Test func offersDeeperFoldersInTheFormTyped() throws {
        let result = try rows(["/Users/me/Documents/Work/2026", "/Users/me/Music", "/opt/other"], "~/Doc")
        #expect(result.rows.map(\.text) == ["~/Documents/Work/2026/"])
        #expect(result.rows[0].name == "Documents/Work/2026")
        #expect(result.rows[0].isFromHistory)
    }

    @Test func aRowLeadsToTheFolderItNames() throws {
        let typed = try query("~/Doc")
        let row = try #require(PathCompletion.addingHistory(["/Users/me/Documents/Work"], to: ([], false), for: typed, includeHidden: false).rows.first)
        let parsed = try query(row.text)
        #expect(parsed.folder.path == "/Users/me/Documents/Work")
        #expect(parsed.typedName.isEmpty)
    }

    @Test func aFolderAlreadyListedKeepsItsPlainRow() throws {
        let listed = [row("Documents", in: "~/")]
        let result = try rows(["/Users/me/Documents"], "~/Doc", listed: listed)
        #expect(result.rows == listed)
    }

    @Test func whatIsAlreadyTypedIsNotOffered() throws {
        #expect(try rows(["/Users/me/Documents"], "~/Documents/").rows.isEmpty)
    }

    @Test func hiddenFoldersFollowTheHiddenItemsSetting() throws {
        let paths = ["/Users/me/Work/.secret/x"]
        #expect(try rows(paths, "~/Wo").rows.isEmpty)
        #expect(try rows(paths, "~/Wo", includeHidden: true).rows.count == 1)
        #expect(try rows(["/Users/me/.cache/x"], "~/.c").rows.count == 1)
    }

    @Test func aRowThatWouldMisleadIsNotOffered() throws {
        #expect(try rows(["/Users/me/a\u{202E}b"], "~/a").rows.isEmpty)
    }

    @Test func historyIsCappedAndNeverCrowdsOutTheRowLimit() throws {
        let paths = (0..<10).map { "/Users/me/Work/d\($0)" }
        let listed = (0..<PathCompletion.rowLimit).map { row("n\($0)", in: "~/Work/") }
        let result = try rows(paths, "~/Work/", listed: listed)
        #expect(result.rows.count == PathCompletion.rowLimit)
        #expect(result.rows.filter(\.isFromHistory).count == 4)
        #expect(result.hasMore)
    }

    @Test func aFullListIsUnchangedWithoutHistory() throws {
        let listed = [row("Documents", in: "~/")]
        let result = try rows([], "~/", listed: listed, hasMore: true)
        #expect(result.rows == listed)
        #expect(result.hasMore)
    }

    @Test func theRootFolderCompletes() throws {
        #expect(try rows(["/opt/tools"], "/op").rows.map(\.text) == ["/opt/tools/"])
    }
}
