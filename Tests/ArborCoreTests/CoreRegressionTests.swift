import Foundation
import Testing
@testable import ArborCore

// Regression tests for core browsing and file-operation bugs (docs/features/qa-core.md).

private let unexpectedConflict: FileTransfer.ConflictResolver = { conflict in
    Issue.record("Unexpected conflict for \(conflict.destination.path)")
    return ConflictDecision(.cancel)
}

/// Answers every conflict with `choice` (a "careless" user who always clicks Replace).
private func answer(_ choice: ConflictChoice, counter: Counter? = nil) -> FileTransfer.ConflictResolver {
    { _ in counter?.increment(); return ConflictDecision(choice) }
}

/// The folder with its last component in another case; nil on case-sensitive volumes (tests return early).
private func caseVariant(_ url: URL) -> URL? {
    let name = url.lastPathComponent
    let flipped = url.deletingLastPathComponent().appendingPathComponent(name.uppercased() == name ? name.lowercased() : name.uppercased())
    return FileManager.default.fileExists(atPath: flipped.path) ? flipped : nil
}

@Suite("Same item reached through another spelling (QA-CORE-1)")
struct AliasedDestinationTests {
    @Test func copyIntoSameFolderSpelledInOtherCaseDuplicates() async throws {
        let fx = try Fixture()
        try fx.file("Docs/a.txt", "A")
        guard let other = caseVariant(fx.url("Docs")) else { return }   // case-sensitive volume
        let job = FileTransfer(kind: .copy, sources: [fx.url("Docs/a.txt")], destination: other, disposeReplaced: fx.disposer)
        let report = await job.run(resolveConflict: answer(.replace))
        #expect(fx.read("Docs/a.txt") == "A", "the source must survive")
        #expect(fx.names(".fixture-trash").isEmpty, "the source must never be thrown away as the 'existing' item")
        #expect(report.committed.first?.destination.lastPathComponent == "a - Copy.txt")
    }

    @Test func moveIntoSameFolderSpelledInOtherCaseIsANoOp() async throws {
        let fx = try Fixture()
        try fx.file("Docs/a.txt", "A")
        guard let other = caseVariant(fx.url("Docs")) else { return }
        let job = FileTransfer(kind: .move, sources: [fx.url("Docs/a.txt")], destination: other, disposeReplaced: fx.disposer)
        let report = await job.run(resolveConflict: answer(.replace))
        #expect(fx.read("Docs/a.txt") == "A")
        #expect(fx.names(".fixture-trash").isEmpty)
        guard case .skipped = report.results.first?.outcome else { Issue.record("expected a skip, got \(String(describing: report.results.first?.outcome))"); return }
    }

    @Test func copyThroughSymlinkedFolderDuplicates() async throws {
        let fx = try Fixture()
        try fx.file("real/a.txt", "A")
        try FileManager.default.createSymbolicLink(at: fx.url("alias"), withDestinationURL: fx.url("real"))
        let job = FileTransfer(kind: .copy, sources: [fx.url("real/a.txt")], destination: fx.url("alias"), disposeReplaced: fx.disposer)
        let report = await job.run(resolveConflict: answer(.replace))
        #expect(fx.read("real/a.txt") == "A")
        #expect(fx.names(".fixture-trash").isEmpty)
        #expect(report.committed.first?.destination.lastPathComponent == "a - Copy.txt")
    }

    @Test func moveFolderIntoSameParentSpelledDifferentlyKeepsContents() async throws {
        let fx = try Fixture()
        try fx.file("P/Sub/one.txt", "1")
        try fx.file("P/Sub/two.txt", "2")
        guard let other = caseVariant(fx.url("P")) else { return }
        let resolver: FileTransfer.ConflictResolver = { c in ConflictDecision(c.kind == .folderOverFolder ? .merge : .replace) }
        _ = await FileTransfer(kind: .move, sources: [fx.url("P/Sub")], destination: other, disposeReplaced: fx.disposer)
            .run(resolveConflict: resolver)
        #expect(fx.names("P/Sub") == ["one.txt", "two.txt"])
        #expect(fx.names(".fixture-trash").isEmpty)
    }

    @Test func folderIntoItsOwnSubfolderSpelledDifferentlyIsRefused() async throws {
        let fx = try Fixture()
        try fx.file("Box/Inner/keep.txt", "k")
        guard let other = caseVariant(fx.url("Box")) else { return }
        let into = other.appendingPathComponent("inner")
        for kind in [TransferKind.copy, .move] {
            let report = await FileTransfer(kind: kind, sources: [fx.url("Box")], destination: into, disposeReplaced: fx.disposer)
                .run(resolveConflict: unexpectedConflict)
            #expect(report.problems.count == 1, "\(kind) into its own subfolder")
        }
        #expect(fx.names("Box/Inner") == ["keep.txt"])
    }

    @Test func replacingAnAncestorSpelledDifferentlyIsRefused() async throws {
        let fx = try Fixture()
        try fx.file("p/x/x/inner.txt", "keep me")
        guard let other = caseVariant(fx.url("p")) else { return }
        let report = await FileTransfer(kind: .move, sources: [fx.url("p/x/x")], destination: other, disposeReplaced: fx.disposer)
            .run(resolveConflict: answer(.replace))
        #expect(report.problems.count == 1)
        #expect(fx.read("p/x/x/inner.txt") == "keep me")
    }
}

@Suite("Address bar spelling (QA-CORE-2)")
struct AddressSpellingTests {
    @Test func typedPathTakesTheSpellingOnDisk() throws {
        let fx = try Fixture()
        try fx.folder("Docs/Sub")
        try fx.file("Docs/Report.txt")
        let typed = fx.root.path + "/docs/SUB"
        guard FileManager.default.fileExists(atPath: typed) else { return }   // case-sensitive volume
        let resolver = PathResolver(homeDirectory: fx.root)
        #expect(resolver.resolve(typed, relativeTo: nil) == .success(.folder(fx.url("Docs/Sub"))))
        #expect(resolver.resolve("docs/report.TXT", relativeTo: fx.root) == .success(.file(fx.url("Docs/Report.txt"))))
        #expect(resolver.resolve("~/DOCS", relativeTo: nil) == .success(.folder(fx.url("Docs"))))
    }

    @Test func unicodeNormalizationAndSymlinksAreKept() throws {
        let fx = try Fixture()
        try fx.folder("Cafe\u{301}")   // decomposed on disk
        try FileManager.default.createSymbolicLink(at: fx.url("link"), withDestinationURL: fx.url("Cafe\u{301}"))
        let resolver = PathResolver(homeDirectory: fx.root)
        guard case .success(.folder(let url)) = resolver.resolve("Caf\u{E9}", relativeTo: fx.root) else { Issue.record("not resolved"); return }
        #expect(url.lastPathComponent.unicodeScalars.count == 5, "the stored (decomposed) name is used")
        // A symbolic link stays the folder the user typed; it is not swapped for its target.
        #expect(resolver.resolve("link", relativeTo: fx.root) == .success(.folder(fx.url("link"))))
    }
}

// MARK: - Other file systems (disk images)

/// A small privately mounted disk image with a chosen file system; nil if hdiutil can't (tests return early).
final class FormattedVolume {
    let image: URL
    let mount: URL

    init?(_ fileSystem: String, megabytes: Int = 20, mountedAt mountPoint: URL? = nil) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-qa-\(UUID().uuidString)")
        image = base.appendingPathExtension("dmg")
        mount = mountPoint ?? base
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard ScratchVolume.run("/usr/bin/hdiutil", ["create", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", "QA",
                                                     "-quiet", image.path]),
              ScratchVolume.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-quiet", "-mountpoint", mount.path, image.path]) else {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: mount)
            return nil
        }
    }

    /// Runs hdiutil on a GCD thread so it doesn't tie up the threads other tests' async work uses.
    static func make(_ fileSystem: String, megabytes: Int = 20, mountedAt mountPoint: URL? = nil) async -> FormattedVolume? {
        final class Box: @unchecked Sendable { var volume: FormattedVolume? }
        let box = Box()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                box.volume = FormattedVolume(fileSystem, megabytes: megabytes, mountedAt: mountPoint)
                done.resume()
            }
        }
        return box.volume
    }

    func url(_ path: String) -> URL { mount.appendingPathComponent(path) }
    func names(_ path: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(path).path)) ?? []).filter { !$0.hasPrefix("._") && $0 != ".fseventsd" && !$0.hasPrefix(".Trash") && $0 != ".Spotlight-V100" }.sorted()
    }

    deinit {
        _ = ScratchVolume.run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path])
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(at: mount)
    }
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferFailure] = []
    func add(_ f: TransferFailure) { lock.withLock { items.append(f) } }
    var all: [TransferFailure] { lock.withLock { items } }
}

@Suite("Copy and move across file systems (QA-CORE)", .serialized)
struct CrossFileSystemTests {
    /// Case-sensitive APFS holds "a.txt" and "A.txt"; the default (case-insensitive) volume can't.
    @Test func caseTwinsFromCaseSensitiveVolumeNeverOverwriteEachOther() async throws {
        guard let cs = await FormattedVolume.make("Case-sensitive APFS") else { return }
        let fx = try Fixture()
        try write("lower", cs.url("Twins/a.txt"))
        try write("UPPER", cs.url("Twins/A.txt"))
        try fx.folder("dst")
        for kind in [TransferKind.copy, .move] {
            let into = fx.url("dst/\(kind)")
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            let failures = FailureRecorder()
            let report = await FileTransfer(kind: kind, sources: [cs.url("Twins")], destination: into, disposeReplaced: fx.disposer)
                .run(resolveConflict: unexpectedConflict, resolveFailure: { f in failures.add(f); return FailureDecision(.skip) })
            let arrived = fx.names("dst/\(kind)/Twins")
            #expect(arrived.count == 1, "\(kind): one twin arrives")
            let kept = read(into.appendingPathComponent("Twins/\(arrived.first ?? "")"))
            #expect(kept == "lower" || kept == "UPPER")
            #expect(!report.problems.isEmpty, "\(kind): the twin that couldn't be written is reported")
            #expect(failures.all.count == 1, "\(kind): asked once about the twin")
        }
        // After the move, the twin that didn't arrive is still at the source.
        #expect(cs.names("Twins").count == 1)
        #expect(fx.names(".fixture-trash").isEmpty)
    }

    @Test func namesExFATRejectsAreReportedAndOriginalsKept() async throws {
        guard let vol = await FormattedVolume.make("ExFAT") else { return }
        let fx = try Fixture()
        try fx.file("src/ok.txt", "ok")
        try fx.file("src/what?.txt", "q")
        try fx.file("src/a:b.txt", "colon")
        let failures = FailureRecorder()
        let report = await FileTransfer(kind: .move, sources: ["ok.txt", "what?.txt", "a:b.txt"].map { fx.url("src/\($0)") },
                                        destination: vol.mount, disposeReplaced: fx.disposer)
            .run(resolveConflict: unexpectedConflict, resolveFailure: { f in failures.add(f); return FailureDecision(.skip) })
        #expect(vol.names().contains("ok.txt"))
        #expect(!fx.exists("src/ok.txt"), "moved")
        for (index, name) in ["what?.txt", "a:b.txt"].enumerated() {
            if vol.names().contains(name) {
                #expect(!fx.exists("src/\(name)"))   // this exFAT driver accepted the name
            } else {
                #expect(fx.read("src/\(name)") != nil, "\(name): original kept when the copy was refused")
                #expect(report.results[index + 1].outcome.isProblem)
            }
        }
        for failure in failures.all { #expect(!failure.summary.isEmpty) }
    }

    @Test func caseOnlyRenameOnOtherFileSystems() async throws {
        for fs in ["ExFAT", "Case-sensitive APFS", "HFS+"] {
            guard let vol = await FormattedVolume.make(fs) else { continue }
            try write("x", vol.url("report.txt"))
            let renamed = try Renamer.rename(vol.url("report.txt"), to: "Report.txt")
            #expect(renamed.lastPathComponent == "Report.txt", "\(fs)")
            #expect(vol.names() == ["Report.txt"], "\(fs): \(vol.names())")
        }
    }

    @Test func crossVolumeFolderMergeKeepsEverything() async throws {
        guard let vol = await FormattedVolume.make("ExFAT") else { return }
        let fx = try Fixture()
        try fx.file("src/Photos/new.jpg", "N")
        try fx.file("src/Photos/same.jpg", "incoming")
        try write("O", vol.url("photos/old.jpg"))
        try write("existing", vol.url("photos/same.jpg"))
        let resolver: FileTransfer.ConflictResolver = { c in ConflictDecision(c.kind == .folderOverFolder ? .merge : .skip) }
        let report = await FileTransfer(kind: .move, sources: [fx.url("src/Photos")], destination: vol.mount, disposeReplaced: fx.disposer)
            .run(resolveConflict: resolver)
        #expect(vol.names("photos") == ["new.jpg", "old.jpg", "same.jpg"])
        #expect(read(vol.url("photos/same.jpg")) == "existing", "skipped file untouched")
        #expect(fx.read("src/Photos/same.jpg") == "incoming", "skipped original stays")
        #expect(!fx.exists("src/Photos/new.jpg"), "moved original removed")
        _ = report
    }
}
