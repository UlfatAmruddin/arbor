import Foundation
import Testing
@testable import ArborCore

private let home = URL(fileURLWithPath: "/Users/me")

private func catalog(_ json: String) -> LibraryCatalog { LibraryCatalog(data: Data(json.utf8), home: home) }

private func names(_ catalog: LibraryCatalog) -> [String] { catalog.libraries.map(\.name) }

private func empty() -> LibraryCatalog { catalog("[]") }

@Suite("Library names (FE-076)")
struct LibraryNameTests {
    @Test func namesAreTrimmedAndComposed() throws {
        #expect(try LibraryLogic.cleanedName("  Work \n") == "Work")
        let decomposed = "Cafe\u{0301}"
        #expect(try LibraryLogic.cleanedName(decomposed).unicodeScalars.count == 4)
    }

    @Test func theRootNameIsReservedInAnyCaseOrWidth() {
        for name in ["Libraries", "libraries", "LIBRARIES", "Ｌibraries"] {
            #expect(throws: LibraryEditError.reserved) { try LibraryLogic.cleanedName(name) }
        }
    }

    @Test func unsafeNamesAreRefused() {
        for name in ["", "   ", ".", "..", "a/b", "a\u{0}b", "a\u{7}b", "a\u{9B}b", "safe\u{202E}gpj.exe", "a\u{2066}b"] {
            #expect(throws: LibraryEditError.self) { try LibraryLogic.cleanedName(name) }
        }
    }

    @Test func directionMarksLineBreaksAndInvisibleCharactersAreRefused() {
        for mark in ["\u{200E}", "\u{200F}", "\u{061C}", "\u{2028}", "\u{2029}", "\u{200B}", "\u{FEFF}", "\u{00AD}", "\u{2060}"] {
            #expect(throws: LibraryEditError.self) { try LibraryLogic.cleanedName("Docu\(mark)ments") }
        }
    }

    @Test func aFlagBuiltFromTagCharactersStaysValid() throws {
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} Team"
        #expect(try LibraryLogic.cleanedName(england) == england)
    }

    @Test func aMessageShortensALongNameButNotAShortOne() throws {
        let long = String(repeating: "a", count: LibraryLogic.maxNameLength)
        let message = try #require(LibraryEditError.taken(long).errorDescription)
        #expect(message.contains("…”"))
        #expect(message.count < 80)
        #expect(LibraryEditError.taken("Work").errorDescription == "There's already a library named “Work”.")
    }

    @Test func lengthIsCapped() throws {
        #expect(try LibraryLogic.cleanedName(String(repeating: "a", count: LibraryLogic.maxNameLength)).count == LibraryLogic.maxNameLength)
        #expect(throws: LibraryEditError.self) { try LibraryLogic.cleanedName(String(repeating: "a", count: LibraryLogic.maxNameLength + 1)) }
        #expect(throws: LibraryEditError.self) { try LibraryLogic.cleanedName(String(repeating: "é", count: 119) + String(repeating: "😀", count: 60)) }
    }

    @Test func emojiWithJoinersStaysValid() throws {
        #expect(try LibraryLogic.cleanedName("👩‍💻 Work") == "👩‍💻 Work")
    }
}

@Suite("Library catalog (FE-076, FE-239)")
struct LibraryCatalogEditTests {
    @Test func nilDataGivesTheDefaults() {
        #expect(names(LibraryCatalog(data: nil, home: home)) == LibraryLogic.defaultNames)
    }

    @Test func createUsesCleanNamesAndRefusesTakenOnes() throws {
        var list = empty()
        let stored = try list.create(named: " Work ")
        #expect(stored == "Work")
        #expect(throws: LibraryEditError.taken("work")) { try list.create(named: "work") }
        #expect(throws: LibraryEditError.taken("ＷＯＲＫ")) { try list.create(named: "ＷＯＲＫ") }
        #expect(names(list) == ["Work"])
    }

    @Test func aNewLibraryIsGeneralAndEmpty() throws {
        var list = empty()
        try list.create(named: "Work")
        #expect(list.definition("Work") == LibraryDefinition(name: "Work", folders: [], template: .generalItems))
    }

    @Test func theDefaultNameCountsUp() throws {
        var list = empty()
        #expect(list.nextAvailableName(base: "New Library") == "New Library")
        try list.create(named: "New Library")
        #expect(list.nextAvailableName(base: "New Library") == "New Library (2)")
        try list.create(named: "new library (2)")
        #expect(list.nextAvailableName(base: "New Library") == "New Library (3)")
    }

    @Test func renameKeepsEverythingButTheName() throws {
        var list = empty()
        try list.create(named: "Work")
        let updated = list.update(LibraryDefinition(name: "Work", folders: [URL(fileURLWithPath: "/a")], template: .music))
        #expect(updated)
        let renamed = try list.rename("Work", to: "Job")
        #expect(renamed == "Job")
        #expect(list.definition("Work") == nil)
        #expect(list.definition("Job")?.folders == ["/a"])
        #expect(list.definition("Job")?.template == .music)
    }

    @Test func renamingOnlyTheCaseIsAllowed() throws {
        var list = empty()
        try list.create(named: "work")
        let renamed = try list.rename("work", to: "WORK")
        #expect(renamed == "WORK")
    }

    @Test func renameRefusesOtherLibrariesNames() throws {
        var list = empty()
        try list.create(named: "A")
        try list.create(named: "B")
        #expect(throws: LibraryEditError.taken("a")) { try list.rename("B", to: "a") }
        #expect(throws: LibraryEditError.notFound("C")) { try list.rename("C", to: "D") }
        #expect(throws: LibraryEditError.reserved) { try list.rename("B", to: "libraries") }
    }

    @Test func updateNeverBringsBackADeletedLibrary() {
        var list = LibraryCatalog(data: nil, home: home)
        let documents = list.definition("Documents")!
        let deleted = list.delete("Documents")
        #expect(deleted)
        let revived = list.update(documents)
        #expect(!revived)
        #expect(list.definition("Documents") == nil)
        let deletedAgain = list.delete("Documents")
        #expect(!deletedAgain)
    }

    @Test func deletingTheLastLibraryStaysEmptyAfterSaving() throws {
        var list = LibraryCatalog(data: nil, home: home)
        for name in names(list) { list.delete(name) }
        let reloaded = LibraryCatalog(data: try list.encoded(), home: home)
        #expect(reloaded.libraries.isEmpty)
    }

    @Test func restoreAddsOnlyWhatIsMissing() throws {
        var list = LibraryCatalog(data: nil, home: home)
        list.delete("Music")
        let edited = LibraryDefinition(name: "Pictures", folders: [URL(fileURLWithPath: "/elsewhere")])
        list.update(edited)
        let restored = list.restoreDefaults(home: home)
        #expect(restored == 1)
        #expect(list.definition("Music")?.folders == ["/Users/me/Music"])
        #expect(list.definition("Pictures") == edited)
        let restoredAgain = list.restoreDefaults(home: home)
        #expect(restoredAgain == 0)
    }

    @Test func aCustomLibraryNamedLikeADefaultBlocksItsRestore() throws {
        var list = empty()
        try list.create(named: "documents")
        let restored = list.restoreDefaults(home: home)
        #expect(restored == 3)
        #expect(list.definition("Documents") == nil)
    }

    @Test func theLibraryCountIsCapped() throws {
        var list = empty()
        for i in 0..<LibraryCatalog.maxLibraries { try list.create(named: "L\(i)") }
        #expect(throws: LibraryEditError.tooMany) { try list.create(named: "One more") }
    }

    @Test func aListThatCouldNotBeReadBackIsRefused() throws {
        var list = empty()
        // Each library holds 64 long paths: well over the read limit in total.
        let longPath = "/" + String(repeating: "p", count: 900)
        for i in 0..<30 {
            try list.create(named: "L\(i)")
            let folders = (0..<LibraryLogic.maxFolders).map { URL(fileURLWithPath: "\(longPath)/\($0)") }
            list.update(LibraryDefinition(name: "L\(i)", folders: folders))
        }
        #expect(throws: LibraryEditError.tooMany) { try list.encoded() }
    }

    @Test func definitionsNeverExceedTheFolderCap() {
        let many = (0..<(LibraryLogic.maxFolders + 5)).map { URL(fileURLWithPath: "/f\($0)") }
        var library = LibraryDefinition(name: "L", folders: many)
        #expect(library.folders.count == LibraryLogic.maxFolders)
        let overflow = library.add(URL(fileURLWithPath: "/more"))
        #expect(overflow == .full)
    }

    @Test func folderEditsKeepTheTemplate() {
        var library = LibraryDefinition(name: "Music", folders: [URL(fileURLWithPath: "/a")])
        library.add(URL(fileURLWithPath: "/b"))
        library.remove(URL(fileURLWithPath: "/a"))
        #expect(library.folders == ["/b"])
        #expect(library.template == .music)
    }

    @Test func aFolderOutsideTheListCannotBeTheSaveLocation() {
        var library = LibraryDefinition(name: "L", folders: [URL(fileURLWithPath: "/a")])
        let accepted = library.setSaveLocation(URL(fileURLWithPath: "/gone"))
        #expect(!accepted)
        #expect(library.saveLocation == "/a")
    }

    @Test func movingAFolderKeepsTheSaveLocationAndStopsAtTheEnds() {
        var library = LibraryDefinition(name: "L", folders: ["/a", "/b", "/c"].map { URL(fileURLWithPath: $0) })
        library.move(URL(fileURLWithPath: "/c"), by: -1)
        #expect(library.folders == ["/a", "/c", "/b"])
        #expect(library.saveLocation == "/a")
        library.move(URL(fileURLWithPath: "/a"), by: -1)
        #expect(library.folders == ["/a", "/c", "/b"])
        library.move(URL(fileURLWithPath: "/b"), by: 5)
        #expect(library.folders == ["/a", "/c", "/b"])
    }

    /// FE-239: nothing a library edit does can reach the member folders.
    @Test func editingALibraryLeavesItsFoldersUntouched() throws {
        let fx = try Fixture()
        let folder = try fx.folder("Member")
        try fx.file("Member/kept.txt", "precious")
        var list = empty()
        try list.create(named: "Work")
        list.update(LibraryDefinition(name: "Work", folders: [folder]))
        var library = list.definition("Work")!
        library.remove(folder)
        list.update(library)
        list.delete("Work")
        #expect(fx.read("Member/kept.txt") == "precious")
    }

    @Test func removingTheSaveLocationPicksTheNextFolder() {
        var library = LibraryDefinition(name: "L", folders: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])
        library.remove(URL(fileURLWithPath: "/a"))
        #expect(library.saveLocation == "/b")
        #expect(LibraryLogic.resolveSaveLocation(library) { _ in true } == .folder(URL(fileURLWithPath: "/b"), isFallback: false))
    }
}

@Suite("Library status text (FE-076, FE-238)")
struct LibraryStatusTextTests {
    private let usedFolder = SaveLocationResolution.folder(URL(fileURLWithPath: "/Users/me/A"), isFallback: true)
    private let chosenFolder = SaveLocationResolution.folder(URL(fileURLWithPath: "/Users/me/A"), isFallback: false)
    private let gone = URL(fileURLWithPath: "/Volumes/Gone")

    @Test func aHealthyLibrarySaysNothing() {
        #expect(LibraryLogic.loadNote(unavailable: [], resolution: chosenFolder) == nil)
    }

    @Test func aFallbackIsNamed() {
        #expect(LibraryLogic.loadNote(unavailable: [], resolution: usedFolder) == "The save location isn't available, so “A” is used instead.")
    }

    @Test func aFallbackAndAMissingFolderShareOneMessage() throws {
        let note = try #require(LibraryLogic.loadNote(unavailable: [gone], resolution: usedFolder))
        #expect(note.hasPrefix("The save location isn't available, so “A” is used instead. "))
        #expect(note.hasSuffix("“/Volumes/Gone”"))
    }

    @Test func noSaveLocationIsNotAFallback() {
        #expect(LibraryLogic.loadNote(unavailable: [], resolution: .unavailable(reason: "none")) == nil)
    }

    @Test func tilesUseTheSharedSummary() {
        #expect(StatusText.explorerSummary(visible: 4, total: 4, query: "", selectedCount: 0, selectedBytes: nil) == "4 items  |")
        #expect(StatusText.explorerSummary(visible: 4, total: 4, query: "", selectedCount: 1, selectedBytes: nil) == "4 items  |  1 item selected  |")
        #expect(StatusText.explorerSummary(visible: 1, total: 4, query: "doc", selectedCount: 0, selectedBytes: nil) == "1 of 4 items match “doc”  |")
    }
}

@Suite("Library catalog decoding (hostile preferences)")
struct LibraryCatalogDecodingTests {
    @Test func oldDataWithoutATemplateGetsTheNames() {
        let list = catalog(#"[{"name":"Music","folders":["/m"],"saveLocation":"/m"},{"name":"Work","folders":[]}]"#)
        #expect(list.definition("Music")?.template == .music)
        #expect(list.definition("Work")?.template == .generalItems)
    }

    @Test func anUnknownTemplateFallsBack() {
        #expect(catalog(#"[{"name":"Videos","folders":[],"template":"holograms"}]"#).definition("Videos")?.template == .videos)
        #expect(catalog(#"[{"name":"Videos","folders":[],"template":7}]"#).definition("Videos")?.template == .videos)
    }

    @Test func aChosenTemplateRoundTrips() throws {
        var list = empty()
        try list.create(named: "Work")
        list.update(LibraryDefinition(name: "Work", folders: [], template: .pictures))
        #expect(LibraryCatalog(data: try list.encoded(), home: home) == list)
    }

    @Test func oneBadElementKeepsTheOthers() {
        let list = catalog(#"[{"name":"A","folders":[]},{"folders":"nope"},12,{"name":"B","folders":[]}]"#)
        #expect(names(list) == ["A", "B"])
    }

    @Test func invalidOrDuplicateNamesAreDropped() {
        let list = catalog(#"[{"name":"A","folders":[]},{"name":"a","folders":[]},{"name":"Libraries","folders":[]},{"name":"x/y","folders":[]},{"name":"","folders":[]}]"#)
        #expect(names(list) == ["A"])
    }

    @Test func notAnArrayGivesTheDefaults() {
        #expect(names(catalog(#"{"name":"A"}"#)) == LibraryLogic.defaultNames)
        #expect(names(catalog("garbage")) == LibraryLogic.defaultNames)
    }

    @Test func oversizedDataGivesTheDefaults() {
        let big = Data(repeating: 0x20, count: LibraryCatalog.maxBytes + 1)
        #expect(names(LibraryCatalog(data: big, home: home)) == LibraryLogic.defaultNames)
    }

    @Test func relativeAndBadPathsAreDropped() {
        let long = "/" + String(repeating: "x", count: Int(PATH_MAX))
        let list = catalog(#"[{"name":"A","folders":["relative/path","/ok/","/nul\u0000x","/dup","/dup/","\#(long)"]}]"#)
        #expect(list.definition("A")?.folders == ["/ok", "/dup"])
    }

    @Test func aSaveLocationOutsideTheListBecomesTheFirstFolder() {
        let list = catalog(#"[{"name":"A","folders":["/a","/b"],"saveLocation":"/evil"}]"#)
        #expect(list.definition("A")?.saveLocation == "/a")
    }

    @Test func overCapListsAreCut() {
        let folders = (0..<100).map { "\"/f\($0)\"" }.joined(separator: ",")
        #expect(catalog(#"[{"name":"A","folders":[\#(folders)]}]"#).definition("A")?.folders.count == LibraryLogic.maxFolders)
        let libraries = (0..<300).map { #"{"name":"L\#($0)","folders":[]}"# }.joined(separator: ",")
        #expect(catalog("[\(libraries)]").libraries.count == LibraryCatalog.maxLibraries)
    }
}

@Suite("Libraries and tabs, views and columns (FE-076)")
struct LibraryIntegrationTests {
    @Test func historyFollowsARename() {
        var history = NavigationHistory(start: .library("Old"))
        history.visit(.home)
        history.visit(.library("Other"))
        history.visit(.library("Old"))
        _ = history.goBack()
        history.rewriteLocations { LibraryLogic.location($0, afterRenaming: "Old", to: "New") }
        #expect(history.current.location == .library("Other"))
        #expect(history.peekForward()?.location == .library("New"))
        _ = history.goBack()
        _ = history.goBack()
        #expect(history.current.location == .library("New"))
    }

    @Test func searchesStartedInALibraryFollowARename() throws {
        let request = SearchRequest(query: "x", originKey: Location.library("Old").key)
        let moved = try #require(LibraryLogic.location(.search(request), afterRenaming: "Old", to: "New"))
        guard case .search(let result) = moved else { Issue.record("not a search"); return }
        #expect(result.origin == .library("New"))
        #expect(LibraryLogic.location(.library("Other"), afterRenaming: "Old", to: "New") == nil)
        #expect(LibraryLogic.location(.home, afterRenaming: "Old", to: "New") == nil)
    }

    @Test func aRenamedLibraryKeepsItsSavedView() {
        let store = FolderViewStore(fileURL: nil)
        let old = LibraryLogic.viewIdentity(named: "Old"), new = LibraryLogic.viewIdentity(named: "New")
        let view = FolderViewSettings(viewMode: "largeIcons")
        store.setOverride(view, for: old, template: .pictures)
        store.moveOverride(from: old, to: new)
        #expect(store.override(for: old) == nil)
        #expect(store.override(for: new) == view)
        #expect(store.count == 1)
    }

    @Test func movingOntoAStaleViewReplacesIt() {
        let store = FolderViewStore(fileURL: nil)
        let old = LibraryLogic.viewIdentity(named: "Old"), new = LibraryLogic.viewIdentity(named: "New")
        store.setOverride(FolderViewSettings(viewMode: "details"), for: new)
        store.setOverride(FolderViewSettings(viewMode: "list"), for: old)
        store.moveOverride(from: old, to: new)
        #expect(store.override(for: new)?.viewMode == "list")
        #expect(store.count == 1)
    }

    @Test func aForgottenViewIsGone() {
        let store = FolderViewStore(fileURL: nil)
        let identity = LibraryLogic.viewIdentity(named: "A")
        store.setOverride(FolderViewSettings(viewMode: "list"), for: identity)
        store.setOverride(nil, for: identity)
        #expect(store.override(for: identity) == nil)
    }

    @Test func theFolderColumnReadsFromTheListing() throws {
        let descriptor = try #require(ColumnCatalog.descriptor(.folder))
        #expect(!ColumnCatalog.needsLoading(.folder))
        #expect(descriptor.truncatesMiddle)
        let item = FileItem(url: URL(fileURLWithPath: "/Users/me/Documents/a.txt"), name: "a.txt", isFolder: false)
        #expect(ColumnValues.value(item, .folder, lookup: nil) == .text("Documents (/Users/me)"))
        #expect(descriptor.toolTip?(item) == "/Users/me/Documents")
    }

    @Test func theFolderColumnSorts() {
        func item(_ path: String) -> FileItem { FileItem(url: URL(fileURLWithPath: path), name: "a.txt", isFolder: false) }
        var order = FileSortOrder()
        order.setPrimary(.folder, ascending: true)
        let sorted = FileSorter.sorted([item("/z/a.txt"), item("/b/a.txt")], by: order)
        #expect(sorted.map(\.url.path) == ["/b/a.txt", "/z/a.txt"])
    }

    @Test func listingStopsBetweenFoldersWhenCancelled() throws {
        let fx = try Fixture()
        let a = try fx.folder("A"), b = try fx.folder("B")
        try fx.file("A/one.txt")
        try fx.file("B/two.txt")
        let library = LibraryDefinition(name: "L", folders: [a, b])
        var checks = 0
        let result = LibraryMerge.list(library, includeHidden: false, isCancelled: {
            checks += 1
            return checks > 1
        })
        #expect(result.items.map(\.name) == ["one.txt"])
        #expect(checks == 2)
    }

    @Test func aSymlinkedFolderListsItemsUnderItsListedFolder() throws {
        let fx = try Fixture()
        let real = try fx.folder("Real")
        try fx.file("Real/one.txt")
        let link = real.deletingLastPathComponent().appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let result = LibraryMerge.list(LibraryDefinition(name: "L", folders: [link]), includeHidden: false)
        #expect(result.items.map { Location.folder($0.url) } == [Location.folder(LibraryMerge.listedFolder(link).appendingPathComponent("one.txt"))])
    }

    @Test func aCancelledListingReadsNothing() throws {
        let fx = try Fixture()
        let a = try fx.folder("A")
        try fx.file("A/one.txt")
        let result = LibraryMerge.list(LibraryDefinition(name: "L", folders: [a]), includeHidden: false, isCancelled: { true })
        #expect(result.items.isEmpty)
    }
}
