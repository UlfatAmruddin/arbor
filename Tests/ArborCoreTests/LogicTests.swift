import Foundation
import Testing
@testable import ArborCore

private func item(_ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil, type: String = "") -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/tmp/fixture/\(name)"), name: name, isFolder: folder,
             size: folder ? nil : size, modified: modified, typeDescription: type)
}

@Suite("Sorting (FE-037, FE-053)")
struct SortingTests {
    @Test func naturalNumberOrder() {
        let sorted = FileSorter.sorted([item("file10"), item("file2"), item("file1")], by: FileSortOrder())
        #expect(sorted.map(\.name) == ["file1", "file2", "file10"])
    }

    @Test func caseInsensitiveNames() {
        let sorted = FileSorter.sorted([item("cherry"), item("Banana"), item("apple")], by: FileSortOrder())
        #expect(sorted.map(\.name) == ["apple", "Banana", "cherry"])
    }

    @Test func foldersFirstInBothDirections() {
        let items = [item("b.txt"), item("Zeta", folder: true), item("a.txt"), item("Alpha", folder: true)]
        let up = FileSorter.sorted(items, by: FileSortOrder(key: .name, ascending: true))
        let down = FileSorter.sorted(items, by: FileSortOrder(key: .name, ascending: false))
        #expect(up.map(\.name) == ["Alpha", "Zeta", "a.txt", "b.txt"])
        #expect(down.map(\.name) == ["Zeta", "Alpha", "b.txt", "a.txt"])
    }

    @Test func foldersCanBeMixedWhenDisabled() {
        let items = [item("b", folder: true), item("a.txt"), item("c.txt")]
        let sorted = FileSorter.sorted(items, by: FileSortOrder(key: .name, ascending: true, foldersFirst: false))
        #expect(sorted.map(\.name) == ["a.txt", "b", "c.txt"])
    }

    @Test func unknownSizesSortLastInBothDirections() {
        let items = [item("unknown"), item("big", size: 900), item("small", size: 10)]
        let up = FileSorter.sorted(items, by: FileSortOrder(key: .size, ascending: true, foldersFirst: false))
        let down = FileSorter.sorted(items, by: FileSortOrder(key: .size, ascending: false, foldersFirst: false))
        #expect(up.map(\.name) == ["small", "big", "unknown"])
        #expect(down.map(\.name) == ["big", "small", "unknown"])
    }

    @Test func equalValuesTieBreakByName() {
        let items = [item("c", size: 5), item("a", size: 5), item("b", size: 5)]
        let sorted = FileSorter.sorted(items, by: FileSortOrder(key: .size, ascending: false))
        #expect(sorted.map(\.name) == ["a", "b", "c"])
    }

    @Test func dateDescending() {
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 1000)
        let sorted = FileSorter.sorted([item("old", modified: old), item("new", modified: new)],
                                       by: FileSortOrder(key: .dateModified, ascending: false))
        #expect(sorted.map(\.name) == ["new", "old"])
    }

    @Test func filterIsCaseAndDiacriticInsensitive() {
        let items = [item("Résumé.pdf"), item("notes.txt")]
        #expect(FileFilter.apply(items, query: "resume").map(\.name) == ["Résumé.pdf"])
        #expect(FileFilter.apply(items, query: "  ").count == 2)
    }
}

@Suite("Navigation history (FE-001, FE-002)")
struct NavigationHistoryTests {
    let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")

    @Test func backAndForward() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        #expect(h.goBack()?.url == b)
        #expect(h.goBack()?.url == a)
        #expect(h.goBack() == nil)
        #expect(h.goForward()?.url == b)
        #expect(h.current.url == b)
    }

    @Test func branchingTrimsForwardHistory() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.goBack()
        h.visit(c)
        #expect(!h.canGoForward)
        #expect(h.backStack.map(\.url) == [a])
    }

    @Test func revisitingCurrentIsNotANewEntry() {
        var h = NavigationHistory(start: a)
        h.visit(a)
        #expect(!h.canGoBack)
    }

    @Test func savedSelectionIsRestoredOnBack() {
        var h = NavigationHistory(start: a)
        h.saveState(selectedNames: ["x.txt"], topVisibleName: "w.txt")
        h.visit(b)
        let entry = h.goBack()
        #expect(entry?.selectedNames == ["x.txt"])
        #expect(entry?.topVisibleName == "w.txt")
    }

    @Test func goingBackSeveralStepsLeavesThemOnForward() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        #expect(h.peekBack(steps: 2)?.url == a)
        #expect(h.goBack(steps: 2)?.url == a)
        #expect(!h.canGoBack)
        #expect(h.goForward()?.url == b)
        #expect(h.goForward()?.url == c)
    }

    @Test func stepsOutsideTheStackDoNothing() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        for steps in [0, -1, 2] {
            #expect(h.peekBack(steps: steps) == nil)
            #expect(h.goBack(steps: steps) == nil)
        }
        #expect(h.current.url == b && h.canGoBack && !h.canGoForward)
    }

    @Test func stepsBackFindsTheNearestMatch() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        #expect(h.stepsBack(toNearest: { $0.url == b }) == 1)
        #expect(h.stepsBack(toNearest: { $0.url == a }) == 2)
        #expect(h.stepsBack(toNearest: { $0.url == c }) == nil)   // the current entry isn't behind us
    }

    @Test func clearingBackForwardKeepsCurrentLocation() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        h.goBack()
        h.saveState(selectedNames: ["x.txt"], topVisibleName: nil)
        h.clearBackForward()
        #expect(!h.canGoBack && !h.canGoForward)
        #expect(h.current.url == b)
        #expect(h.current.selectedNames == ["x.txt"])
        // A tab rebuilt from the saved session has no Back/Forward either.
        let saved = SessionTab(history: h, viewMode: "details", sort: FileSortOrder())
        #expect(saved.back.isEmpty && saved.forward.isEmpty)
    }

    @Test func historyIsBounded() {
        var h = NavigationHistory(start: a, limit: 3)
        for i in 0..<10 { h.visit(URL(fileURLWithPath: "/f\(i)")) }
        #expect(h.backStack.count == 3)
    }

    @Test func parentOfRootIsNil() {
        #expect(NavigationHistory.parent(of: URL(fileURLWithPath: "/")) == nil)
        #expect(NavigationHistory.parent(of: URL(fileURLWithPath: "/Users/me"))?.path == "/Users")
    }
}

@Suite("Address bar resolution (FE-005, FE-013, FE-014)")
struct PathResolverTests {
    let home = URL(fileURLWithPath: "/Users/me")
    var resolver: PathResolver {
        let fs: [String: Bool] = [
            "/Users/me": true, "/Users/me/Documents": true, "/Users/me/My Folder": true,
            "/Users/me/notes.txt": false, "/Users": true, "/": true,
        ]
        return PathResolver(homeDirectory: home, probe: { fs[$0] })
    }

    func folder(_ s: String, from current: URL? = nil) -> String? {
        if case .success(.folder(let u)) = resolver.resolve(s, relativeTo: current) { return u.path }
        return nil
    }

    @Test func tilde() {
        #expect(folder("~") == "/Users/me")
        #expect(folder("~/Documents") == "/Users/me/Documents")
    }

    @Test func quotedPathWithSpaces() {
        #expect(folder("\"/Users/me/My Folder\"") == "/Users/me/My Folder")
        #expect(folder("  /Users/me/My Folder  ") == "/Users/me/My Folder")
    }

    @Test func fileURLIsDecodedOnce() {
        #expect(folder("file:///Users/me/My%20Folder") == "/Users/me/My Folder")
    }

    @Test func relativePaths() {
        #expect(folder("Documents", from: home) == "/Users/me/Documents")
        #expect(folder("..", from: home) == "/Users")
    }

    @Test func existingFileSelectsIt() {
        #expect(resolver.resolve("~/notes.txt", relativeTo: nil) == .success(.file(URL(fileURLWithPath: "/Users/me/notes.txt"))))
    }

    @Test func uncBecomesSMB() {
        guard case .success(.network(let url)) = resolver.resolve(#"\\nas\media\Movies 2026"#, relativeTo: nil) else {
            Issue.record("expected network"); return
        }
        #expect(url.absoluteString == "smb://nas/media/Movies%202026")
    }

    @Test func smbURLIsNetwork() {
        #expect(resolver.resolve("smb://nas/share", relativeTo: nil) == .success(.network(URL(string: "smb://nas/share")!)))
    }

    @Test func errorsAreSpecific() {
        #expect(resolver.resolve(#"C:\Users"#, relativeTo: nil) == .failure(.windowsDriveLetter(#"C:\Users"#)))
        #expect(resolver.resolve("D:", relativeTo: nil) == .failure(.windowsDriveLetter("D:")))
        #expect(resolver.resolve("/nope", relativeTo: nil) == .failure(.notFound("/nope")))
        #expect(resolver.resolve("http://example.com", relativeTo: nil) == .failure(.unsupportedScheme("http://example.com")))
        #expect(resolver.resolve("   ", relativeTo: nil) == .failure(.empty))
    }

    @Test func shellTextIsNeverExecuted() {
        // Treated as a relative path that doesn't exist, not as a command.
        #expect(resolver.resolve("$(rm -rf ~)", relativeTo: home) == .failure(.notFound("/Users/me/$(rm -rf ~)")))
    }
}

@Suite("Naming (FE-063, FE-086, FE-087)")
struct NameRulesTests {
    @Test func extensions() {
        #expect(NameRules.splitExtension("report.pdf", treatAsFolder: false) == ("report", "pdf"))
        #expect(NameRules.splitExtension(".zshrc", treatAsFolder: false) == (".zshrc", nil))
        #expect(NameRules.splitExtension("archive.tar.gz", treatAsFolder: false) == ("archive.tar", "gz"))
        #expect(NameRules.splitExtension("trailing.", treatAsFolder: false) == ("trailing.", nil))
        #expect(NameRules.splitExtension("my.folder", treatAsFolder: true) == ("my.folder", nil))
    }

    @Test func renameSelectsBaseName() {
        #expect(NameRules.basenameSelection("report.pdf", treatAsFolder: false) == NSRange(location: 0, length: 6))
        #expect(NameRules.basenameSelection("my.folder", treatAsFolder: true) == NSRange(location: 0, length: 9))
    }

    @Test func duplicateAndKeepBothNames() {
        var taken: Set<String> = ["a.txt"]
        let first = NameRules.duplicateName(for: "a.txt", treatAsFolder: false) { taken.contains($0) }
        #expect(first == "a - Copy.txt")
        taken.insert(first)
        #expect(NameRules.duplicateName(for: "a.txt", treatAsFolder: false) { taken.contains($0) } == "a - Copy (2).txt")
        #expect(NameRules.keepBothName(for: "a.txt", treatAsFolder: false) { taken.contains($0) } == "a (2).txt")
    }

    @Test func newFolderNames() {
        #expect(NameRules.newFolderName { _ in false } == "New folder")
        #expect(NameRules.newFolderName { ["New folder", "New folder (2)"].contains($0) } == "New folder (3)")
        // Whatever the language, the name is plain text: no direction marks reach the disk.
        #expect(!NameRules.newFolderName { $0 == "New folder" }.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) })
    }

    @Test func validation() {
        #expect(NameRules.validate("") == .empty)
        #expect(NameRules.validate("a/b") == .containsSlash)
        #expect(NameRules.validate("..") == .reserved(".."))
        #expect(NameRules.validate(String(repeating: "x", count: 256)) == .tooLong)
        // Valid on macOS even though Windows forbids it.
        #expect(NameRules.validate("What? <draft>: v2") == nil)
    }
}

@Suite("Clipboard intent (FE-084)")
struct TransferIntentTests {
    let files = [URL(fileURLWithPath: "/a/1.txt"), URL(fileURLWithPath: "/a/2.txt")]

    @Test func cutPastesAsMoveWhileCurrent() {
        let intent = TransferIntent(kind: .move, urls: files, pasteboardChangeCount: 7)
        #expect(TransferIntent.pasteKind(intent: intent, changeCount: 7, pasteboardURLs: files) == .move)
        #expect(intent.marksCut(files[0], changeCount: 7))
    }

    @Test func staleCutBecomesCopy() {
        let intent = TransferIntent(kind: .move, urls: files, pasteboardChangeCount: 7)
        #expect(TransferIntent.pasteKind(intent: intent, changeCount: 8, pasteboardURLs: files) == .copy)
        #expect(!intent.marksCut(files[0], changeCount: 8))
        #expect(TransferIntent.pasteKind(intent: intent, changeCount: 7, pasteboardURLs: [files[0]]) == .copy)
    }

    @Test func statusSummary() {
        let sel = [item("a", size: 1000), item("b", size: 24)]
        #expect(StatusText.summary(visible: 3, total: 3, query: "", selected: []) == "3 items")
        #expect(StatusText.summary(visible: 1, total: 1, query: "", selected: []) == "1 item")
        #expect(StatusText.summary(visible: 2, total: 9, query: "re", selected: sel).hasPrefix("2 of 9 items match “re”     2 selected · "))
        #expect(!StatusText.summary(visible: 2, total: 2, query: "", selected: [item("f", folder: true)]).contains("·"))
    }
}
