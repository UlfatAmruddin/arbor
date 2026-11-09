import Foundation
import Testing
@testable import ArborCore

private func tab(_ name: String) -> SessionTab { SessionTab(location: "folder:/Users/me/\(name)") }

private func workspace(_ name: String = "Work", tabs: [SessionTab] = [tab("a")], active: Int = 0) throws -> Workspace {
    try #require(Workspace(name: name, tabs: tabs, activeTab: active))
}

private func json(_ workspaces: String, version: String = "\"version\":1,") -> Data {
    Data("{\(version)\"workspaces\":[\(workspaces)]}".utf8)
}

private let goodEntry = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Good","activeTab":0,"tabs":[{"location":"home"}]}"#

private func loaded(_ data: Data) -> (list: WorkspaceList, skipped: Int)? {
    if case .loaded(let list, let skipped) = WorkspaceFile.parse(data) { return (list, skipped) }
    return nil
}

private func reloaded(_ list: WorkspaceList) throws -> (list: WorkspaceList, skipped: Int) {
    let data = try #require(WorkspaceFile.encoded(list))
    return try #require(loaded(data))
}

/// A store over disposable files, with its queues.
private func makeStore(_ url: URL?) async -> WorkspaceStore {
    let store = WorkspaceStore(fileURL: url, queue: DispatchQueue(label: "test.workspaces"), callbackQueue: DispatchQueue(label: "test.workspaces.callbacks"))
    await withCheckedContinuation { continuation in store.loadIfNeeded { continuation.resume() } }
    return store
}

@Suite("Workspace names (FE-027)")
struct WorkspaceNameTests {
    @Test func removesControlAndBidiAndLineSeparators() {
        #expect(WorkspaceName.clean("a\u{0}b\u{7}c\u{202E}d\u{2066}e\u{2028}f\u{2029}g\nh") == "abcdefgh")
    }

    @Test func trimsAndRejectsEmpty() {
        #expect(WorkspaceName.clean("  Work  ") == "Work")
        #expect(WorkspaceName.clean("   ") == nil)
        #expect(WorkspaceName.clean("\u{202E}\u{0}") == nil)
    }

    @Test func capsLengthAndRetrims() throws {
        let capped = try #require(WorkspaceName.clean(String(repeating: "x", count: 79) + " " + String(repeating: "y", count: 200)))
        #expect(capped == String(repeating: "x", count: 79))
    }

    @Test func boundsScalarsOfOneCharacter() throws {
        let zalgo = "a" + String(repeating: "\u{301}", count: 100_000)
        let cleaned = try #require(WorkspaceName.clean(zalgo))
        #expect(cleaned.unicodeScalars.count <= WorkspaceName.scalarLimit)
    }

    @Test func percentStaysLiteral() { #expect(WorkspaceName.clean("100%@ %d") == "100%@ %d") }

    @Test func duplicatesIgnoreCase() {
        #expect(WorkspaceName.matches("Work", "wORK"))
        #expect(!WorkspaceName.matches("Work", "Works"))
    }
}

@Suite("Workspace values (FE-027)")
struct WorkspaceValueTests {
    @Test func dropsHistory() throws {
        let saved = try workspace(tabs: [SessionTab(location: "home", back: ["trash"], forward: ["network"])])
        #expect(saved.tabs[0].back.isEmpty && saved.tabs[0].forward.isEmpty)
    }

    @Test func capsTabsAndClampsActive() throws {
        let many = (0..<50).map { tab("t\($0)") }
        let saved = try workspace(tabs: many, active: 45)
        #expect(saved.tabs.count == SessionState.tabLimit)
        #expect(saved.activeTab == SessionState.tabLimit - 1)
        #expect(try workspace(tabs: [tab("a")], active: -3).activeTab == 0)
        #expect(try workspace(tabs: [tab("a")], active: .max).activeTab == 0)
    }

    @Test func refusesKeysTheFileWouldDropAndKeepsActiveOnItsTab() throws {
        let long = SessionTab(location: "search?q=" + String(repeating: "q", count: Workspace.keyLengthLimit))
        let nul = SessionTab(location: "folder:/a\0b")
        let saved = try workspace(tabs: [tab("a"), long, nul, tab("b")], active: 3)
        #expect(saved.tabs.map(\.location) == [tab("a").location, tab("b").location])
        #expect(saved.activeTab == 1)
    }

    @Test func needsANameAndATab() {
        #expect(Workspace(name: " ", tabs: [tab("a")], activeTab: 0) == nil)
        #expect(Workspace(name: "A", tabs: [], activeTab: 0) == nil)
        #expect(Workspace(name: "A", tabs: [SessionTab(location: "a\0")], activeTab: 0) == nil)
    }
}

@Suite("Workspace list edits (FE-027)")
struct WorkspaceListTests {
    @Test func saveReplaceKeepsIDAndSorts() throws {
        var list = WorkspaceList()
        let first = try list.save(name: "beta", tabs: [tab("a")], activeTab: 0).get()
        _ = try list.save(name: "Alpha", tabs: [tab("b")], activeTab: 0).get()
        let replaced = try list.save(name: "BETA", tabs: [tab("c")], activeTab: 0).get()
        #expect(replaced.id == first.id)
        #expect(replaced.tabs == [tab("c")])
        #expect(list.workspaces.map(\.name) == ["Alpha", "BETA"])
    }

    @Test func sortsNumbersLikeAPerson() throws {
        var list = WorkspaceList()
        for name in ["Set 10", "Set 9"] { _ = try list.save(name: name, tabs: [tab("a")], activeTab: 0).get() }
        #expect(list.workspaces.map(\.name) == ["Set 9", "Set 10"])
    }

    @Test func renameRules() throws {
        var list = WorkspaceList()
        let a = try list.save(name: "One", tabs: [tab("a")], activeTab: 0).get()
        let b = try list.save(name: "Two", tabs: [tab("b")], activeTab: 0).get()
        #expect(try list.rename(id: a.id, to: "ONE").get().id == a.id)
        #expect(list.workspace(id: a.id)?.name == "ONE")
        #expect(list.rename(id: b.id, to: "one") == .failure(.duplicateName))
        #expect(list.rename(id: b.id, to: "  ") == .failure(.invalidName))
        #expect(list.rename(id: "gone", to: "X") == .failure(.notFound))
        #expect(list.workspace(id: b.id)?.name == "Two")
    }

    @Test func deleteByIDOnly() throws {
        var list = WorkspaceList()
        let a = try list.save(name: "One", tabs: [tab("a")], activeTab: 0).get()
        #expect(list.delete(id: "gone") == .failure(.notFound))
        #expect(try list.delete(id: a.id).get() == a)
        #expect(list.workspaces.isEmpty)
    }

    @Test func limitAppliesToNewEntriesOnly() throws {
        var list = WorkspaceList()
        for n in 0..<WorkspaceList.limit { _ = try list.save(name: "W\(n)", tabs: [tab("a")], activeTab: 0).get() }
        #expect(list.save(name: "One more", tabs: [tab("a")], activeTab: 0) == .failure(.limitReached))
        #expect((try? list.save(name: "W5", tabs: [tab("b")], activeTab: 0).get()) != nil)
    }

    @Test func refusesATabSetWithNothingStorable() {
        var list = WorkspaceList()
        #expect(list.save(name: "A", tabs: [SessionTab(location: "a\0")], activeTab: 0) == .failure(.noStorableTabs))
    }
}

@Suite("Workspaces.json format (FE-027)")
struct WorkspaceFileFormatTests {
    @Test func outputIsStableAndMatchesTheDocumentedFormat() throws {
        var list = WorkspaceList()
        let saved = try list.save(name: "Work", tabs: [tab("Projects")], activeTab: 0).get()
        let text = try #require(WorkspaceFile.encoded(list).map { String(decoding: $0, as: UTF8.self) })
        let expected = #"{"version":1,"workspaces":[{"activeTab":0,"id":"\#(saved.id)","name":"Work","tabs":[{"ascending":true,"back":[],"foldersFirst":true,"forward":[],"location":"folder:/Users/me/Projects","sortKey":"name","viewMode":"details"}]}]}"#
        #expect(text == expected)
    }

    @Test func roundTrips() throws {
        var list = WorkspaceList()
        let tabs = [SessionTab(location: "home", viewMode: "list", sortKey: "size", ascending: false, foldersFirst: false), tab("a")]
        _ = try list.save(name: "One", tabs: tabs, activeTab: 1).get()
        _ = try list.save(name: "Two", tabs: [tab("b")], activeTab: 0).get()
        let parsed = try reloaded(list)
        #expect(parsed.list == list)
        #expect(parsed.skipped == 0)
    }

    @Test func keyAtTheLimitRoundTrips() throws {
        let key = "folder:/" + String(repeating: "k", count: Workspace.keyLengthLimit - 8)
        #expect(key.utf8.count == Workspace.keyLengthLimit)
        var list = WorkspaceList()
        _ = try list.save(name: "Long", tabs: [SessionTab(location: key)], activeTab: 0).get()
        let parsed = try reloaded(list)
        #expect(parsed.list.workspaces[0].tabs[0].location == key)
        #expect(parsed.skipped == 0)
    }

    @Test func fullListRoundTrips() throws {
        var list = WorkspaceList()
        let tabs = (0..<SessionState.tabLimit).map { tab("t\($0)") }
        for n in 0..<WorkspaceList.limit { _ = try list.save(name: "W\(n)", tabs: tabs, activeTab: 0).get() }
        let parsed = try reloaded(list)
        #expect(parsed.list == list)
        #expect(parsed.skipped == 0)
    }

    @Test func encodedRefusesAboveTheByteLimit() throws {
        var list = WorkspaceList()
        let key = "folder:/" + String(repeating: "k", count: 8000)
        let tabs = [SessionTab](repeating: SessionTab(location: key), count: SessionState.tabLimit)
        for n in 0..<20 { _ = try list.save(name: "W\(n)", tabs: tabs, activeTab: 0).get() }
        #expect(WorkspaceFile.encoded(list) == nil)
    }

    @Test func notJSONOrTheWrongShapeIsDamaged() {
        for text in ["garbage", "", "[]", "3", #"{"version":1}"#, #"{"workspaces":{}}"#, #"{"workspaces":3}"#] {
            #expect(WorkspaceFile.parse(Data(text.utf8)) == .damaged, "\(text)")
        }
    }

    @Test func newerVersionIsReportedWithWhatParses() throws {
        guard case .newerVersion(let list) = WorkspaceFile.parse(json(goodEntry + #","x""#, version: "\"version\":99,")) else {
            Issue.record("not newer"); return
        }
        #expect(list.workspaces.map(\.name) == ["Good"])
    }

    @Test(arguments: [#"{"version":2,"sets":[1]}"#, #"{"sets":[],"version":2}"#, #"{"version":2,"workspaces":{"a":1}}"#, #"{"version":2,"workspaces":null}"#])
    func aNewerVersionWithAnotherShapeIsNewerNotDamaged(_ text: String) {
        #expect(WorkspaceFile.parse(Data(text.utf8)) == .newerVersion(WorkspaceList()))
    }

    @Test func unknownKeysAreIgnored() throws {
        let entry = #"{"future":{"a":1},"name":"A","activeTab":0,"tabs":[{"location":"home","extra":[1]}]}"#
        let data = Data(#"{"version":1,"more":true,"workspaces":[\#(entry)]}"#.utf8)
        let parsed = try #require(loaded(data))
        #expect(parsed.list.workspaces.map(\.name) == ["A"])
        #expect(parsed.skipped == 0)
    }

    @Test func badElementsAreSkippedAndCountedAndSiblingsSurvive() throws {
        let tabs = #"[{"location":"home"},7,{"viewMode":"list"},{"location":"trash"}]"#
        let data = json(#"3,{"name":"NoTabs"},\#(goodEntry),{"name":"Mixed","activeTab":0,"tabs":\#(tabs)}"#)
        let parsed = try #require(loaded(data))
        #expect(parsed.list.workspaces.map(\.name) == ["Good", "Mixed"])
        #expect(parsed.list.workspaces[1].tabs.map(\.location) == ["home", "trash"])
        #expect(parsed.skipped == 4)
    }

    @Test func aDroppedActiveTabLandsOnItsRightNeighbour() throws {
        let data = json(#"{"name":"A","activeTab":1,"tabs":[{"location":"home"},7,{"location":"trash"}]}"#)
        let parsed = try #require(loaded(data))
        #expect(parsed.list.workspaces[0].tabs[parsed.list.workspaces[0].activeTab].location == "trash")
    }

    @Test func missingOptionalTabFieldsTakeDefaults() throws {
        let parsed = try #require(loaded(json(#"{"name":"A","tabs":[{"location":"home"}]}"#)))
        #expect(parsed.list.workspaces[0].tabs == [SessionTab(location: "home")])
        #expect(parsed.list.workspaces[0].activeTab == 0)
    }

    @Test func wrongTypedOptionalFieldsTakeDefaults() throws {
        let tabText = #"{"location":"home","viewMode":3,"sortKey":false,"ascending":"no","foldersFirst":[],"back":7,"forward":{}}"#
        let parsed = try #require(loaded(json(#"{"name":"A","id":5,"activeTab":"x","tabs":[\#(tabText)]}"#)))
        #expect(parsed.list.workspaces[0].tabs == [SessionTab(location: "home")])
        #expect(parsed.skipped == 0)
    }

    @Test func aMissingOrMalformedVersionIsVersionOne() throws {
        #expect(loaded(json(goodEntry, version: "")) != nil)
        #expect(loaded(json(goodEntry, version: "\"version\":\"two\",")) != nil)
        #expect(loaded(json(goodEntry, version: "\"version\":1.5,")) != nil)
    }

    @Test(arguments: ["-7", "99999", "1e30", "0.5", "\"x\"", "null"])
    func activeTabValuesCannotCrash(_ value: String) throws {
        let parsed = try #require(loaded(json(#"{"name":"A","activeTab":\#(value),"tabs":[{"location":"home"},{"location":"trash"}]}"#)))
        #expect(parsed.list.workspaces[0].tabs.indices.contains(parsed.list.workspaces[0].activeTab))
    }

    @Test func overLongAndNulKeysAreSkipped() throws {
        let long = String(repeating: "q", count: Workspace.keyLengthLimit + 1)
        let parsed = try #require(loaded(json(#"{"name":"A","tabs":[{"location":"\#(long)"},{"location":"a\u0000b"},{"location":"home"}]}"#)))
        #expect(parsed.list.workspaces[0].tabs.map(\.location) == ["home"])
        #expect(parsed.skipped == 2)
    }

    @Test func aNameIsCleanedOrItsEntrySkipped() throws {
        let longName = String(repeating: "n", count: 500)
        let parsed = try #require(loaded(json(#"{"name":"A‮b","tabs":[{"location":"home"}]},{"name":"\#(longName)","tabs":[{"location":"home"}]},{"name":" ","tabs":[{"location":"home"}]}"#)))
        #expect(parsed.list.workspaces.map(\.name.count) == [2, WorkspaceName.characterLimit])
        #expect(parsed.list.workspaces[0].name == "Ab")
        #expect(parsed.skipped == 1)
    }

    @Test func badOrRepeatedIDsGetNewOnes() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let parsed = try #require(loaded(json(#"{"id":"\#(id)","name":"A","tabs":[{"location":"home"}]},{"id":"\#(id)","name":"B","tabs":[{"location":"home"}]},{"id":"nope","name":"C","tabs":[{"location":"home"}]}"#)))
        let ids = parsed.list.workspaces.map(\.id)
        #expect(Set(ids).count == 3)
        #expect(ids[0] == id)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
    }

    @Test func repeatNamesAndEntriesOverTheLimitCountAsSkipped() throws {
        let repeated = #"{"name":"a","tabs":[{"location":"home"}]},{"name":"A","tabs":[{"location":"trash"}]}"#
        let first = try #require(loaded(json(repeated)))
        #expect(first.list.workspaces.map(\.tabs[0].location) == ["home"])
        #expect(first.skipped == 1)

        let entries = (0...WorkspaceList.limit).map { #"{"name":"W\#($0)","tabs":[{"location":"home"}]}"# }
        let second = try #require(loaded(json(entries.joined(separator: ","))))
        #expect(second.list.workspaces.count == WorkspaceList.limit)
        #expect(second.skipped == 1)
    }

    @Test func tabsOverTheLimitCountAsSkipped() throws {
        let tabs = Array(repeating: #"{"location":"home"}"#, count: SessionState.tabLimit + 2).joined(separator: ",")
        let parsed = try #require(loaded(json(#"{"name":"A","tabs":[\#(tabs)]}"#)))
        #expect(parsed.list.workspaces[0].tabs.count == SessionState.tabLimit)
        #expect(parsed.skipped == 2)
    }

    @Test func historyInTheFileIsDiscarded() throws {
        let parsed = try #require(loaded(json(#"{"name":"A","tabs":[{"location":"home","back":["trash"],"forward":["network"]}]}"#)))
        #expect(parsed.list.workspaces[0].tabs[0].back.isEmpty)
        #expect(parsed.list.workspaces[0].tabs[0].forward.isEmpty)
        #expect(parsed.skipped == 0)
    }

    @Test func unknownLocationKeysStayInTheFile() throws {
        var list = try #require(loaded(json(#"{"name":"A","tabs":[{"location":"hologram:/x"}]}"#))).list
        let id = list.workspaces[0].id
        _ = try list.rename(id: id, to: "B").get()
        let text = String(decoding: try #require(WorkspaceFile.encoded(list)), as: UTF8.self)
        #expect(text.contains("hologram:/x"))
    }
}

@Suite("Session tab decoding (FE-024, FE-027)")
struct SessionTabDecodingTests {
    @Test func aSessionFileDecodesAsBefore() throws {
        let tab = SessionTab(location: "folder:/x", back: ["home"], forward: ["trash"], viewMode: "list", sortKey: "size", ascending: false, foldersFirst: false)
        let state = SessionState(windows: [SessionWindow(frame: CGRect(x: 1, y: 2, width: 300, height: 400), tabs: [tab], activeTab: 0)])
        let data = try #require(state.encoded())
        #expect(SessionState.decode(data) == state)
    }

    @Test func onlyLocationIsRequired() throws {
        let decoded = try JSONDecoder().decode(SessionTab.self, from: Data(#"{"location":"home","ascending":"x"}"#.utf8))
        #expect(decoded == SessionTab(location: "home"))
        #expect((try? JSONDecoder().decode(SessionTab.self, from: Data(#"{"viewMode":"list"}"#.utf8))) == nil)
    }

    @Test func unknownSortAndViewNamesCannotCrash() {
        let odd = SessionTab(location: "home", viewMode: "hologram", sortKey: "weight")
        _ = odd.sortOrder
        #expect(odd.history() != nil)
    }
}

@Suite("Loading Workspaces.json (FE-027)")
struct WorkspaceFileLoadTests {
    private func paths() throws -> (fixture: Fixture, file: URL, copy: URL) {
        let fixture = try Fixture()
        return (fixture, fixture.root.appendingPathComponent("Workspaces.json"),
                fixture.root.appendingPathComponent(WorkspaceFile.damagedCopyName))
    }

    @Test func absentIsAnEmptyWritableList() throws {
        let p = try paths()
        #expect(WorkspaceFile.load(at: p.file) == WorkspaceLoad())
    }

    @Test func aMissingFolderIsAbsentToo() throws {
        let p = try paths()
        #expect(WorkspaceFile.load(at: p.fixture.root.appendingPathComponent("no/Workspaces.json")) == WorkspaceLoad())
    }

    @Test func aDanglingSymlinkIsUnreadableNotAbsent() throws {
        let p = try paths()
        try FileManager.default.createSymbolicLink(atPath: p.file.path, withDestinationPath: "/nonexistent/target")
        #expect(WorkspaceFile.load(at: p.file) == WorkspaceLoad(issue: .unreadable))
    }

    @Test func aSymlinkToARealFileIsUnreadableAndUntouched() throws {
        let p = try paths()
        let target = try p.fixture.file("target.json", String(decoding: json(goodEntry), as: UTF8.self))
        try FileManager.default.createSymbolicLink(atPath: p.file.path, withDestinationPath: target.path)
        #expect(WorkspaceFile.load(at: p.file) == WorkspaceLoad(issue: .unreadable))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: p.file.path)) == target.path)
    }

    @Test func aFIFOIsUnreadableWithoutBlocking() throws {
        let p = try paths()
        #expect(mkfifo(p.file.path, 0o600) == 0)
        #expect(WorkspaceFile.load(at: p.file) == WorkspaceLoad(issue: .unreadable))
    }

    @Test func aDirectoryIsUnreadable() throws {
        let p = try paths()
        try FileManager.default.createDirectory(at: p.file, withIntermediateDirectories: false)
        #expect(WorkspaceFile.load(at: p.file) == WorkspaceLoad(issue: .unreadable))
    }

    @Test func damagedMovesAsideWithOneRename() throws {
        let p = try paths()
        try Data("garbage".utf8).write(to: p.file)
        try Data("older copy".utf8).write(to: p.copy)
        #expect(WorkspaceFile.load(at: p.file) == WorkspaceLoad(issue: .damaged(copyKept: true)))
        #expect(!FileManager.default.fileExists(atPath: p.file.path))
        #expect(try Data(contentsOf: p.copy) == Data("garbage".utf8))
    }

    @Test func anEmptyFileIsMovedAside() throws {
        let p = try paths()
        try Data().write(to: p.file)
        let load = WorkspaceFile.load(at: p.file)
        #expect(load == WorkspaceLoad(issue: .damaged(copyKept: true)))
        #expect(load.issue?.isReadOnly == false)
        #expect(!FileManager.default.fileExists(atPath: p.file.path))
        #expect(FileManager.default.fileExists(atPath: p.copy.path))
    }

    @Test func overTheCapStaysInPlaceReadOnly() throws {
        let p = try paths()
        let big = Data(count: WorkspaceFile.byteLimit + 1)
        try big.write(to: p.file)
        let load = WorkspaceFile.load(at: p.file)
        #expect(load == WorkspaceLoad(issue: .unreadable))
        #expect(load.issue?.isReadOnly == true)
        #expect(try Data(contentsOf: p.file).count == big.count)
        #expect(!FileManager.default.fileExists(atPath: p.copy.path))
    }

    @Test func exactlyAtTheCapIsStillParsed() throws {
        let p = try paths()
        let body = json(goodEntry)
        try (body + Data(repeating: 0x20, count: WorkspaceFile.byteLimit - body.count)).write(to: p.file)
        #expect(WorkspaceFile.load(at: p.file).list.workspaces.map(\.name) == ["Good"])
    }

    @Test func damagedRenameReplacesASymlinkInsteadOfFollowingIt() throws {
        let p = try paths()
        let victim = try p.fixture.file("victim.txt", "keep me")
        try FileManager.default.createSymbolicLink(atPath: p.copy.path, withDestinationPath: victim.path)
        try Data("garbage".utf8).write(to: p.file)
        #expect(WorkspaceFile.load(at: p.file).issue == .damaged(copyKept: true))
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: p.copy.path)) == nil)
    }

    @Test func damagedThatCannotMoveIsReadOnlyAndUntouched() throws {
        let p = try paths()
        try Data("garbage".utf8).write(to: p.file)
        try p.fixture.file("\(WorkspaceFile.damagedCopyName)/occupied", "x")
        let load = WorkspaceFile.load(at: p.file)
        #expect(load.issue == .damaged(copyKept: false))
        #expect(load.issue?.isReadOnly == true)
        #expect(try Data(contentsOf: p.file) == Data("garbage".utf8))
    }

    @Test func partialLoadCopiesTheOriginalBytes() throws {
        let p = try paths()
        let original = json(goodEntry + ",3")
        try original.write(to: p.file)
        let load = WorkspaceFile.load(at: p.file)
        #expect(load.issue == .partial(skipped: 1, copyKept: true))
        #expect(load.issue?.isReadOnly == false)
        #expect(try Data(contentsOf: p.copy) == original)
        #expect(try Data(contentsOf: p.file) == original)
    }

    @Test func partialLoadThatCannotCopyIsReadOnly() throws {
        let p = try paths()
        try json(goodEntry + ",3").write(to: p.file)
        try p.fixture.file("\(WorkspaceFile.damagedCopyName)/occupied", "x")
        let load = WorkspaceFile.load(at: p.file)
        #expect(load.issue == .partial(skipped: 1, copyKept: false))
        #expect(load.issue?.isReadOnly == true)
        #expect(load.list.workspaces.count == 1)
    }

    @Test func aCleanFileHasNoIssueAndMakesNoCopy() throws {
        let p = try paths()
        try json(goodEntry).write(to: p.file)
        let load = WorkspaceFile.load(at: p.file)
        #expect(load.issue == nil)
        #expect(load.list.workspaces.map(\.name) == ["Good"])
        #expect(!FileManager.default.fileExists(atPath: p.copy.path))
    }

    @Test func aNewerVersionWithAnotherShapeStaysInPlaceReadOnly() throws {
        let p = try paths()
        let original = Data(#"{"version":2,"sets":[{"name":"Future"}]}"#.utf8)
        try original.write(to: p.file)
        let load = WorkspaceFile.load(at: p.file)
        #expect(load == WorkspaceLoad(issue: .newerVersion))
        #expect(load.issue?.isReadOnly == true)
        #expect(try Data(contentsOf: p.file) == original)
        #expect(!FileManager.default.fileExists(atPath: p.copy.path))
    }

    @Test func newerVersionIsReadOnly() throws {
        let p = try paths()
        try json(goodEntry, version: "\"version\":99,").write(to: p.file)
        let load = WorkspaceFile.load(at: p.file)
        #expect(load.issue == .newerVersion)
        #expect(load.issue?.isReadOnly == true)
        #expect(load.list.workspaces.count == 1)
    }
}

@Suite("Workspace store (FE-027)")
struct WorkspaceStoreTests {
    @Test func savesAndReloads() async throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("state/Workspaces.json")
        let store = await makeStore(url)
        let saved = try store.save(name: "Work", tabs: [tab("a"), tab("b")], activeTab: 1).get()
        store.flush()
        let again = await makeStore(url)
        #expect(again.list.workspace(id: saved.id) == saved)
        #expect(again.issue == nil)
    }

    @Test func refusesEditsBeforeTheLoadFinishes() {
        let store = WorkspaceStore(fileURL: nil, queue: DispatchQueue(label: "test.unloaded"))
        #expect(store.save(name: "A", tabs: [tab("a")], activeTab: 0) == .failure(.readOnly))
    }

    @Test func aNilFileStaysInMemory() async throws {
        let store = await makeStore(nil)
        #expect(store.canEdit)
        _ = try store.save(name: "A", tabs: [tab("a")], activeTab: 0).get()
        #expect(store.list.workspaces.count == 1)
    }

    @Test func aNewerFileIsNeverWrittenAndEveryEditIsRefused() async throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("Workspaces.json")
        let original = json(goodEntry, version: "\"version\":99,")
        try original.write(to: url)
        let store = await makeStore(url)
        let id = try #require(store.list.workspaces.first?.id)
        #expect(store.save(name: "New", tabs: [tab("a")], activeTab: 0) == .failure(.readOnly))
        #expect(store.rename(id: id, to: "Other") == .failure(.readOnly))
        #expect(store.delete(id: id) == .failure(.readOnly))
        store.flush()
        #expect(try Data(contentsOf: url) == original)
        #expect(store.list.workspaces.map(\.name) == ["Good"])
    }

    @Test func aPartialLoadKeepsItsCopyAfterTheNextSave() async throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("Workspaces.json")
        let original = json(goodEntry + ",3")
        try original.write(to: url)
        let store = await makeStore(url)
        #expect(store.canEdit)
        _ = try store.save(name: "New", tabs: [tab("a")], activeTab: 0).get()
        store.flush()
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(WorkspaceFile.damagedCopyName)) == original)
        #expect(try Data(contentsOf: url) != original)
    }

    @Test func anEditThatWouldOverflowTheFileChangesNothing() async throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("Workspaces.json")
        let store = await makeStore(url)
        let key = "folder:/" + String(repeating: "k", count: 8000)
        let tabs = [SessionTab](repeating: SessionTab(location: key), count: SessionState.tabLimit)
        var refused = false
        for n in 0..<WorkspaceList.limit where !refused {
            let before = store.list
            if case .failure(let error) = store.save(name: "W\(n)", tabs: tabs, activeTab: 0) {
                #expect(error == .tooLarge)
                #expect(store.list == before)
                refused = true
            }
        }
        #expect(refused)
        store.flush()
        // The largest list that was accepted still reads back whole.
        let again = await makeStore(url)
        #expect(again.issue == nil)
        #expect(again.list == store.list)
    }

    @Test func aFailedWriteKeepsMemoryAndReports() async throws {
        let fixture = try Fixture()
        let folder = try fixture.folder("state")
        let store = await makeStore(folder.appendingPathComponent("Workspaces.json"))
        try FileManager.default.removeItem(at: folder)
        try fixture.file("state", "a file where the folder was")
        await withCheckedContinuation { continuation in
            store.onWriteFailure = { continuation.resume() }
            _ = store.save(name: "A", tabs: [tab("a")], activeTab: 0)
        }
        #expect(store.list.workspaces.map(\.name) == ["A"])
    }
}

@Suite("Opening a workspace (FE-027)")
struct WorkspaceOpenPlanTests {
    private let folders = [SessionTab(location: "folder:/m/a"), SessionTab(location: "folder:/m/b"), SessionTab(location: "folder:/m/c")]

    private func plan(_ tabs: [SessionTab], active: Int = 0, gone: Set<String> = []) throws -> WorkspaceOpenPlan {
        WorkspaceOpenPlan(workspace: try workspace(tabs: tabs, active: active)) { requirement in
            switch requirement {
            case .directory(let path), .file(let path): return !gone.contains(path)
            }
        }
    }

    @Test func allPresent() throws {
        let result = try plan(folders, active: 2)
        #expect(result.tabs.map(\.saved) == folders)
        #expect(result.activeIndex == 2)
        #expect(result.unavailableNames.isEmpty && result.unreadableCount == 0)
    }

    @Test func someMissingAreNamed() throws {
        let result = try plan(folders, gone: ["/m/b"])
        #expect(result.tabs.map(\.saved.location) == ["folder:/m/a", "folder:/m/c"])
        #expect(result.unavailableNames == ["b"])
    }

    @Test func aSkippedActiveTabMovesRightThenToTheLast() throws {
        #expect(try plan(folders, active: 1, gone: ["/m/b"]).activeIndex == 1)
        #expect(try plan(folders, active: 2, gone: ["/m/c"]).activeIndex == 1)
        #expect(try plan(folders, active: 2, gone: ["/m/a"]).activeIndex == 1)
    }

    @Test func allMissingPlansNoTabs() throws {
        let result = try plan(folders, active: 1, gone: ["/m/a", "/m/b", "/m/c"])
        #expect(result.tabs.isEmpty)
        #expect(result.activeIndex == 0)
        #expect(result.unavailableNames.count == 3)
    }

    @Test func unreadableKeysAreCounted() throws {
        let result = try plan([SessionTab(location: "hologram"), SessionTab(location: "home")])
        #expect(result.unreadableCount == 1)
        #expect(result.tabs.map(\.saved.location) == ["home"])
    }

    @Test func tabsCarryTheirParsedLocation() throws {
        let result = try plan([SessionTab(location: "home"), SessionTab(location: "folder:/m/a")])
        #expect(result.tabs.map(\.location) == [.home, .folder(URL(fileURLWithPath: "/m/a"))])
    }

    @Test func onlyUnreadableKeysPlanNoTabsAndNameNothing() throws {
        let result = try plan([SessionTab(location: "hologram")])
        #expect(result.tabs.isEmpty)
        #expect(result.unavailableNames.isEmpty)
        #expect(result.unreadableCount == 1)
    }

    @Test func virtualAndSearchLocationsAreNeverChecked() throws {
        let tabs = ["home", "thismac", "gallery", "network", "trash", Location.search(SearchRequest(query: "x", scope: URL(fileURLWithPath: "/m/gone"))).key, Location.library("Docs").key]
        var asked = 0
        let result = WorkspaceOpenPlan(workspace: try workspace(tabs: tabs.map { SessionTab(location: $0) })) { _ in
            asked += 1
            return false
        }
        #expect(asked == 0)
        #expect(result.tabs.count == tabs.count)
    }

    @Test func archivesNeedTheirFile() throws {
        let key = Location.archive(URL(fileURLWithPath: "/m/a.zip"), innerPath: "x/y").key
        var seen: [WorkspaceOpenPlan.Requirement] = []
        let result = WorkspaceOpenPlan(workspace: try workspace(tabs: [SessionTab(location: key)])) { seen.append($0); return false }
        #expect(seen == [.file("/m/a.zip")])
        #expect(result.unavailableNames == ["a.zip"])
    }

    @Test func aFolderReplacedByAFileIsUnavailable() throws {
        let fixture = try Fixture()
        let file = try fixture.file("was-a-folder")
        let folder = try fixture.folder("still-a-folder")
        #expect(!WorkspaceOpenPlan.existsOnDisk(.directory(file.path)))
        #expect(WorkspaceOpenPlan.existsOnDisk(.file(file.path)))
        #expect(WorkspaceOpenPlan.existsOnDisk(.directory(folder.path)))
        #expect(!WorkspaceOpenPlan.existsOnDisk(.file(folder.path)))
        #expect(!WorkspaceOpenPlan.existsOnDisk(.directory(file.path + "-nothing")))
    }

    @Test func aHostileFolderNameIsCleanedForTheAlert() throws {
        let result = try plan([SessionTab(location: "folder:/m/a\u{202E}b")], gone: ["/m/a\u{202E}b"])
        #expect(result.unavailableNames == ["ab"])
    }
}

@Suite("Workspace open deadline (FE-027)", .serialized)
@MainActor
struct WorkspaceOpenCheckTests {
    /// The plan, or nil on a timeout.
    private func outcome(of check: WorkspaceOpenCheck, _ workspace: Workspace, afterStarting: () -> Void = {}) async -> WorkspaceOpenPlan? {
        await withCheckedContinuation { continuation in
            check.run(workspace) { outcome in
                if case .finished(let plan) = outcome { continuation.resume(returning: plan) } else { continuation.resume(returning: nil) }
            }
            afterStarting()
        }
    }

    @Test func aHungCheckTimesOutAndARetryJoinsTheSameJob() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = NetworkCallCounter()
        let check = WorkspaceOpenCheck(deadline: 0.5) { _ in
            calls.bump()
            gate.wait()
            return true
        }
        let saved = try workspace(tabs: [tab("slow")])
        #expect(await outcome(of: check, saved) == nil)
        #expect(!check.isRunning)
        let plan = await outcome(of: check, saved) { gate.signal() }
        #expect(plan?.tabs.count == 1)
        #expect(calls.value == 1)
    }

    @Test func parsingHappensInsideTheDeadline() async throws {
        let check = WorkspaceOpenCheck(deadline: 5) { _ in
            !Thread.isMainThread
        }
        let plan = await outcome(of: check, try workspace(tabs: [tab("a")]))
        #expect(plan?.tabs.count == 1)
    }

    @Test func aNewerOpenCancelsTheOlderAnswer() async throws {
        let gate = DispatchSemaphore(value: 0)
        let check = WorkspaceOpenCheck(deadline: 5) { requirement in
            if requirement == .directory("/Users/me/slow") { gate.wait() }
            return true
        }
        var stale = false
        check.run(try workspace("Old", tabs: [tab("slow")])) { _ in stale = true }
        let plan = await outcome(of: check, try workspace("New", tabs: [tab("fast")]))
        #expect(plan?.tabs.map(\.saved) == [tab("fast")])
        gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!stale)
    }

    @Test func aFinishedCheckIsNoLongerRunning() async throws {
        let check = WorkspaceOpenCheck(deadline: 5) { _ in true }
        _ = await outcome(of: check, try workspace())
        #expect(!check.isRunning)
    }
}
