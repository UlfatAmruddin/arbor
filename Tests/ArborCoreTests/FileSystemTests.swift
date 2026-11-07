import Foundation
import Testing
@testable import ArborCore

/// A disposable fixture folder. Tests never touch real user files or the real Trash.
final class Fixture {
    let root: URL
    let trash: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("arbor-tests-\(UUID().uuidString)").standardizedFileURL
        trash = root.appendingPathComponent(".fixture-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }
    func read(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
    func names(_ path: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: url(path).path)) ?? []).sorted() }

    /// Moves "replaced" items into the fixture's own trash folder.
    var disposer: FileTransfer.Disposer {
        let trash = self.trash
        return { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    func transfer(_ kind: TransferKind, _ sources: [String], to dest: String) -> FileTransfer {
        FileTransfer(kind: kind, sources: sources.map(url), destination: url(dest), disposeReplaced: disposer)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func always(_ choice: ConflictChoice, all: Bool = false, counter: Counter? = nil) -> FileTransfer.ConflictResolver {
    { _ in counter?.increment(); return ConflictDecision(choice, applyToRemaining: all) }
}

private let neverAsked: FileTransfer.ConflictResolver = { conflict in
    Issue.record("Unexpected conflict for \(conflict.destination.lastPathComponent)")
    return ConflictDecision(.cancel)
}

@Suite("Directory listing (FE-015, FE-044)")
struct DirectoryListerTests {
    @Test func listsWithAndWithoutHiddenItems() throws {
        let fx = try Fixture()
        try fx.file("box/visible.txt")
        try fx.file("box/.hidden")
        try fx.folder("box/Sub")
        let shown = try DirectoryLister.list(fx.url("box"), includeHidden: false)
        #expect(Set(shown.map(\.name)) == ["visible.txt", "Sub"])
        #expect(shown.first { $0.name == "Sub" }?.isFolder == true)
        #expect(shown.first { $0.name == "Sub" }?.size == nil)
        #expect(shown.first { $0.name == "visible.txt" }?.size == 1)
        let all = try DirectoryLister.list(fx.url("box"), includeHidden: true)
        #expect(all.count == 3)
    }

    @Test func distinctErrors() throws {
        let fx = try Fixture()
        let file = try fx.file("plain.txt")
        #expect(throws: ListingError.notFound(path: fx.url("missing").path)) {
            try DirectoryLister.list(fx.url("missing"), includeHidden: false)
        }
        #expect(throws: ListingError.notAFolder(path: file.path)) {
            try DirectoryLister.list(file, includeHidden: false)
        }
    }

    @Test func symlinkToFolderIsNavigable() throws {
        let fx = try Fixture()
        try fx.folder("real")
        try fx.folder("box")
        try FileManager.default.createSymbolicLink(at: fx.url("box/link"), withDestinationURL: fx.url("real"))
        let items = try DirectoryLister.list(fx.url("box"), includeHidden: false)
        #expect(items.first?.isFolder == true)
        #expect(items.first?.isSymbolicLink == true)
    }
}

@Suite("Rename (FE-063, FE-086, FE-224)")
struct RenamerTests {
    @Test func renames() throws {
        let fx = try Fixture()
        let a = try fx.file("a.txt", "hello")
        let b = try Renamer.rename(a, to: "b.txt")
        #expect(b.lastPathComponent == "b.txt")
        #expect(fx.read("b.txt") == "hello")
        #expect(!fx.exists("a.txt"))
    }

    @Test func refusesToOverwrite() throws {
        let fx = try Fixture()
        let a = try fx.file("a.txt", "A")
        try fx.file("b.txt", "B")
        #expect(throws: RenameError.alreadyExists("b.txt")) { try Renamer.rename(a, to: "b.txt") }
        #expect(fx.read("a.txt") == "A")
        #expect(fx.read("b.txt") == "B")
    }

    @Test func caseOnlyRename() throws {
        let fx = try Fixture()
        let a = try fx.file("readme.md", "R")
        _ = try Renamer.rename(a, to: "README.md")
        #expect(fx.names("").contains("README.md"))
        #expect(!fx.names("").contains("readme.md"))
        #expect(fx.read("README.md") == "R")
    }

    @Test func rejectsInvalidNames() throws {
        let fx = try Fixture()
        let a = try fx.file("a.txt")
        #expect(throws: RenameError.invalid(.containsSlash)) { try Renamer.rename(a, to: "x/y") }
        #expect(throws: RenameError.invalid(.empty)) { try Renamer.rename(a, to: "") }
    }
}

@Suite("Copy and move (FE-084, FE-112, FE-117–FE-122)")
struct FileTransferTests {
    @Test func copyKeepsSource() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "A")
        try fx.folder("dst")
        let report = await fx.transfer(.copy, ["src/a.txt"], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        #expect(fx.read("src/a.txt") == "A")
        #expect(fx.read("dst/a.txt") == "A")
    }

    @Test func moveRemovesSource() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "A")
        try fx.folder("dst")
        let report = await fx.transfer(.move, ["src/a.txt"], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.committed.map(\.destination.lastPathComponent) == ["a.txt"])
        #expect(!fx.exists("src/a.txt"))
        #expect(fx.read("dst/a.txt") == "A")
    }

    @Test func copyIntoSameFolderMakesWindowsStyleCopy() async throws {
        let fx = try Fixture()
        try fx.file("f/a.txt", "A")
        let first = await fx.transfer(.copy, ["f/a.txt"], to: "f").run(resolveConflict: neverAsked)
        let second = await fx.transfer(.copy, ["f/a.txt"], to: "f").run(resolveConflict: neverAsked)
        #expect(first.committed.first?.destination.lastPathComponent == "a - Copy.txt")
        #expect(second.committed.first?.destination.lastPathComponent == "a - Copy (2).txt")
    }

    @Test func moveIntoSameFolderIsANoOp() async throws {
        let fx = try Fixture()
        try fx.file("f/a.txt", "A")
        let report = await fx.transfer(.move, ["f/a.txt"], to: "f").run(resolveConflict: neverAsked)
        guard case .skipped = report.results.first?.outcome else { Issue.record("expected skip"); return }
        #expect(fx.read("f/a.txt") == "A")
    }

    @Test func refusesFolderIntoItself() async throws {
        let fx = try Fixture()
        try fx.folder("p/child")
        for dest in ["p", "p/child"] {
            let report = await fx.transfer(.move, ["p"], to: dest).run(resolveConflict: neverAsked)
            #expect(report.problems.count == 1, "into \(dest)")
        }
        #expect(fx.exists("p/child"))
    }

    @Test func keepBoth() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "new")
        try fx.file("dst/a.txt", "old")
        let report = await fx.transfer(.copy, ["src/a.txt"], to: "dst").run(resolveConflict: always(.keepBoth))
        #expect(report.committed.first?.destination.lastPathComponent == "a (2).txt")
        #expect(fx.read("dst/a.txt") == "old")
        #expect(fx.read("dst/a (2).txt") == "new")
    }

    @Test func replaceDisposesOfExistingItemFirst() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "new")
        try fx.file("dst/a.txt", "old")
        _ = await fx.transfer(.copy, ["src/a.txt"], to: "dst").run(resolveConflict: always(.replace))
        #expect(fx.read("dst/a.txt") == "new")
        #expect(fx.names(".fixture-trash").count == 1, "old file is recoverable, not erased")
    }

    @Test func skipLeavesDestinationUntouched() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "new")
        try fx.file("dst/a.txt", "old")
        let report = await fx.transfer(.move, ["src/a.txt"], to: "dst").run(resolveConflict: always(.skip))
        guard case .skipped = report.results.first?.outcome else { Issue.record("expected skip"); return }
        #expect(fx.read("dst/a.txt") == "old")
        #expect(fx.read("src/a.txt") == "new")
    }

    @Test func applyToRemainingAsksOnce() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt"); try fx.file("src/b.txt")
        try fx.file("dst/a.txt"); try fx.file("dst/b.txt")
        let counter = Counter()
        _ = await fx.transfer(.copy, ["src/a.txt", "src/b.txt"], to: "dst")
            .run(resolveConflict: always(.skip, all: true, counter: counter))
        #expect(counter.count == 1)
    }

    @Test func cancelStopsRemainingItems() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt"); try fx.file("src/b.txt")
        try fx.file("dst/a.txt")
        let report = await fx.transfer(.copy, ["src/a.txt", "src/b.txt"], to: "dst").run(resolveConflict: always(.cancel))
        #expect(report.wasCancelled)
        #expect(report.results.map(\.outcome) == [.cancelled, .cancelled])
        #expect(!fx.exists("dst/b.txt"))
    }

    @Test func mergeFolders() async throws {
        let fx = try Fixture()
        try fx.file("src/Photos/new.jpg", "N")
        try fx.file("src/Photos/.DS_Store", "finder")
        try fx.file("dst/Photos/old.jpg", "O")
        let report = await fx.transfer(.move, ["src/Photos"], to: "dst").run(resolveConflict: always(.merge))
        #expect(report.results.first?.outcome == .merged(fx.url("dst/Photos")))
        #expect(fx.names("dst/Photos") == ["new.jpg", "old.jpg"])
        #expect(!fx.exists("src/Photos"), "emptied source folder is removed after a move-merge")
    }

    @Test func mergeAsksAgainForNestedFileConflicts() async throws {
        let fx = try Fixture()
        try fx.file("src/F/same.txt", "new")
        try fx.file("dst/F/same.txt", "old")
        let counter = Counter()
        let resolver: FileTransfer.ConflictResolver = { conflict in
            counter.increment()
            return ConflictDecision(conflict.kind == .folderOverFolder ? .merge : .skip)
        }
        let report = await fx.transfer(.copy, ["src/F"], to: "dst").run(resolveConflict: resolver)
        #expect(counter.count == 2)
        #expect(fx.read("dst/F/same.txt") == "old")
        #expect(report.details.count == 1)
    }

    @Test func typeMismatchIsReported() async throws {
        let fx = try Fixture()
        try fx.folder("src/thing")
        try fx.file("dst/thing", "file")
        let seen = Counter()
        let resolver: FileTransfer.ConflictResolver = { c in
            if c.kind == .typeMismatch { seen.increment() }
            return ConflictDecision(.skip)
        }
        _ = await fx.transfer(.copy, ["src/thing"], to: "dst").run(resolveConflict: resolver)
        #expect(seen.count == 1)
        #expect(fx.read("dst/thing") == "file")
    }

    @Test func missingSourceFailsWithoutStoppingOthers() async throws {
        let fx = try Fixture()
        try fx.file("src/b.txt")
        try fx.folder("dst")
        let report = await fx.transfer(.copy, ["src/gone.txt", "src/b.txt"], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.problems.count == 1)
        #expect(fx.exists("dst/b.txt"))
    }

    @Test func refusesToReplaceAnAncestorOfTheSource() async throws {
        let fx = try Fixture()
        try fx.file("p/x/x/inner.txt", "keep me")
        let report = await fx.transfer(.move, ["p/x/x"], to: "p").run(resolveConflict: always(.replace))
        #expect(report.problems.count == 1)
        #expect(fx.read("p/x/x/inner.txt") == "keep me")
    }
}
