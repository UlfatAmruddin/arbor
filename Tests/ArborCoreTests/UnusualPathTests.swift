import Foundation
import Testing
@testable import ArborCore

private let tooLong = L10n.tr("The path is too long or nested too deeply.")

/// A fixture holding `src/<name>` with the name's own bytes as content, and an empty `dst`.
private func oddFixture(_ name: String) throws -> (fx: Fixture, item: URL, contents: Data) {
    let fx = try Fixture()
    try fx.folder("src")
    try fx.folder("dst")
    let item = fx.url("src").appendingPathComponent(name)
    let contents = Data(name.utf8)
    #expect(FileManager.default.createFile(atPath: item.path, contents: contents))
    return (fx, item, contents)
}

private func contents(_ fx: Fixture, _ folder: String, _ name: String) -> Data? {
    try? Data(contentsOf: fx.url(folder).appendingPathComponent(name))
}

@Suite("Unusual names through every operation (FE-225)")
struct UnusualNameTests {
    @Test(arguments: OddNames.all)
    func listedAsOneRowWithItsExactName(name: String) throws {
        let (fx, _, _) = try oddFixture(name)
        let items = try DirectoryLister.list(fx.url("src"), includeHidden: true)
        #expect(items.map(\.name) == [name])
        #expect(items.first?.size == Int64(name.utf8.count))
    }

    @Test(arguments: OddNames.all)
    func copiedByteForByte(name: String) async throws {
        let (fx, item, data) = try oddFixture(name)
        let report = await fx.job(.copy, ["src/" + name], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(fx.names("dst") == [name])
        #expect(contents(fx, "dst", name) == data)
        #expect(try Data(contentsOf: item) == data, "the original is untouched")
    }

    @Test(arguments: OddNames.all)
    func movedOnTheSameVolume(name: String) async throws {
        let (fx, _, data) = try oddFixture(name)
        let report = await fx.job(.move, ["src/" + name], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(fx.names("src").isEmpty)
        #expect(fx.names("dst") == [name])
        #expect(contents(fx, "dst", name) == data)
    }

    @Test(arguments: OddNames.all)
    func movedAcrossVolumes(name: String) async throws {
        let (fx, _, data) = try oddFixture(name)
        let report = await fx.job(.move, ["src/" + name], to: "dst", sameVolume: { _, _ in false }).run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(fx.names("src").isEmpty)
        #expect(contents(fx, "dst", name) == data)
    }

    @Test(arguments: OddNames.all)
    func renamedAndBack(name: String) throws {
        let (fx, item, data) = try oddFixture(name)
        let renamed = try Renamer.rename(item, to: "renamed")
        #expect(fx.names("src") == ["renamed"])
        let back = try Renamer.rename(renamed, to: name)
        #expect(fx.names("src") == [name])
        #expect(try Data(contentsOf: back) == data)
    }

    @Test(arguments: OddNames.all)
    func trashedIntoAPrivateFolder(name: String) throws {
        let (fx, item, data) = try oddFixture(name)
        let trashed = try SystemTrash.trash(item, into: fx.trash)
        #expect(fx.names("src").isEmpty)
        #expect(fx.names(".fixture-trash") == [name])
        #expect(try Data(contentsOf: trashed) == data)
    }

    @Test(arguments: OddNames.all)
    func deletedPermanently(name: String) throws {
        let (fx, item, _) = try oddFixture(name)
        #expect(FileOps.removePermanently(item) == 0)
        #expect(fx.names("src").isEmpty)
    }
}

@Suite("Paths at the limit (FE-225)")
struct PathLimitTests {
    @Test func aPathOfExactlyTheLimitWorksEverywhere() async throws {
        let tree = try DeepTree()
        let parts = tree.components(reaching: PathLimits.maxPathBytes)
        let file = try tree.file(parts, "at the limit")
        #expect(file.path.utf8.count == PathLimits.maxPathBytes)
        #expect(PathLimits.fits(file))
        let folder = file.deletingLastPathComponent()
        #expect(try DirectoryLister.list(folder, includeHidden: true).map(\.name) == [parts[parts.count - 1]])

        let destination = try tree.folder(["dst"])
        let copied = await FileTransfer(kind: .copy, sources: [file], destination: destination).run(resolveConflict: neverAsked)
        #expect(copied.problems.isEmpty, "\(copied.problems)")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(parts[parts.count - 1]).path))

        let renamedName = String(repeating: "e", count: parts[parts.count - 1].utf8.count)
        let renamed = try Renamer.rename(file, to: renamedName)
        #expect(renamed.path.utf8.count == PathLimits.maxPathBytes)

        let moveTarget = try tree.folder(["moved"])
        let moved = await FileTransfer(kind: .move, sources: [renamed], destination: moveTarget).run(resolveConflict: neverAsked)
        #expect(moved.problems.isEmpty, "\(moved.problems)")
        #expect(!FileOps.exists(renamed))

        let again = try tree.file(parts, "again")
        #expect(FileOps.removePermanently(again) == 0)
        #expect(!FileOps.exists(again))
    }

    @Test func oneBytePastTheLimitIsExplainedAsTooLong() async throws {
        let tree = try DeepTree()
        let parts = tree.components(reaching: PathLimits.maxPathBytes + 1 + tree.standardizingSlack)
        let file = try tree.file(parts, "past the limit")
        #expect(!PathLimits.fits(file.standardizedFileURL))
        let before = TreeManifest(of: tree.root)

        let destination = try tree.folder(["dst"])
        let report = await FileTransfer(kind: .copy, sources: [file], destination: destination).run(resolveConflict: neverAsked)
        #expect(report.results.map(\.outcome) == [.failed(tooLong)])
        #expect(throws: RenameError.pathTooLong) { try Renamer.rename(file, to: "x") }
        #expect(TreeManifest(of: tree.root).paths == before.paths.union(["dst"]))

        let folderTree = try DeepTree()
        let folder = try folderTree.folder(folderTree.components(reaching: PathLimits.maxPathBytes + 1 + folderTree.standardizingSlack))
        #expect(throws: ListingError.pathTooLong(path: folder.path)) { try DirectoryLister.list(folder, includeHidden: true) }
        expectTooLong(PathResolver().resolve(folder.path, relativeTo: nil))

        #expect(FileOps.removePermanently(file) == 0, "a descriptor of the parent reaches what a path can't")
    }

    private func expectTooLong(_ result: Result<PathResolution, PathResolutionError>, sourceLocation: SourceLocation = #_sourceLocation) {
        if case .failure(.pathTooLong) = result { return }
        Issue.record("\(result)", sourceLocation: sourceLocation)
    }

    @Test func aChildPastTheLimitIsListedAndItsSiblingsSurvive() async throws {
        let tree = try DeepTree()
        let parts = tree.components(reaching: 895)
        let long = String(repeating: "L", count: 200)
        let siblings = (0..<20).map { "short-\($0).txt" }
        for name in siblings { try tree.file(parts + [name]) }
        try tree.file(parts + [long], "too long to open")
        try tree.file(parts + ["." + long], "hidden and too long")
        let folder = tree.url(parts)

        let shown = try DirectoryLister.list(folder, includeHidden: false)
        #expect(Set(shown.map(\.name)) == Set(siblings + [long]))
        let all = try DirectoryLister.list(folder, includeHidden: true)
        #expect(all.count == siblings.count + 2)
        let row = try #require(shown.first { $0.name == long })
        #expect(row.size == Int64("too long to open".utf8.count))
        #expect(!row.isFolder)

        let destination = try tree.folder(["dst"])
        let report = await FileTransfer(kind: .copy, sources: [row.url], destination: destination).run(resolveConflict: neverAsked)
        #expect(report.results.map(\.outcome) == [.failed(tooLong)], "acting on the row explains it")
    }

    /// `top/…/{short.txt, <over-limit>.txt}`: the walk reaches them through descriptors.
    private func treeWithOverLimitDescendant() throws -> (tree: DeepTree, top: URL, inner: [String], long: String) {
        let tree = try DeepTree()
        let inner = ["top"] + tree.components(reaching: 895)
        let long = String(repeating: "L", count: 240) + ".txt"
        try tree.file(inner + ["short.txt"], "short")
        try tree.file(inner + [long], "long")
        #expect(!PathLimits.fits(tree.url(inner + [long])))
        return (tree, tree.url(["top"]), inner, long)
    }

    @Test func aSameVolumeMoveKeepsDescendantsPastTheLimit() async throws {
        let (tree, top, _, _) = try treeWithOverLimitDescendant()
        let before = TreeManifest(of: top)
        let destination = try tree.folder(["dst"])
        let report = await FileTransfer(kind: .move, sources: [top], destination: destination).run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(TreeManifest(of: destination.appendingPathComponent("top")) == before)
    }

    @Test func aCopyReportsEachItemPastTheLimitAndCopiesTheRest() async throws {
        let (tree, top, inner, long) = try treeWithOverLimitDescendant()
        let before = TreeManifest(of: tree.root)
        let destination = try tree.folder(["d"])
        let asked = FailureRecorder()
        let report = await FileTransfer(kind: .copy, sources: [top], destination: destination)
            .run(resolveConflict: neverAsked, resolveFailure: { asked.add($0); return FailureDecision(.skip) })
        #expect(asked.all.map(\.kind) == [.pathTooLong])
        #expect(asked.all.first?.source.lastPathComponent == long)
        #expect(report.results.count == 1)
        if case .partial = report.results[0].outcome {} else { Issue.record("\(report.results[0].outcome)") }
        let arrived = TreeManifest(of: destination)
        let relative = inner.joined(separator: "/")
        #expect(arrived[relative + "/short.txt"] != nil)
        #expect(arrived[relative + "/" + long] == nil)
        let after = TreeManifest(of: tree.root)
        for path in before.paths { #expect(after[path] == before[path], "\(path.suffix(40))") }
    }

    @Test func aCrossVolumeMoveKeepsOriginalsPastTheLimit() async throws {
        let (tree, top, inner, long) = try treeWithOverLimitDescendant()
        let destination = try tree.folder(["d"])
        let report = await FileTransfer(kind: .move, sources: [top], destination: destination, sameVolume: { _, _ in false })
            .run(resolveConflict: neverAsked, resolveFailure: answerSkip)
        #expect(report.results.count == 1)
        #expect(report.results[0].outcome.isProblem)
        let left = TreeManifest(of: tree.root)
        let relative = inner.joined(separator: "/")
        #expect(left[relative + "/" + long] != nil, "the original past the limit is kept")
        #expect(left[relative + "/short.txt"] == nil, "what could be copied was moved")
        #expect(left["d/" + relative + "/short.txt"] != nil)
    }

    @Test func aPermanentDeleteRemovesDescendantsPastTheLimit() throws {
        let (tree, top, _, _) = try treeWithOverLimitDescendant()
        #expect(FileOps.removePermanently(top) == 0)
        #expect(TreeManifest(of: tree.root).paths.isEmpty)
    }

    @Test func aLongDestinationKeepsOriginalsOfACopyAndCrossVolumeMove() async throws {
        let tree = try DeepTree()
        let leaf = ["src", "Tree", String(repeating: "n", count: 240)]
        try tree.file(leaf + ["f.txt"], "data")
        let destination = try tree.folder(tree.components(reaching: 900))
        let source = tree.url(["src", "Tree"])
        let before = TreeManifest(of: source)

        let asked = FailureRecorder()
        _ = await FileTransfer(kind: .copy, sources: [source], destination: destination)
            .run(resolveConflict: neverAsked, resolveFailure: { asked.add($0); return FailureDecision(.skip) })
        #expect(asked.all.contains { $0.kind == .pathTooLong })
        #expect(TreeManifest(of: source) == before)

        let elsewhere = try tree.folder(["other"] + tree.components(reaching: 880))
        _ = await FileTransfer(kind: .move, sources: [source], destination: elsewhere, sameVolume: { _, _ in false })
            .run(resolveConflict: neverAsked, resolveFailure: answerSkip)
        #expect(TreeManifest(of: source) == before, "nothing is removed before its copy exists")
    }

    @Test func aSameVolumeRenameMovesATreeEvenIfItsDescendantsEndUpPastTheLimit() async throws {
        let tree = try DeepTree()
        try tree.file(["src", "Tree", String(repeating: "n", count: 240), "f.txt"], "data")
        let destination = try tree.folder(tree.components(reaching: 900))
        let source = tree.url(["src", "Tree"])
        let before = TreeManifest(of: source)
        let report = await FileTransfer(kind: .move, sources: [source], destination: destination).run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(TreeManifest(of: destination.appendingPathComponent("Tree")) == before, "only the two top paths count")
    }

    @Test func namesTooLongForTheCopySuffixAreExplainedNotTruncated() async throws {
        let fx = try Fixture()
        let name = String(repeating: "a", count: 250) + ".txt"
        try fx.file("box/" + name, "original")
        let asked = FailureRecorder()
        let duplicate = await fx.job(.copy, ["box/" + name], to: "box")
            .run(resolveConflict: neverAsked, resolveFailure: { asked.add($0); return FailureDecision(.skip) })
        #expect(asked.all.map(\.kind) == [.pathTooLong])
        #expect(duplicate.results[0].outcome.isProblem)
        #expect(fx.names("box") == [name])

        try fx.file("dst/" + name, "existing")
        let kept = FailureRecorder()
        let both = await fx.job(.copy, ["box/" + name], to: "dst")
            .run(resolveConflict: { _ in ConflictDecision(.keepBoth) }, resolveFailure: { kept.add($0); return FailureDecision(.skip) })
        #expect(kept.all.map(\.kind) == [.pathTooLong])
        #expect(both.results[0].outcome.isProblem)
        #expect(fx.read("box/" + name) == "original")
        #expect(fx.read("dst/" + name) == "existing")
        #expect(fx.names("dst") == [name])
    }

    @Test func aTreeThatFitsOnlyPrecomposedIsShownAndExplained() async throws {
        let tree = try DeepTree()
        let name = String(repeating: "\u{E9}", count: 100)   // 200 bytes as stored, 300 decomposed
        let parts = Array(repeating: name, count: 4)
        let file = try tree.file(parts + ["leaf.txt"], "still here")

        // Every level is shown; the last one can't be opened and says why.
        var folder = tree.root
        for _ in parts {
            let rows = try DirectoryLister.list(folder, includeHidden: true)
            let row = try #require(rows.first)
            #expect(row.isFolder)
            folder = row.url
        }
        #expect(throws: ListingError.pathTooLong(path: folder.path)) { try DirectoryLister.list(folder, includeHidden: true) }

        let typed = ([tree.root.path] + parts + ["leaf.txt"]).joined(separator: "/")
        expectTooLong(PathResolver().resolve(typed, relativeTo: nil))

        let destination = try tree.folder(["dst"])
        let report = await FileTransfer(kind: .copy, sources: [file], destination: destination).run(resolveConflict: neverAsked)
        #expect(report.results.map(\.outcome) == [.failed(tooLong)], "the decomposed path can't be handed to the kernel")
        #expect(TreeManifest(of: tree.root).paths.contains { $0.hasSuffix("/leaf.txt") }, "never lost")
    }
}

@Suite("Folder depth (FE-225)", .serialized)
struct FolderDepthTests {
    private static let pastTheCap = PathLimits.maxFolderDepth + 12
    private static let levels = Array(repeating: "d", count: pastTheCap)

    /// Runs a job on a tree nested past the cap and returns what it reported and asked.
    private func run(_ job: FileTransfer, conflict: @escaping FileTransfer.ConflictResolver = neverAsked) async -> (TransferReport, [FailureKind]) {
        let asked = FailureRecorder()
        let report = await finishing(job) {
            await job.run(resolveConflict: conflict, resolveFailure: { asked.add($0); return FailureDecision(.skip) })
        }
        return (report, asked.all.map(\.kind))
    }

    @Test func foldersPastTheCapFailAsClassifiedAndTheRestIsCopied() async throws {
        let tree = try DeepTree()
        try tree.file(["src"] + Self.levels + ["leaf.txt"], "bottom")
        let source = tree.url(["src"])
        let before = TreeManifest(of: source)
        let destination = try tree.folder(["dst"])
        let (report, asked) = await run(FileTransfer(kind: .copy, sources: [source], destination: destination))
        #expect(asked == [.pathTooLong])
        if case .partial = report.results[0].outcome {} else { Issue.record("\(report.results[0].outcome)") }
        #expect(TreeManifest(of: source) == before)
        let copied = TreeManifest(of: destination.appendingPathComponent("src"))
        #expect(copied.paths.map { $0.split(separator: "/").count }.max() == PathLimits.maxFolderDepth - 1)
    }

    @Test func aCrossVolumeMoveKeepsTheTreePastTheCap() async throws {
        let tree = try DeepTree()
        try tree.file(["src"] + Self.levels + ["leaf.txt"], "bottom")
        let source = tree.url(["src"])
        let before = TreeManifest(of: source)
        let destination = try tree.folder(["dst"])
        let (report, asked) = await run(FileTransfer(kind: .move, sources: [source], destination: destination, sameVolume: { _, _ in false }))
        #expect(asked == [.pathTooLong])
        #expect(report.results[0].outcome.isProblem)
        #expect(TreeManifest(of: source) == before, "the leaf never got a copy, so nothing above it may go")
    }

    @Test func aPackagePastTheCapIsRefusedWhole() async throws {
        let tree = try DeepTree()
        try tree.file(["Tool.app"] + Self.levels + ["leaf.txt"], "bottom")
        let destination = try tree.folder(["dst"])
        let (report, asked) = await run(FileTransfer(kind: .copy, sources: [tree.url(["Tool.app"])], destination: destination))
        #expect(asked == [.pathTooLong])
        #expect(report.results[0].outcome.isProblem)
        #expect(TreeManifest(of: destination).paths.isEmpty, "all or nothing")
    }

    @Test func aDeleteStopsAtTheCapWithAReason() throws {
        let tree = try DeepTree()
        try tree.file(["src"] + Self.levels + ["leaf.txt"], "bottom")
        #expect(FileOps.removePermanently(tree.url(["src"])) == ENAMETOOLONG)
        #expect(FileOps.exists(tree.url(["src"])))
    }

    @Test func aTwoSidedMergeStopsAtTheCapAndKeepsOriginals() async throws {
        let tree = try DeepTree()
        try tree.file(["src", "Box"] + Self.levels + ["new.txt"], "new")
        try tree.file(["dst", "Box"] + Self.levels + ["old.txt"], "old")
        let before = TreeManifest(of: tree.root)
        let job = FileTransfer(kind: .move, sources: [tree.url(["src", "Box"])], destination: tree.url(["dst"]))
        let (report, _) = await run(job, conflict: { _ in ConflictDecision(.merge) })
        #expect(report.results[0].outcome.isProblem)
        #expect(report.problems.contains { $0.outcome == .failed(tooLong) })
        #expect(TreeManifest(of: tree.root) == before, "nothing past the cap moved")
    }
}

@Suite("File-system limits (FE-225)", .serialized)
struct FileSystemLimitTests {
    /// Each name either arrives byte-identical where the report says, or is refused with its original kept.
    private func checkArrivedOrExplained(_ report: TransferReport, data: (URL) -> Data?) throws {
        for result in report.results {
            switch result.outcome {
            case .succeeded(let target):
                #expect(data(target) == data(result.source), "\(target.lastPathComponent)")
            case .skipped, .failed:
                #expect(FileOps.exists(result.source), "\(result.source.lastPathComponent): the original is kept")
            default:
                Issue.record("\(result.source.lastPathComponent): \(result.outcome)")
            }
        }
    }

    private func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// One of each name that a normalization-insensitive volume can hold side by side.
    private func sourceFolder(_ fx: Fixture) throws -> [URL] {
        try fx.folder("src")
        return try Array(Set(OddNames.all)).sorted().map { name in
            let url = fx.url("src").appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
    }

    @Test func oddNamesLongNamesAndTheRealTrashOnHFSPlus() async throws {
        guard let volume = await FormattedVolume.required("HFS+") else { return }
        let fx = try Fixture()
        let sources = try sourceFolder(fx)
        let onto = FileTransfer(kind: .copy, sources: sources, destination: volume.mount)
        try checkArrivedOrExplained(await finishing(onto) {
            await onto.run(resolveConflict: { _ in ConflictDecision(.skip) }, resolveFailure: answerSkip)
        }, data: read)

        // Under 255 UTF-16 units, as HFS+ counts, but over 255 UTF-8 bytes: APFS may refuse it.
        let wide = String(repeating: "\u{6F22}", count: 200)
        try Data("wide".utf8).write(to: volume.url(wide))
        #expect(try DirectoryLister.list(volume.mount, includeHidden: true).contains { $0.name == wide })
        try fx.folder("back")
        let back = FileTransfer(kind: .copy, sources: [volume.url(wide)], destination: fx.url("back"))
        try checkArrivedOrExplained(await finishing(back) {
            await back.run(resolveConflict: neverAsked, resolveFailure: answerSkip)
        }, data: read)
        #expect(fx.names("back").allSatisfy { $0 == wide }, "never shortened")

        let doomed = volume.url("to-trash.txt")
        try Data("gone soon".utf8).write(to: doomed)
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volume.mount, create: true)
        guard FileOps.sameVolume(trash, volume.mount) else { return }   // never reach the user's Trash
        let trashed = try SystemTrash.trash(doomed, into: nil)
        #expect(FileOps.sameVolume(trashed, volume.mount))
        #expect(!FileOps.exists(doomed))
        #expect(read(trashed) == Data("gone soon".utf8))
    }

    @Test func oddNamesOnExFAT() async throws {
        guard let volume = await FormattedVolume.required("ExFAT") else { return }
        let fx = try Fixture()
        let job = FileTransfer(kind: .copy, sources: try sourceFolder(fx), destination: volume.mount)
        let report = await finishing(job) {
            await job.run(resolveConflict: { _ in ConflictDecision(.skip) }, resolveFailure: answerSkip)
        }
        try checkArrivedOrExplained(report, data: read)
    }
}
