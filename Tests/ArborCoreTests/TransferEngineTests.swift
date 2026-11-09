import Foundation
import Testing
@testable import ArborCore

// MARK: - Helpers

let MB: Int64 = 1 << 20

/// Writes `size` bytes of non-repeating data (so APFS can't dedupe and copies are real).
func writeDense(_ url: URL, size: Int64) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    var chunk = Data(count: Int(MB))
    var written: Int64 = 0
    while written < size {
        chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let n = Int(min(MB, size - written))
        try handle.write(contentsOf: chunk.prefix(n))
        written += Int64(n)
    }
    try handle.close()
}

private func sameContents(_ a: URL, _ b: URL) throws -> Bool {
    let ha = try FileHandle(forReadingFrom: a), hb = try FileHandle(forReadingFrom: b)
    defer { try? ha.close(); try? hb.close() }
    while true {
        let da = try ha.read(upToCount: Int(MB)) ?? Data(), db = try hb.read(upToCount: Int(MB)) ?? Data()
        if da != db { return false }
        if da.isEmpty { return true }
    }
}

private func stat(_ url: URL) -> Darwin.stat {
    var info = Darwin.stat()
    lstat(url.path, &info)
    return info
}

/// Thread-safe recorder for progress callbacks (they arrive on the job's worker thread).
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferProgress] = []
    func add(_ p: TransferProgress) { lock.withLock { items.append(p) } }
    var all: [TransferProgress] { lock.withLock { items } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// True the first time only.
    func trip() -> Bool { lock.withLock { defer { value = true }; return !value } }
    var isSet: Bool { lock.withLock { value } }
}

let neverAsked: FileTransfer.ConflictResolver = { conflict in
    Issue.record("Unexpected conflict for \(conflict.destination.lastPathComponent)")
    return ConflictDecision(.cancel)
}

let noClone = FileTransfer.Options(allowClone: false, progressInterval: 0)

extension Fixture {
    func job(_ kind: TransferKind, _ sources: [String], to dest: String, options: FileTransfer.Options = noClone,
                  sameVolume: FileTransfer.VolumeCheck? = nil, journal: JobJournal? = nil) -> FileTransfer {
        FileTransfer(kind: kind, sources: sources.map(url), destination: url(dest), disposeReplaced: disposer,
                     sameVolume: sameVolume ?? { FileOps.sameVolume($0, $1) }, journal: journal, options: options)
    }
}

/// A real HFS+ volume for cross-volume moves and disk-full errors; nil (test skipped) if mounting fails.
final class ScratchVolume {
    let image: URL
    let mount: URL

    init?(megabytes: Int) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-vol-\(UUID().uuidString)")
        image = base.appendingPathExtension("dmg")
        mount = base
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "ArborTest", "-quiet", image.path]),
              Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-quiet", "-mountpoint", mount.path, image.path]) else {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: mount)
            return nil
        }
    }

    deinit {
        _ = Self.run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path])
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(at: mount)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Byte progress, cancel, pause (FE-114, FE-115, FE-257)

@Suite("Transfer progress, cancel and pause (FE-114, FE-115, FE-257)", .serialized)
struct TransferProgressTests {
    @Test func byteLevelProgressFor200MBFile() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 200 * MB)
        try fx.folder("dst")
        let log = ProgressLog()
        let report = await fx.job(.copy, ["src/big.bin"], to: "dst").run(progress: { log.add($0) }, resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        let all = log.all
        #expect(all.first?.phase == .discovering)
        let running = all.filter { $0.phase == .running && $0.bytesTotal != nil }
        #expect(running.allSatisfy { $0.bytesTotal == 200 * MB })
        let distinct = Set(running.map(\.bytesDone))
        #expect(distinct.count >= 3, "intermediate byte counts are reported, got \(distinct.count)")
        #expect(zip(running, running.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }, "monotonic")
        #expect(all.last?.bytesDone == 200 * MB)
        #expect(all.last?.fraction == 1)
        #expect(try sameContents(fx.url("src/big.bin"), fx.url("dst/big.bin")))
    }

    @Test func cancelMidFileLeavesNoPartialFile() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 200 * MB)
        try fx.file("src/after.txt", "later")
        try fx.folder("dst")
        let transfer = fx.job(.copy, ["src/big.bin", "src/after.txt"], to: "dst")
        let seenMidFile = Flag()
        let report = await transfer.run(progress: { p in
            if p.phase == .running, p.bytesDone > 30 * MB, p.bytesDone < 190 * MB, seenMidFile.trip() { transfer.cancel() }
        }, resolveConflict: neverAsked)
        #expect(seenMidFile.isSet, "cancelled while the file was half copied")
        #expect(report.wasCancelled)
        #expect(report.results.map(\.outcome) == [.cancelled, .cancelled])
        #expect(fx.names("dst").isEmpty, "no partial big.bin, and after.txt never started")
        #expect(stat(fx.url("src/big.bin")).st_size == 200 * MB, "source untouched")
    }

    @Test func cancelMidFolderKeepsFinishedFilesOnly() async throws {
        let fx = try Fixture()
        try fx.file("src/F/a.txt", "A")
        try writeDense(fx.url("src/F/b.bin"), size: 40 * MB)
        try fx.file("src/F/c.txt", "C")
        try fx.folder("dst")
        let transfer = fx.job(.copy, ["src/F"], to: "dst")
        let flag = Flag()
        let report = await transfer.run(progress: { p in
            if p.phase == .running, p.currentName == "b.bin", p.bytesDone > 5 * MB, flag.trip() { transfer.cancel() }
        }, resolveConflict: neverAsked)
        #expect(report.wasCancelled)
        guard case .partial(let url, _) = report.results.first?.outcome else { Issue.record("expected partial"); return }
        #expect(url.lastPathComponent == "F")
        // Directory order isn't fixed, but b.bin is never left half written.
        #expect(!fx.exists("dst/F/b.bin"))
        #expect(fx.names("src/F") == ["a.txt", "b.bin", "c.txt"])
    }

    @Test func pauseBlocksAndResumeCompletes() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 64 * MB)
        try fx.folder("dst")
        let transfer = fx.job(.copy, ["src/big.bin"], to: "dst")
        let log = ProgressLog()
        let paused = Flag()
        let job = Task {
            await transfer.run(progress: { p in
                log.add(p)
                if p.phase == .running, p.bytesDone > 8 * MB, paused.trip() { transfer.pause() }
            }, resolveConflict: neverAsked)
        }
        for _ in 0..<12_000 where !transfer.isPaused { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(transfer.isPaused)
        let atPause = transfer.currentProgress.bytesDone
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(transfer.currentProgress.bytesDone == atPause, "no bytes move while paused")
        #expect(transfer.currentProgress.phase == .paused)
        #expect(atPause < 64 * MB)
        transfer.resume()
        let report = await job.value
        #expect(report.problems.isEmpty)
        #expect(log.all.contains { $0.phase == .paused }, "the paused state was reported")
        #expect(try sameContents(fx.url("src/big.bin"), fx.url("dst/big.bin")))
    }

    @Test func cancelWhilePausedStops() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 32 * MB)
        try fx.folder("dst")
        let transfer = fx.job(.copy, ["src/big.bin"], to: "dst")
        let flag = Flag()
        let job = Task {
            await transfer.run(progress: { p in
                if p.phase == .running, p.bytesDone > 2 * MB, flag.trip() { transfer.pause() }
            }, resolveConflict: neverAsked)
        }
        for _ in 0..<12_000 where !transfer.isPaused { try await Task.sleep(nanoseconds: 10_000_000) }
        transfer.cancel()
        let report = await job.value
        #expect(report.wasCancelled)
        #expect(!fx.exists("dst/big.bin"))
    }

    @Test func sparseFileStaysSparse() async throws {
        let fx = try Fixture()
        let src = fx.url("src/sparse.img")
        try fx.folder("src")
        try fx.folder("dst")
        let fd = open(src.path, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        ftruncate(fd, off_t(200 * MB))
        _ = "head".withCString { pwrite(fd, $0, 4, 0) }
        _ = "tail".withCString { pwrite(fd, $0, 4, off_t(200 * MB - 4)) }
        close(fd)
        let log = ProgressLog()
        let report = await fx.job(.copy, ["src/sparse.img"], to: "dst").run(progress: { log.add($0) }, resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        let copy = stat(fx.url("dst/sparse.img"))
        #expect(copy.st_size == 200 * MB)
        #expect(Int64(copy.st_blocks) * 512 < 8 * MB, "holes were preserved (\(copy.st_blocks) blocks)")
        #expect(log.all.last?.bytesDone == 200 * MB, "progress reaches the logical size")
        #expect(try sameContents(src, fx.url("dst/sparse.img")))
    }

    @Test func manySmallFilesCountEveryEntry() async throws {
        let fx = try Fixture()
        for d in 0..<10 { for f in 0..<50 { try fx.file("src/Tree/d\(d)/f\(f).txt", "file \(d)-\(f)") } }
        try fx.folder("dst")
        let log = ProgressLog()
        let report = await fx.job(.copy, ["src/Tree"], to: "dst").run(progress: { log.add($0) }, resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        let last = try #require(log.all.last)
        #expect(last.itemsTotal == 1 + 10 + 500)
        #expect(last.itemsDone == last.itemsTotal)
        #expect(last.itemsRemaining == 0)
        for d in 0..<10 { #expect(fx.names("dst/Tree/d\(d)").count == 50) }
        #expect(fx.read("dst/Tree/d7/f42.txt") == "file 7-42")
    }

    @Test func discoveryCanBeCancelled() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt")
        try fx.folder("dst")
        let transfer = fx.job(.copy, ["src/a.txt"], to: "dst")
        transfer.cancel()
        let report = await transfer.run(resolveConflict: neverAsked)
        #expect(report.wasCancelled)
        #expect(fx.names("dst").isEmpty)
        let control = TransferControl()
        control.cancel()
        try fx.file("big/x/1"); try fx.file("big/x/2")
        for i in 0..<300 { try fx.file("big/y/\(i)") }
        #expect(TransferDiscovery.measure(fx.url("big"), control: control) == nil)
        #expect(TransferDiscovery.measure(fx.url("big"))?.items == 1 + 2 + 2 + 300)
    }

    @Test func throttleSlowsTheCopy() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/f.bin"), size: 8 * MB)
        try fx.folder("dst")
        let start = Date()
        _ = await fx.job(.copy, ["src/f.bin"], to: "dst", options: .init(allowClone: false, bytesPerSecondLimit: 16 * MB, progressInterval: 0))
            .run(resolveConflict: neverAsked)
        #expect(Date().timeIntervalSince(start) > 0.35)
    }
}

// MARK: - Metadata and links (FE-123, FE-124)

@Suite("Copy fidelity (FE-123, FE-124)")
struct TransferFidelityTests {
    @Test func preservesXattrsPermissionsDatesTagsAndFlags() async throws {
        let fx = try Fixture()
        let src = try fx.file("src/doc.txt", "content")
        try (src as NSURL).setResourceValue(["Red", "Project X"], forKey: .tagNamesKey)
        #expect(setxattr(src.path, "com.example.arbor", "value", 5, 0, 0) == 0)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let modified = Date(timeIntervalSince1970: 1_200_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified, .posixPermissions: 0o640],
                                              ofItemAtPath: src.path)
        #expect(chflags(src.path, UInt32(UF_HIDDEN)) == 0)
        let folder = try fx.folder("src/Box")
        try fx.file("src/Box/inner.txt")
        try FileManager.default.setAttributes([.modificationDate: modified, .posixPermissions: 0o750], ofItemAtPath: folder.path)
        try fx.folder("dst")

        for options in [noClone, FileTransfer.Options()] {
            let dest = "dst/\(options.allowClone ? "clone" : "copy")"
            try fx.folder(dest)
            let report = await fx.job(.copy, ["src/doc.txt", "src/Box"], to: dest, options: options).run(resolveConflict: neverAsked)
            #expect(report.problems.isEmpty)
            let copy = fx.url("\(dest)/doc.txt")
            let v = try copy.resourceValues(forKeys: [.tagNamesKey, .creationDateKey, .contentModificationDateKey])
            #expect(v.tagNames == ["Red", "Project X"])
            #expect(v.creationDate == created, "creation date (\(options.allowClone ? "clone" : "copy"))")
            #expect(v.contentModificationDate == modified)
            var buffer = [CChar](repeating: 0, count: 16)
            #expect(getxattr(copy.path, "com.example.arbor", &buffer, 16, 0, 0) == 5)
            let info = stat(copy)
            #expect(info.st_mode & 0o777 == 0o640)
            #expect(info.st_flags & UInt32(UF_HIDDEN) != 0)
            let box = fx.url("\(dest)/Box")
            #expect(stat(box).st_mode & 0o777 == 0o750)
            #expect(try box.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified,
                    "folder date applied after its contents")
        }
    }

    @Test func symlinksAreCopiedAsLinksNeverFollowed() async throws {
        let fx = try Fixture()
        try fx.file("outside/secret/big.txt", "not to be copied")
        try fx.folder("src/F")
        try FileManager.default.createSymbolicLink(atPath: fx.url("src/F/link").path, withDestinationPath: fx.url("outside/secret").path)
        try FileManager.default.createSymbolicLink(atPath: fx.url("src/top-link").path, withDestinationPath: "relative/target")
        try fx.folder("dst")
        let report = await fx.job(.copy, ["src/F", "src/top-link"], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        #expect(stat(fx.url("dst/F/link")).st_mode & S_IFMT == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fx.url("dst/F/link").path) == fx.url("outside/secret").path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fx.url("dst/top-link").path) == "relative/target")
        #expect(TransferDiscovery.measure(fx.url("src/F"))?.items == 2, "discovery doesn't walk through the link")
    }

    @Test func hardLinksBecomeIndependentCopies() async throws {
        let fx = try Fixture()
        try fx.file("src/H/a.txt", "shared")
        #expect(link(fx.url("src/H/a.txt").path, fx.url("src/H/b.txt").path) == 0)
        try fx.folder("dst")
        _ = await fx.job(.copy, ["src/H"], to: "dst").run(resolveConflict: neverAsked)
        let a = stat(fx.url("dst/H/a.txt")), b = stat(fx.url("dst/H/b.txt"))
        #expect(a.st_ino != b.st_ino)
        #expect(a.st_nlink == 1 && b.st_nlink == 1)
        try "edited".write(to: fx.url("dst/H/a.txt"), atomically: false, encoding: .utf8)
        #expect(fx.read("dst/H/b.txt") == "shared")
    }

    @Test func packagesAreCopiedAsUnits() async throws {
        let fx = try Fixture()
        try fx.file("src/Tool.app/Contents/Info.plist", "<plist/>")
        try fx.file("src/Tool.app/Contents/MacOS/tool", "bin")
        try fx.file("src/Tool.app/Contents/Resources/secret.dat", "locked")
        try fx.folder("dst")
        #expect(CopyEngine.isPackage(fx.url("src/Tool.app")))
        // A package that can't be copied completely is removed, not left half there.
        chmod(fx.url("src/Tool.app/Contents/Resources/secret.dat").path, 0)
        defer { chmod(fx.url("src/Tool.app/Contents/Resources/secret.dat").path, 0o644) }
        let failed = await fx.job(.copy, ["src/Tool.app"], to: "dst").run(resolveConflict: neverAsked)
        guard case .failed = failed.results.first?.outcome else { Issue.record("expected failure, got \(String(describing: failed.results.first?.outcome))"); return }
        #expect(!fx.exists("dst/Tool.app"))
        chmod(fx.url("src/Tool.app/Contents/Resources/secret.dat").path, 0o644)
        let moved = await fx.job(.move, ["src/Tool.app"], to: "dst", sameVolume: { _, _ in false }).run(resolveConflict: neverAsked)
        #expect(moved.problems.isEmpty)
        #expect(fx.read("dst/Tool.app/Contents/MacOS/tool") == "bin")
        #expect(!fx.exists("src/Tool.app"), "original package deleted only after the whole copy")
    }
}

// MARK: - Moves (FE-122)

@Suite("Moves (FE-122)")
struct TransferMoveTests {
    @Test func sameVolumeMoveIsARename() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "A")
        try fx.folder("dst")
        let inode = stat(fx.url("src/a.txt")).st_ino
        let log = ProgressLog()
        let report = await fx.job(.move, ["src/a.txt"], to: "dst").run(progress: { log.add($0) }, resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        #expect(stat(fx.url("dst/a.txt")).st_ino == inode)
        #expect(!log.all.contains { $0.phase == .discovering }, "no discovery for renames")
    }

    @Test func simulatedCrossVolumeMoveCopiesThenDeletesEachOriginal() async throws {
        let fx = try Fixture()
        try fx.file("src/F/a.txt", "A")
        try fx.file("src/F/sub/b.txt", "B")
        try fx.file("src/F/.DS_Store", "finder")
        let modified = Date(timeIntervalSince1970: 1_300_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fx.url("src/F/a.txt").path)
        try fx.folder("dst")
        let inode = stat(fx.url("src/F/a.txt")).st_ino
        let report = await fx.job(.move, ["src/F"], to: "dst", sameVolume: { _, _ in false }).run(resolveConflict: neverAsked)
        #expect(report.problems.isEmpty)
        #expect(report.committed.map(\.destination.lastPathComponent) == ["F"])
        #expect(!fx.exists("src/F"))
        #expect(fx.read("dst/F/sub/b.txt") == "B")
        #expect(stat(fx.url("dst/F/a.txt")).st_ino != inode, "really copied, not renamed")
        #expect(try fx.url("dst/F/a.txt").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test func crossVolumeMoveKeepsOriginalsThatFailed() async throws {
        let fx = try Fixture()
        try fx.file("src/F/ok.txt", "ok")
        try fx.file("src/F/unreadable.txt", "u")
        chmod(fx.url("src/F/unreadable.txt").path, 0)
        defer { chmod(fx.url("src/F/unreadable.txt").path, 0o644) }
        try fx.folder("dst")
        let report = await fx.job(.move, ["src/F"], to: "dst", sameVolume: { _, _ in false }).run(resolveConflict: neverAsked)
        guard case .partial = report.results.first?.outcome else { Issue.record("expected partial"); return }
        #expect(report.details.map(\.source.lastPathComponent) == ["unreadable.txt"])
        #expect(fx.exists("src/F/unreadable.txt"), "a failed item's original is never removed")
        #expect(!fx.exists("src/F/ok.txt"))
        #expect(fx.read("dst/F/ok.txt") == "ok")
        #expect(!fx.exists("dst/F/unreadable.txt"))
    }

    @Test func realCrossVolumeMoveAndDiskFull() async throws {
        guard let volume = ScratchVolume(megabytes: 6) else { return }   // hdiutil unavailable: skipped
        let fx = try Fixture()
        try fx.file("src/small.txt", "small")
        try writeDense(fx.url("src/big.bin"), size: 12 * MB)
        let transfer = FileTransfer(kind: .move, sources: [fx.url("src/small.txt"), fx.url("src/big.bin")],
                                    destination: volume.mount, disposeReplaced: fx.disposer)
        let asked = ProgressLog()
        let report = await transfer.run(resolveConflict: neverAsked, resolveFailure: { failure in
            asked.add(TransferProgress(completed: 0, total: 0, currentName: failure.kind.rawValue))
            #expect(failure.kind == .diskFull)
            #expect(!failure.allowsSkip)
            #expect(failure.message(verb: "move", volumeName: "ArborTest").contains("not enough space"))
            return FailureDecision(.cancel)
        })
        #expect(asked.all.count == 1)
        #expect(report.results.first?.outcome == .succeeded(volume.mount.appendingPathComponent("small.txt")))
        #expect(!fx.exists("src/small.txt"))
        #expect(report.results.last?.outcome == .cancelled)
        #expect(stat(fx.url("src/big.bin")).st_size == 12 * MB, "original kept when the copy can't finish")
        #expect(!FileManager.default.fileExists(atPath: volume.mount.appendingPathComponent("big.bin").path), "no partial file")
    }
}

// MARK: - Conflicts (FE-117, FE-119, FE-250, FE-255)

final class BatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[Conflict]] = []
    func add(_ b: [Conflict]) { lock.withLock { batches.append(b) } }
    var all: [[Conflict]] { lock.withLock { batches } }
}

@Suite("Conflict batches and revalidation (FE-117, FE-119, FE-250)")
struct TransferConflictTests {
    @Test func conflictsAtOneLevelAreAskedTogether() async throws {
        let fx = try Fixture()
        for n in ["a", "b", "c"] { try fx.file("src/\(n).txt", "new \(n)"); try fx.file("dst/\(n).txt", "old \(n)") }
        try fx.file("src/d.txt", "new d")
        let log = BatchLog()
        let report = await fx.job(.copy, ["src/a.txt", "src/b.txt", "src/c.txt", "src/d.txt"], to: "dst")
            .run(resolveConflicts: { batch in
                log.add(batch)
                return [ConflictDecision(.replace), ConflictDecision(.skip), ConflictDecision(.keepBoth)]
            })
        #expect(log.all.count == 1)
        #expect(log.all.first?.map(\.destination.lastPathComponent) == ["a.txt", "b.txt", "c.txt"])
        #expect(log.all.first?.allSatisfy { $0.sourceStamp != nil && $0.destinationStamp != nil } == true)
        #expect(fx.read("dst/a.txt") == "new a")
        #expect(fx.read("dst/b.txt") == "old b")
        #expect(fx.read("dst/c.txt") == "old c")
        #expect(fx.read("dst/c (2).txt") == "new c")
        #expect(fx.read("dst/d.txt") == "new d")
        #expect(report.committed.map(\.destination.lastPathComponent) == ["a.txt", "c (2).txt", "d.txt"], "actual committed names (FE-255)")
    }

    @Test func changedDestinationIsAskedAgain() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "incoming")
        try fx.file("dst/a.txt", "old")
        let asked = Counter()
        let dest = fx.url("dst/a.txt")
        let report = await fx.job(.copy, ["src/a.txt"], to: "dst").run(resolveConflict: { _ in
            asked.increment()
            if asked.count == 1 {
                // Someone saves a newer version while the dialog is open.
                try? "edited meanwhile, longer".write(to: dest, atomically: true, encoding: .utf8)
                return ConflictDecision(.replace)
            }
            return ConflictDecision(.skip)
        })
        #expect(asked.count == 2)
        #expect(fx.read("dst/a.txt") == "edited meanwhile, longer", "stale Replace didn't clobber newer work")
        guard case .skipped = report.results.first?.outcome else { Issue.record("expected skip"); return }
    }

    @Test func vanishedConflictCopiesUnderTheOriginalName() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "incoming")
        try fx.file("dst/a.txt", "old")
        let dest = fx.url("dst/a.txt")
        _ = await fx.job(.copy, ["src/a.txt"], to: "dst").run(resolveConflict: { _ in
            try? FileManager.default.removeItem(at: dest)
            return ConflictDecision(.keepBoth)
        })
        #expect(fx.names("dst") == ["a.txt"])
        #expect(fx.read("dst/a.txt") == "incoming")
    }

    @Test func duplicateNamesAmongSourcesAreCaughtLate() async throws {
        let fx = try Fixture()
        try fx.file("one/a.txt", "1")
        try fx.file("two/a.txt", "2")
        try fx.folder("dst")
        let asked = Counter()
        let report = await fx.job(.copy, ["one/a.txt", "two/a.txt"], to: "dst").run(resolveConflict: { _ in
            asked.increment()
            return ConflictDecision(.keepBoth)
        })
        #expect(asked.count == 1)
        #expect(report.committed.map(\.destination.lastPathComponent) == ["a.txt", "a (2).txt"])
    }
}

// MARK: - Failures (FE-120, FE-121)

final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferFailure] = []
    func add(_ f: TransferFailure) { lock.withLock { items.append(f) } }
    var all: [TransferFailure] { lock.withLock { items } }
}

@Suite("Failures: retry, skip, cancel (FE-120, FE-121)")
struct TransferFailureTests {
    @Test func destinationAccessDeniedThenRetrySucceeds() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "A")
        let dst = try fx.folder("dst")
        chmod(dst.path, 0o555)
        defer { chmod(dst.path, 0o755) }
        let log = FailureLog()
        let report = await fx.job(.copy, ["src/a.txt"], to: "dst").run(resolveConflict: neverAsked, resolveFailure: { failure in
            log.add(failure)
            chmod(dst.path, 0o755)   // the user fixes permissions, then clicks Try Again
            return FailureDecision(.retry)
        })
        #expect(log.all.map(\.kind) == [.destinationAccessDenied])
        #expect(log.all.first?.title == "Destination Folder Access Denied")
        #expect(report.problems.isEmpty)
        #expect(fx.read("dst/a.txt") == "A")
    }

    @Test func skipForAllAsksOncePerKind() async throws {
        let fx = try Fixture()
        for n in ["a", "b", "c"] {
            try fx.file("src/\(n).txt", n)
        }
        chmod(fx.url("src/a.txt").path, 0)
        chmod(fx.url("src/b.txt").path, 0)
        defer { chmod(fx.url("src/a.txt").path, 0o644); chmod(fx.url("src/b.txt").path, 0o644) }
        try fx.folder("dst")
        let log = FailureLog()
        let report = await fx.job(.copy, ["src/a.txt", "src/b.txt", "src/c.txt"], to: "dst")
            .run(resolveConflict: neverAsked, resolveFailure: { failure in
                log.add(failure)
                return FailureDecision(.skip, applyToRemaining: true)
            })
        #expect(log.all.count == 1)
        #expect(log.all.first?.kind == .accessDenied)
        #expect(report.problems.count == 2)
        #expect(fx.names("dst") == ["c.txt"])
        let last = report.results.last
        #expect(last?.outcome == .succeeded(fx.url("dst/c.txt")))
    }

    @Test func cancelFromFailureStopsTheJob() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt")
        try fx.file("src/b.txt")
        chmod(fx.url("src/a.txt").path, 0)
        defer { chmod(fx.url("src/a.txt").path, 0o644) }
        try fx.folder("dst")
        let report = await fx.job(.copy, ["src/a.txt", "src/b.txt"], to: "dst")
            .run(resolveConflict: neverAsked, resolveFailure: { _ in FailureDecision(.cancel) })
        #expect(report.wasCancelled)
        #expect(fx.names("dst").isEmpty)
    }

    @Test func classification() throws {
        let fx = try Fixture()
        let src = try fx.file("a.txt")
        let busy = TransferFailure.classify(errno: EBUSY, source: src, destination: nil, stage: .copying)
        #expect(busy.kind == .inUse && busy.title == "File In Use" && busy.hint == "Close the file and try again.")
        let full = TransferFailure.classify(errno: ENOSPC, source: src, destination: fx.url("d/a.txt"), stage: .copying, bytesNeeded: 5 << 20)
        #expect(full.kind == .diskFull)
        #expect(full.message(verb: "copy", volumeName: "USB").contains("5.00 MB is needed to copy these items"))
        let gone = TransferFailure.classify(errno: ENOENT, source: fx.url("missing"), destination: nil, stage: .copying)
        #expect(gone.kind == .notFound && gone.title == "Item Not Found")
        let other = TransferFailure.classify(errno: EIO, source: src, destination: nil, stage: .copying)
        #expect(other.title == "Interrupted Action" && other.hint.hasPrefix("Error 5:"))
        #expect(TransferFailure.classify(errno: EROFS, source: src, destination: nil, stage: .copying).allowsSkip == false)
    }
}

// MARK: - Journal (FE-125, FE-128, FE-241)

@Suite("Job journal (FE-125, FE-128, FE-241)")
struct JobJournalTests {
    @Test func journalIsRemovedWhenTheJobEnds() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt")
        try fx.folder("dst")
        let dir = fx.url("journal")
        let journal = try JobJournal(directory: dir, kind: .copy, sources: [fx.url("src/a.txt")], destination: fx.url("dst"))
        #expect(fx.names("journal").count == 1)
        _ = await fx.job(.copy, ["src/a.txt"], to: "dst", journal: journal).run(resolveConflict: neverAsked)
        #expect(fx.names("journal").isEmpty)
    }

    @Test func interruptedJobDistinguishesCompletedNotDoneAndUncertain() throws {
        let fx = try Fixture()
        let sources = ["a", "b", "c", "d", "gone"].map { fx.url("src/\($0).txt") }
        for s in sources.dropLast() { try fx.file("src/\(s.lastPathComponent)") }
        let dir = fx.url("journal")
        let journal = try JobJournal(directory: dir, kind: .move, sources: sources, destination: fx.url("dst"), pid: 999_999)
        journal.record(0, .started, destination: fx.url("dst/a.txt"))
        journal.record(0, .committed, destination: fx.url("dst/a (2).txt"))
        journal.record(1, .started, destination: fx.url("dst/b.txt"))
        journal.record(3, .failed, note: "Access denied.")
        journal.abandon()
        // A crash mid-write leaves a torn last line; it must not break recovery.
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"i\":2,\"s\":\"comm".utf8))
        try handle.close()

        let found = JobJournal.interrupted(in: dir, isRunning: { _ in false })
        #expect(found.count == 1)
        let job = try #require(found.first)
        #expect(job.kind == .move)
        #expect(job.items.map(\.status) == [.completed, .uncertain, .notDone, .notDone, .notDone])
        #expect(job.completed.first?.destination?.lastPathComponent == "a (2).txt", "committed name, not the planned one")
        #expect(job.uncertain.first?.destination?.lastPathComponent == "b.txt")
        #expect(job.items[3].note == "Access denied.")
        #expect(job.retryableSources.map(\.lastPathComponent) == ["b.txt", "c.txt", "d.txt"], "missing sources aren't offered")
        #expect(JobJournal.interrupted(in: dir, isRunning: { _ in true }).isEmpty, "a running process's jobs are left alone")
        job.discard()
        #expect(JobJournal.interrupted(in: dir, isRunning: { _ in false }).isEmpty)
    }

    @Test func journalShowsWorkInProgressWhilePaused() async throws {
        let fx = try Fixture()
        try fx.file("src/first.txt", "1")
        try writeDense(fx.url("src/second.bin"), size: 32 * MB)
        try fx.folder("dst")
        let dir = fx.url("journal")
        let sources = [fx.url("src/first.txt"), fx.url("src/second.bin")]
        let journal = try JobJournal(directory: dir, kind: .copy, sources: sources, destination: fx.url("dst"))
        let transfer = FileTransfer(kind: .copy, sources: sources, destination: fx.url("dst"), journal: journal, options: noClone)
        let flag = Flag()
        let job = Task {
            await transfer.run(progress: { p in
                if p.currentName == "second.bin", p.bytesDone > 4 * MB, flag.trip() { transfer.pause() }
            }, resolveConflict: neverAsked)
        }
        for _ in 0..<12_000 where !transfer.isPaused { try await Task.sleep(nanoseconds: 10_000_000) }
        let snapshot = try #require(InterruptedJob(file: journal.url))
        #expect(snapshot.items.map(\.status) == [.completed, .uncertain])
        transfer.resume()
        _ = await job.value
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
    }
}

// MARK: - Undo copy (FE-129) and estimates (FE-114)

@Suite("Undo copy fingerprints (FE-129)")
struct CopyUndoTests {
    @Test func onlyUnchangedCopiesAreRemovable() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "A")
        try fx.file("src/b.txt", "B")
        try fx.file("src/c.txt", "C")
        try fx.file("src/F/x.txt", "X")
        try fx.file("src/G/y.txt", "Y")
        try fx.file("src/H/z.txt", "Z")
        try fx.folder("dst")
        let report = await fx.job(.copy, ["src/a.txt", "src/b.txt", "src/c.txt", "src/F", "src/G", "src/H"], to: "dst")
            .run(resolveConflict: neverAsked)
        #expect(report.fingerprints.count == 6)
        // a untouched, b edited, c same-size replacement, F gets .DS_Store, G inner file edited, H deleted.
        try "BB".write(to: fx.url("dst/b.txt"), atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: fx.url("dst/c.txt"))
        try "Q".write(to: fx.url("dst/c.txt"), atomically: false, encoding: .utf8)
        try fx.file("dst/F/.DS_Store", "view settings")
        try "YY".write(to: fx.url("dst/G/y.txt"), atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: fx.url("dst/H"))
        let plan = CopyUndo.plan(report.fingerprints.map { ($0.key, $0.value) })
        #expect(Set(plan.unchanged.map(\.lastPathComponent)) == ["a.txt", "F"])
        #expect(Set(plan.changed.map(\.lastPathComponent)) == ["b.txt", "c.txt", "G"])
        #expect(plan.missing.map(\.lastPathComponent) == ["H"])
    }

    @Test func movesAreNotFingerprinted() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt")
        try fx.folder("dst")
        let report = await fx.job(.move, ["src/a.txt"], to: "dst").run(resolveConflict: neverAsked)
        #expect(report.fingerprints.isEmpty)
    }
}

@Suite("Speed and time remaining (FE-114)")
struct TransferRateTests {
    @Test func calculatingUntilReliableThenSmoothed() {
        var rate = TransferRateEstimator()
        rate.record(bytes: 0, at: 0)
        rate.record(bytes: 5 * MB, at: 0.5)
        #expect(rate.bytesPerSecond(at: 0.5) == nil, "too early: Calculating…")
        var t = 0.5
        var bytes = 5 * MB
        while t < 3 {
            t += 0.25
            bytes += Int64(2.5 * Double(MB))
            rate.record(bytes: bytes, at: t)
        }
        let speed = rate.bytesPerSecond(at: t) ?? 0
        #expect(abs(speed - Double(10 * MB)) < Double(MB), "≈10 MB/s, got \(speed)")
        let eta = rate.secondsRemaining(100 * MB, at: t)
        #expect(eta.map { abs($0 - 10) < 1.5 } == true)
        rate.pause()
        #expect(rate.bytesPerSecond(at: t + 1) == nil, "paused: no estimate")
        rate.resume()
        rate.record(bytes: bytes, at: t + 5)
        #expect(rate.bytesPerSecond(at: t + 5) == nil, "recalculating after resume")
    }

    @Test func wording() {
        #expect(TransferRateEstimator.describeRemaining(3) == "About 5 seconds")
        #expect(TransferRateEstimator.describeRemaining(42) == "About 45 seconds")
        #expect(TransferRateEstimator.describeRemaining(58) == "About 1 minute")
        #expect(TransferRateEstimator.describeRemaining(70) == "About 1 minute")
        #expect(TransferRateEstimator.describeRemaining(150) == "About 3 minutes")
        #expect(TransferRateEstimator.describeRemaining(3600) == "About 1 hour")
        #expect(TransferRateEstimator.describeRemaining(3900) == "About 1 hour and 5 minutes")
        #expect(TransferRateEstimator.describeRemaining(3 * 86400) == "About 3 days")
        #expect(TransferRateEstimator.describeSpeed(45.25 * 1024 * 1024) == "45.2 MB/s")   // 1024-based, like Explorer
    }

    @Test func remainingTimeOutOfRangeIsCalculating() {
        for seconds in [Double.infinity, -.infinity, .nan, 1e9, 5.7e20, .greatestFiniteMagnitude] {
            #expect(TransferRateEstimator.describeRemaining(seconds) == "Calculating…", "\(seconds)")
        }
        #expect(TransferRateEstimator.describeRemaining(1e8) == "About 1157 days")
    }

    @Test func emptyItemsAfterALargeFileNeverTrapTheEstimate() {
        // 200 MB in 2 s, then only empty folders: each record decays the rate toward zero.
        var rate = TransferRateEstimator()
        var t = 0.0
        while t < 2 { rate.record(bytes: Int64(t * 100) * MB, at: t); t += 0.1 }
        let total = 200 * MB
        while t < 60 {
            rate.record(bytes: total, at: t)
            if let eta = rate.secondsRemaining(MB, at: t) {
                #expect(eta <= Double(MB) + 1, "at least 1 B/s, so at most 1 MB of seconds")
                _ = TransferRateEstimator.describeRemaining(eta)
            }
            t += 0.1
        }
        #expect(rate.bytesPerSecond(at: t) == nil, "a rate under 1 B/s is Calculating…")
    }

    @Test func progressFractionPrefersBytes() {
        var p = TransferProgress(completed: 0, total: 2, currentName: nil, phase: .discovering)
        #expect(p.fraction == nil)
        p.phase = .running
        p.itemsTotal = 10; p.itemsDone = 5
        #expect(p.fraction == 0.5)
        p.bytesTotal = 100; p.bytesDone = 25
        #expect(p.fraction == 0.25)
        #expect(p.bytesRemaining == 75 && p.itemsRemaining == 5)
    }
}

// MARK: - Items that change under a running copy or move

final class DetailLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ItemResult] = []
    func add(_ r: ItemResult) { lock.withLock { items.append(r) } }
    var all: [ItemResult] { lock.withLock { items } }
}

final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var sum: Int64 = 0
    func add(_ n: Int64) { lock.withLock { sum += n } }
    var total: Int64 { lock.withLock { sum } }
}

@Suite("Copy engine: concurrent changes")
struct CopyEngineRaceTests {
    private func engine() -> CopyEngine { CopyEngine(control: TransferControl(), allowClone: false, verb: "copy") }

    @Test func failedPackageCopyKeepsAnItemThatAppearedAtTheTarget() throws {
        let fx = try Fixture()
        let source = try fx.file("src/Tool.app/Contents/Info.plist", "plist").deletingLastPathComponent().deletingLastPathComponent()
        try #require(CopyEngine.isPackage(source))
        try fx.file("dst/Tool.app/theirs.txt", "theirs")   // made by someone else after planning
        let outcome = engine().copyItem(source, to: fx.url("dst/Tool.app"), moveSource: false)
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(fx.read("dst/Tool.app/theirs.txt") == "theirs")
        #expect(fx.exists("src/Tool.app/Contents/Info.plist"))
    }

    @Test func failedPackageCopyRemovesOnlyItsOwnTree() throws {
        let fx = try Fixture()
        try fx.file("src/Tool.app/Contents/a.txt", "a")
        try fx.file("src/Tool.app/Contents/locked.txt", "l")
        chmod(fx.url("src/Tool.app/Contents/locked.txt").path, 0)
        defer { chmod(fx.url("src/Tool.app/Contents/locked.txt").path, 0o644) }
        try fx.folder("dst")
        let outcome = engine().copyItem(fx.url("src/Tool.app"), to: fx.url("dst/Tool.app"), moveSource: false)
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(!fx.exists("dst/Tool.app"), "packages are all-or-nothing")
    }

    @Test func moveKeepsTheItemAPathLeadsToAfterTheParentIsSwappedForALink() throws {
        let fx = try Fixture()
        try fx.file("src/Project/notes.txt", "mine")
        try fx.file("victim/notes.txt", "victim")
        try fx.folder("dst")
        let e = engine()
        let swapped = Flag()
        let log = DetailLog()
        e.hooks.detail = { log.add($0) }
        e.hooks.entryDone = { _ in
            guard swapped.trip() else { return }   // right after notes.txt is copied
            try? FileManager.default.moveItem(at: fx.url("src/Project"), to: fx.url("src/Project-old"))
            try? FileManager.default.createSymbolicLink(at: fx.url("src/Project"), withDestinationURL: fx.url("victim"))
        }
        _ = e.copyItem(fx.url("src/Project"), to: fx.url("dst/Project"), moveSource: true)
        #expect(fx.read("victim/notes.txt") == "victim", "a file outside the source is never removed")
        #expect(!fx.exists("src/Project-old/notes.txt"), "the copied original is removed from the folder that was listed")
        #expect(fx.exists("src/Project-old"), "the folder the path no longer leads to is kept")
        #expect(fx.read("dst/Project/notes.txt") == "mine")
        #expect(log.all.contains { if case .copiedButSourceRemains = $0.outcome { return true }; return false })
    }

    @Test func moveKeepsAnOriginalReplacedAfterItsCopy() throws {
        let fx = try Fixture()
        let file = try fx.file("src/a.txt", "copied")
        try fx.folder("dst")
        let e = engine()
        e.hooks.entryDone = { _ in
            try? FileManager.default.removeItem(at: file)
            try? "newer".write(to: file, atomically: false, encoding: .utf8)
        }
        #expect(e.copyItem(file, to: fx.url("dst/a.txt"), moveSource: true) == .done)
        #expect(fx.read("src/a.txt") == "newer")
        #expect(fx.read("dst/a.txt") == "copied")

        let plain = try fx.file("src/b.txt", "b")
        #expect(engine().copyItem(plain, to: fx.url("dst/b.txt"), moveSource: true) == .done)
        #expect(!fx.exists("src/b.txt"), "an unchanged original is still removed")
    }

    @Test func moveNeverTakesAFileOutsideTheSourceWhenTheParentIsSwappedBeforeAChild() throws {
        let fx = try Fixture()
        for name in ["a.txt", "b.txt"] {
            try fx.file("src/Project/\(name)", "mine \(name)")
            try fx.file("victim/\(name)", "victim \(name)")
        }
        try fx.folder("dst")
        let e = engine()
        let swapped = Flag()
        e.hooks.entryDone = { _ in
            guard swapped.trip() else { return }   // after the first child, before the second
            try? FileManager.default.moveItem(at: fx.url("src/Project"), to: fx.url("src/Project-old"))
            try? FileManager.default.createSymbolicLink(at: fx.url("src/Project"), withDestinationURL: fx.url("victim"))
        }
        _ = e.copyItem(fx.url("src/Project"), to: fx.url("dst/Project"), moveSource: true)
        for name in ["a.txt", "b.txt"] {
            #expect(fx.read("victim/\(name)") == "victim \(name)", "a file outside the source is never removed")
            #expect(fx.exists("dst/Project/\(name)") != fx.exists("src/Project-old/\(name)"), "\(name) is in one place")
            if let copied = fx.read("dst/Project/\(name)") { #expect(copied == "mine \(name)", "only the source's own content") }
        }
    }

    @Test func movedPackageIsRemovedThroughRemoveTreeWithoutFollowingItsLinks() throws {
        let fx = try Fixture()
        try fx.file("src/Project/Tool.app/Contents/Info.plist", "plist")
        try fx.file("src/Project/Tool.app/Contents/Resources/r.txt", "r")
        try fx.file("outside/keep.txt", "keep")
        try FileManager.default.createSymbolicLink(at: fx.url("src/Project/Tool.app/Contents/out"), withDestinationURL: fx.url("outside"))
        try #require(CopyEngine.isPackage(fx.url("src/Project/Tool.app")))
        try fx.folder("dst")
        #expect(engine().copyItem(fx.url("src/Project"), to: fx.url("dst/Project"), moveSource: true) == .done)
        #expect(!fx.exists("src/Project"), "the package and its emptied folder are gone")
        #expect(fx.read("dst/Project/Tool.app/Contents/Resources/r.txt") == "r")
        #expect(fx.read("outside/keep.txt") == "keep")
    }

    /// src/Project holds files listed before `name`; victim holds its own `name`.
    /// After the first file is copied, Project is swapped for a link to victim.
    private func moveWithParentSwappedBeforeAPackage(_ fx: Fixture, _ name: String) throws {
        try fx.file("src/Project/\(name)/Contents/mine.txt", "mine")
        try fx.file("victim/\(name)/Contents/theirs.txt", "theirs")
        try fx.folder("dst")
        let fd = open(fx.url("src/Project").path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { close(fd) }
        // Listing order is the file system's, so add files until one comes before the package.
        for i in 0..<32 where FileOps.entryNames(of: fd)?.first ?? name == name {
            try fx.file("src/Project/f\(i).txt", "mine \(i)")
        }
        try #require(FileOps.entryNames(of: fd)?.first != name, "the swap must fall before the package")
        let e = engine()
        let swapped = Flag()
        e.hooks.entryDone = { _ in
            guard swapped.trip() else { return }
            try? FileManager.default.moveItem(at: fx.url("src/Project"), to: fx.url("src/Project-old"))
            try? FileManager.default.createSymbolicLink(at: fx.url("src/Project"), withDestinationURL: fx.url("victim"))
        }
        _ = e.copyItem(fx.url("src/Project"), to: fx.url("dst/Project"), moveSource: true)
        #expect(swapped.isSet)
        #expect(fx.read("victim/\(name)/Contents/theirs.txt") == "theirs", "the outside package is never removed")
        #expect(!fx.exists("dst/Project/\(name)/Contents/theirs.txt"), "the outside package is never copied")
        let kept = fx.read("src/Project-old/\(name)/Contents/mine.txt")
        let moved = fx.read("dst/Project/\(name)/Contents/mine.txt")
        #expect((kept ?? moved) == "mine" && (kept == nil) != (moved == nil), "the real item is in exactly one place")
    }

    @Test func moveNeverTakesAnOutsidePackageWhenTheParentIsSwappedBeforeIt() throws {
        let fx = try Fixture()
        try moveWithParentSwappedBeforeAPackage(fx, "Tool.app")
        try #require(CopyEngine.isPackage(fx.url("victim/Tool.app")))
    }

    @Test func aPlainFolderIsNotTakenForAPackageThroughASwappedParent() throws {
        let fx = try Fixture()
        try fx.folder("victim/Plain")
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x20   // kHasBundle
        try #require(setxattr(fx.url("victim/Plain").path, "com.apple.FinderInfo", &info, 32, 0, 0) == 0)
        try #require(CopyEngine.isPackage(fx.url("victim/Plain")))
        try moveWithParentSwappedBeforeAPackage(fx, "Plain")
        #expect(fx.read("src/Project-old/Plain/Contents/mine.txt") == "mine", "never removed as a whole package")
    }

    @Test func anOutsideFileFoundAfterASwapIsNotReadAtAll() throws {
        let fx = try Fixture()
        try fx.file("src/Project/a.txt", "a")
        try fx.file("src/Project/b.txt", "b")
        try fx.file("victim/a.txt", String(repeating: "v", count: 4 << 20))
        try fx.file("victim/b.txt", String(repeating: "v", count: 4 << 20))
        try fx.folder("dst")
        let e = engine()
        let swapped = Flag()
        let counted = ByteCount()
        e.hooks.bytes = { if $0 > 0 { counted.add($0) } }
        e.hooks.entryDone = { _ in
            guard swapped.trip() else { return }
            try? FileManager.default.moveItem(at: fx.url("src/Project"), to: fx.url("src/Project-old"))
            try? FileManager.default.createSymbolicLink(at: fx.url("src/Project"), withDestinationURL: fx.url("victim"))
        }
        _ = e.copyItem(fx.url("src/Project"), to: fx.url("dst/Project"), moveSource: true)
        #expect(swapped.isSet)
        #expect(counted.total <= 2, "the data stage stops before any of the outside file is copied")
    }

    @Test func entryNamesCanListTheSameDescriptorTwice() throws {
        let fx = try Fixture()
        try fx.file("f/a")
        try fx.file("f/b")
        let fd = open(fx.url("f").path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(FileOps.entryNames(of: fd)?.sorted() == ["a", "b"])
        #expect(FileOps.entryNames(of: fd)?.sorted() == ["a", "b"])
    }
}
