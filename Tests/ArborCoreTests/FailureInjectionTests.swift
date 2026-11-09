import Foundation
import Testing
@testable import ArborCore

/// Both sides of a job, recorded before it runs, so one check can prove nothing was lost.
private struct Sides {
    let source: URL
    let destination: URL
    let sourceBefore: TreeManifest
    let destinationBefore: TreeManifest

    init(_ source: URL, _ destination: URL) {
        self.source = source
        self.destination = destination
        sourceBefore = TreeManifest(of: source)
        destinationBefore = TreeManifest(of: destination)
    }

    /// No original is gone unless an identical copy exists, nothing that was there changed, no partial item
    /// remains, every source has one result, and the expected failure was what the user was asked about.
    func verify(_ report: TransferReport, sources: Int, asked: FailureRecorder? = nil, expected: FailureKind? = nil,
                sourceLocation: SourceLocation = #_sourceLocation) {
        let sourceAfter = TreeManifest(of: source), destinationAfter = TreeManifest(of: destination)
        #expect(report.results.count == sources, sourceLocation: sourceLocation)
        for (path, entry) in sourceBefore.entries where sourceAfter[path] == nil {
            #expect(destinationAfter[path] == entry, "\(path) is gone with no identical copy", sourceLocation: sourceLocation)
        }
        for (path, entry) in destinationBefore.entries {
            #expect(destinationAfter[path] == entry, "\(path) was there before and changed", sourceLocation: sourceLocation)
        }
        for (path, entry) in destinationAfter.entries where destinationBefore[path] == nil {
            #expect(sourceBefore[path] == entry, "\(path) is partial or unexplained", sourceLocation: sourceLocation)
        }
        if let expected {
            let kinds = asked?.all.map(\.kind) ?? []
            #expect(kinds.contains(expected), "asked \(kinds), expected \(expected)", sourceLocation: sourceLocation)
        }
    }
}

private func record(_ asked: FailureRecorder, answer: FailureChoice = .skip) -> FileTransfer.FailureResolver {
    { failure in asked.add(failure); return FailureDecision(answer) }
}

/// Cancels once: cancelling reports progress, which would land here again.
private func cancelling(_ transfer: FileTransfer, when condition: @escaping @Sendable (TransferProgress) -> Bool) -> @Sendable (TransferProgress) -> Void {
    let once = Flag()
    return { progress in if condition(progress), once.trip() { transfer.cancel() } }
}

private func locked(_ url: URL) { #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0) }
private func unlock(_ url: URL) { _ = chflags(url.path, 0) }

@Suite("Failure injection (FE-230)", .serialized)
struct FailureInjectionTests {
    private func job(_ kind: TransferKind, _ sources: [URL], to destination: URL, crossVolume: Bool = false,
                     options: FileTransfer.Options = noClone, disposer: FileTransfer.Disposer? = nil) -> FileTransfer {
        let nothingReplaced: FileTransfer.Disposer = { url in Issue.record("\(url.lastPathComponent) was replaced") }
        let volumes: FileTransfer.VolumeCheck = { crossVolume ? false : FileOps.sameVolume($0, $1) }
        return FileTransfer(kind: kind, sources: sources, destination: destination, disposeReplaced: disposer ?? nothingReplaced,
                            sameVolume: volumes, options: options)
    }

    // MARK: Disk full

    @Test func aFullDiskKeepsOriginalsAndLeavesNoPartialFile() async throws {
        guard let volume = await FormattedVolume.required("HFS+", megabytes: 6) else { return }
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 8 * MB)
        try writeDense(fx.url("src/Folder/small.bin"), size: 1 * MB)
        try writeDense(fx.url("src/Folder/huge.bin"), size: 8 * MB)
        let sides = Sides(fx.url("src"), volume.mount)
        for source in ["big.bin", "Folder"] {
            let asked = FailureRecorder()
            let transfer = job(.move, [fx.url("src/" + source)], to: volume.mount, crossVolume: true)
            let report = await finishing(transfer) { await transfer.run(resolveConflict: neverAsked, resolveFailure: record(asked)) }
            sides.verify(report, sources: 1, asked: asked, expected: .diskFull)
            #expect(asked.all.allSatisfy { $0.kind != .diskFull || !$0.allowsSkip }, "Skip can't help a full disk")
        }
        #expect(FileOps.exists(fx.url("src/Folder/huge.bin")))
    }

    // MARK: Denied access

    @Test func anUnreadableFileIsAskedAboutAndKept() async throws {
        guard geteuid() != 0 else { return }   // root ignores permissions
        let fx = try Fixture()
        try fx.file("src/secret.txt", "secret")
        try fx.folder("dst")
        chmod(fx.url("src/secret.txt").path, 0)
        defer { chmod(fx.url("src/secret.txt").path, 0o644) }
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let asked = FailureRecorder()
        let report = await job(.move, [fx.url("src/secret.txt")], to: fx.url("dst"), crossVolume: true)
            .run(resolveConflict: neverAsked, resolveFailure: record(asked))
        sides.verify(report, sources: 1, asked: asked, expected: .accessDenied)
    }

    @Test func anUnlistableFolderIsAskedAboutAndKept() async throws {
        guard geteuid() != 0 else { return }
        let fx = try Fixture()
        try fx.file("src/Closed/inside.txt", "inside")
        try fx.folder("dst")
        chmod(fx.url("src/Closed").path, 0)
        defer {
            chmod(fx.url("src/Closed").path, 0o755)
            chmod(fx.url("dst/Closed").path, 0o755)
        }
        let asked = FailureRecorder()
        let report = await job(.move, [fx.url("src/Closed")], to: fx.url("dst"), crossVolume: true)
            .run(resolveConflict: neverAsked, resolveFailure: record(asked))
        #expect(asked.all.map(\.kind) == [.accessDenied])
        #expect(report.results[0].outcome.isProblem)
        chmod(fx.url("src/Closed").path, 0o755)
        #expect(fx.read("src/Closed/inside.txt") == "inside")
    }

    @Test func aReadOnlyDestinationThenTryAgainSucceeds() async throws {
        guard geteuid() != 0 else { return }
        let fx = try Fixture()
        try fx.file("src/a.txt", "a")
        try fx.folder("dst")
        let destination = fx.url("dst")
        chmod(destination.path, 0o555)
        defer { chmod(destination.path, 0o755) }
        let sides = Sides(fx.url("src"), destination)
        let asked = FailureRecorder()
        let report = await job(.copy, [fx.url("src/a.txt")], to: destination).run(resolveConflict: neverAsked, resolveFailure: { failure in
            asked.add(failure)
            chmod(destination.path, 0o755)
            return FailureDecision(.retry)
        })
        sides.verify(report, sources: 1, asked: asked, expected: .destinationAccessDenied)
        #expect(asked.all.count == 1)
        #expect(fx.read("dst/a.txt") == "a")
    }

    @Test func aDeleteDeniedOriginalIsReportedAsRemaining() async throws {
        guard geteuid() != 0 else { return }
        let fx = try Fixture()
        let file = try fx.file("src/a.txt", "a")
        try fx.folder("dst")
        _ = ScratchVolume.run("/bin/chmod", ["+a", "everyone deny delete", file.path])
        defer { _ = ScratchVolume.run("/bin/chmod", ["-N", file.path]) }
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let asked = FailureRecorder()
        let report = await job(.move, [file], to: fx.url("dst"), crossVolume: true)
            .run(resolveConflict: neverAsked, resolveFailure: record(asked))
        sides.verify(report, sources: 1, asked: asked, expected: .accessDenied)
        guard case .copiedButSourceRemains = report.results[0].outcome else {
            Issue.record("\(report.results[0].outcome)")
            return
        }
        #expect(fx.read("src/a.txt") == "a")
    }

    // MARK: Locked items

    @Test func aLockedSourceStaysPutOnASameVolumeMove() async throws {
        let fx = try Fixture()
        let file = try fx.file("src/a.txt", "a")
        try fx.folder("dst")
        locked(file)
        defer { unlock(file) }
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let asked = FailureRecorder()
        let report = await job(.move, [file], to: fx.url("dst")).run(resolveConflict: neverAsked, resolveFailure: record(asked))
        sides.verify(report, sources: 1, asked: asked, expected: .locked)
        #expect(report.results[0].outcome.isProblem)
        #expect(fx.read("src/a.txt") == "a")
    }

    @Test func aLockedSourceIsCopiedButKeptOnACrossVolumeMove() async throws {
        let fx = try Fixture()
        let file = try fx.file("src/a.txt", "a")
        try fx.folder("dst")
        locked(file)
        defer {
            unlock(file)
            unlock(fx.url("dst/a.txt"))
        }
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let asked = FailureRecorder()
        let report = await job(.move, [file], to: fx.url("dst"), crossVolume: true)
            .run(resolveConflict: neverAsked, resolveFailure: record(asked))
        sides.verify(report, sources: 1, asked: asked, expected: .locked)
        guard case .copiedButSourceRemains = report.results[0].outcome else {
            Issue.record("\(report.results[0].outcome)")
            return
        }
    }

    @Test func aLockedDestinationFolderIsNamedAsSuch() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "a")
        let destination = try fx.folder("dst")
        locked(destination)
        defer { unlock(destination) }
        let sides = Sides(fx.url("src"), destination)
        let asked = FailureRecorder()
        let report = await job(.copy, [fx.url("src/a.txt")], to: destination).run(resolveConflict: neverAsked, resolveFailure: record(asked))
        sides.verify(report, sources: 1, asked: asked, expected: .destinationLocked)
        #expect(asked.all.first?.allowsSkip == false)
    }

    @Test func aLockedDestinationBlamesItEvenWhenTheSourceIsLockedToo() {
        let fx = try? Fixture()
        guard let fx, let file = try? fx.file("src/a.txt"), let folder = try? fx.folder("dst") else { Issue.record("fixture"); return }
        locked(file)
        locked(folder)
        defer {
            unlock(file)
            unlock(folder)
        }
        let failure = TransferFailure.classify(errno: EPERM, source: file, destination: folder.appendingPathComponent("a.txt"), stage: .copying)
        #expect(failure.kind == .destinationLocked)
    }

    @Test func replacingALockedTargetLeavesBothSidesAlone() async throws {
        let fx = try Fixture()
        let source = try fx.file("src/a.txt", "new")
        let target = try fx.file("dst/a.txt", "old")
        locked(target)
        defer { unlock(target) }
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let report = await job(.copy, [source], to: fx.url("dst"), disposer: fx.disposer)
            .run(resolveConflict: { _ in ConflictDecision(.replace) }, resolveFailure: answerSkip)
        sides.verify(report, sources: 1)
        #expect(report.results[0].outcome.isProblem)
    }

    // MARK: Cancellation

    @Test func cancellingMidFileLeavesNoPartialFile() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 16 * MB)
        try fx.folder("dst")
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let options = FileTransfer.Options(allowClone: false, bytesPerSecondLimit: 32 * MB, progressInterval: 0)
        let transfer = job(.copy, [fx.url("src/big.bin")], to: fx.url("dst"), options: options)
        let report = await finishing(transfer) {
            await transfer.run(progress: cancelling(transfer, when: { $0.phase == .running && $0.bytesDone > 0 }), resolveConflict: neverAsked)
        }
        sides.verify(report, sources: 1)
        #expect(report.wasCancelled)
        #expect(fx.names("dst").isEmpty)
    }

    @Test func cancellingMidFolderKeepsWhatFinished() async throws {
        let fx = try Fixture()
        for index in 0..<40 { try fx.file("src/Folder/\(index).txt", "\(index)") }
        try fx.folder("dst")
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let transfer = job(.move, [fx.url("src/Folder")], to: fx.url("dst"), crossVolume: true)
        let report = await finishing(transfer) {
            await transfer.run(progress: cancelling(transfer, when: { $0.phase == .running && $0.itemsDone >= 3 }), resolveConflict: neverAsked)
        }
        sides.verify(report, sources: 1)
        #expect(report.wasCancelled)
    }

    @Test func cancellingMidPackageIsAllOrNothing() async throws {
        let fx = try Fixture()
        try writeDense(fx.url("src/Tool.app/Contents/one.bin"), size: 8 * MB)
        try writeDense(fx.url("src/Tool.app/Contents/two.bin"), size: 8 * MB)
        try fx.folder("dst")
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let options = FileTransfer.Options(allowClone: false, bytesPerSecondLimit: 32 * MB, progressInterval: 0)
        let transfer = job(.move, [fx.url("src/Tool.app")], to: fx.url("dst"), crossVolume: true, options: options)
        let report = await finishing(transfer) {
            await transfer.run(progress: cancelling(transfer, when: { $0.phase == .running && $0.bytesDone > 0 }), resolveConflict: neverAsked)
        }
        sides.verify(report, sources: 1)
        #expect(fx.names("dst").isEmpty)
        #expect(FileOps.exists(fx.url("src/Tool.app/Contents/two.bin")))
    }

    @Test func cancellingDuringDiscoveryStartsNothing() async throws {
        let fx = try Fixture()
        for index in 0..<300 { try fx.file("src/Folder/\(index).txt", "x") }
        try fx.folder("dst")
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let transfer = job(.copy, [fx.url("src/Folder")], to: fx.url("dst"))
        let report = await finishing(transfer) {
            await transfer.run(progress: cancelling(transfer, when: { $0.phase == .discovering }), resolveConflict: neverAsked)
        }
        sides.verify(report, sources: 1)
        #expect(report.results.map(\.outcome) == [.cancelled])
        #expect(fx.names("dst").isEmpty)
    }

    @Test func cancellingAtTheFailurePromptStopsTheRest() async throws {
        guard geteuid() != 0 else { return }
        let fx = try Fixture()
        try fx.file("src/a.txt", "a")
        try fx.file("src/b.txt", "b")
        let destination = try fx.folder("dst")
        chmod(destination.path, 0o555)
        defer { chmod(destination.path, 0o755) }
        let sides = Sides(fx.url("src"), destination)
        let asked = FailureRecorder()
        let report = await job(.copy, [fx.url("src/a.txt"), fx.url("src/b.txt")], to: destination)
            .run(resolveConflict: neverAsked, resolveFailure: record(asked, answer: .cancel))
        sides.verify(report, sources: 2, asked: asked, expected: .destinationAccessDenied)
        #expect(asked.all.count == 1)
        #expect(report.wasCancelled)
    }

    @Test func cancellingAtTheConflictPromptChangesNothing() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "new")
        try fx.file("dst/a.txt", "old")
        let sides = Sides(fx.url("src"), fx.url("dst"))
        let report = await job(.move, [fx.url("src/a.txt")], to: fx.url("dst"))
            .run(resolveConflict: { _ in ConflictDecision(.cancel) })
        sides.verify(report, sources: 1)
        #expect(report.wasCancelled)
    }

    // MARK: Network and disk loss (simulated)

    @Test(arguments: [ENXIO, ENODEV, ENOTCONN, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED, ESHUTDOWN,
                      ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH, ESTALE])
    func aLostConnectionIsClassified(code: Int32) {
        let failure = TransferFailure.classify(errno: code, source: URL(fileURLWithPath: "/nowhere/a"), destination: nil, stage: .copying)
        #expect(failure.kind == .volumeUnavailable)
        #expect(!failure.allowsSkip)
    }

    @Test func classificationOfTheOtherNewCases() throws {
        let fx = try Fixture()
        let source = try fx.file("a.txt")
        let gone = fx.url("no-such-folder/a.txt")
        #expect(TransferFailure.classify(errno: ENOENT, source: source, destination: gone, stage: .copying).kind == .volumeUnavailable)
        #expect(TransferFailure.classify(errno: ENOENT, source: fx.url("missing"), destination: gone, stage: .copying).kind == .notFound)
        #expect(TransferFailure.classify(errno: EFBIG, source: source, destination: nil, stage: .copying).kind == .fileTooLarge)
        #expect(TransferFailure.classify(errno: ENAMETOOLONG, source: source, destination: nil, stage: .copying).kind == .pathTooLong)
        #expect(TransferFailure.classify(errno: EIO, source: source, destination: nil, stage: .copying).kind == .other)
    }

    @Test func noWriteLandsInTheLeftoverFolderAndTryAgainWorksAfterAReconnect() async throws {
        guard let volume = await FormattedVolume.required("HFS+"),
              let slotTaker = await FormattedVolume.required("HFS+") else { return }
        let fx = try Fixture()
        try fx.file("src/first.txt", "first")
        try fx.file("src/second.txt", "second")
        await slotTaker.detach()
        let transfer = job(.move, [fx.url("src/first.txt"), fx.url("src/second.txt")], to: volume.mount, crossVolume: true)
        let firstDone = Flag()
        let asked = FailureRecorder()
        let running = Task {
            await finishing(transfer, within: 60) {
                await transfer.run(progress: { p in
                    if p.completed == 1, firstDone.trip() { transfer.pause() }
                }, resolveConflict: neverAsked, resolveFailure: { failure in
                    asked.add(failure)
                    #expect(TreeManifest(of: volume.mount).paths.isEmpty, "the leftover folder got nothing")
                    await slotTaker.attach()     // takes the old device number
                    await volume.attach()        // same place, new device number
                    return FailureDecision(.retry)
                })
            }
        }
        await waitUntil { transfer.isPaused }
        await volume.detach()
        #expect(FileManager.default.fileExists(atPath: volume.mount.path), "the mount-point folder must survive for this to test anything")
        transfer.resume()
        let report = await running.value
        #expect(asked.all.map(\.kind) == [.volumeUnavailable])
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(volume.names() == ["first.txt", "second.txt"])
        #expect(!FileOps.exists(fx.url("src/second.txt")))
    }

    @Test func losingTheDestinationMidFileKeepsTheOriginal() async throws {
        guard let volume = await FormattedVolume.required("HFS+") else { return }
        let fx = try Fixture()
        try writeDense(fx.url("src/big.bin"), size: 12 * MB)
        let options = FileTransfer.Options(allowClone: false, bytesPerSecondLimit: 8 * MB, progressInterval: 0)
        let transfer = job(.move, [fx.url("src/big.bin")], to: volume.mount, crossVolume: true, options: options)
        let started = Flag()
        let asked = FailureRecorder()
        let running = Task {
            await finishing(transfer, within: 60) {
                await transfer.run(progress: { p in
                    if p.phase == .running, p.bytesDone > 0, started.trip() { transfer.pause() }
                }, resolveConflict: neverAsked, resolveFailure: record(asked, answer: .cancel))
            }
        }
        await waitUntil { transfer.isPaused }
        await volume.detach()
        #expect(FileManager.default.fileExists(atPath: volume.mount.path))
        transfer.resume()
        let report = await running.value
        #expect(asked.all.map(\.kind) == [.volumeUnavailable], "not “Error 5”, and no Skip")
        #expect(report.results.count == 1)
        #expect(FileOps.exists(fx.url("src/big.bin")))
        #expect(TreeManifest(of: volume.mount).paths.isEmpty, "no partial file in the leftover folder")
    }

    @Test func losingTheSourceBetweenItemsIsReportedNotLost() async throws {
        guard let volume = await FormattedVolume.required("HFS+") else { return }
        let fx = try Fixture()
        try Data("one".utf8).write(to: volume.url("one.txt"))
        try Data("two".utf8).write(to: volume.url("two.txt"))
        let destination = try fx.folder("dst")
        let transfer = job(.move, [volume.url("one.txt"), volume.url("two.txt")], to: destination, crossVolume: true)
        let firstDone = Flag()
        let asked = FailureRecorder()
        let running = Task {
            await finishing(transfer, within: 60) {
                await transfer.run(progress: { p in
                    if p.completed == 1, firstDone.trip() { transfer.pause() }
                }, resolveConflict: neverAsked, resolveFailure: record(asked))
            }
        }
        await waitUntil { transfer.isPaused }
        await volume.detach()
        transfer.resume()
        let report = await running.value
        #expect(report.results.count == 2)
        #expect(report.results[1].outcome.isProblem)
        #expect(fx.names("dst") == ["one.txt"], "only what really arrived")
        await volume.attach()
        #expect(volume.names().contains("two.txt"), "the second original is still on the disk")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<3_000 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition(), "timed out")
    }

    // MARK: Merge racing a new arrival

    @Test func removingAMergedFolderOnlyHappensWhenItIsEmpty() throws {
        let fx = try Fixture()
        try fx.file("box/.DS_Store", "view state")
        try fx.file("box/arrived.txt", "don't lose me")
        let parent = open(fx.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(parent >= 0)
        defer { close(parent) }
        #expect(FileOps.removeEmptyFolder("box", in: parent) == 0)
        #expect(fx.read("box/arrived.txt") == "don't lose me", "the file survives")
        #expect(fx.exists("box"), "the folder stays")

        try FileManager.default.removeItem(at: fx.url("box/arrived.txt"))
        #expect(FileOps.removeEmptyFolder("box", in: parent) == 0)
        #expect(!fx.exists("box"), "only .DS_Store was left")
    }

    @Test func aFileArrivingAsAMergeFinishesKeepsTheSourceFolder() async throws {
        let fx = try Fixture()
        try fx.file("src/Box/moved.txt", "moved")
        try fx.file("dst/Box/old.txt", "old")
        let arrived = Flag()
        // Across volumes the job reports each child, so this lands after the last one and before the folder is dealt with.
        let report = await job(.move, [fx.url("src/Box")], to: fx.url("dst"), crossVolume: true).run(progress: { _ in
            if !fx.exists("src/Box/moved.txt"), arrived.trip() { try? Data("don't lose me".utf8).write(to: fx.url("src/Box/arrived.txt")) }
        }, resolveConflict: { _ in ConflictDecision(.merge) })
        #expect(arrived.isSet)
        #expect(fx.read("src/Box/arrived.txt") == "don't lose me", "the new file survives, so its folder stays")
        #expect(fx.read("dst/Box/moved.txt") == "moved")
        #expect(fx.read("dst/Box/old.txt") == "old")
        #expect(report.problems.isEmpty)
        if case .merged = report.results[0].outcome {} else { Issue.record("\(report.results[0].outcome)") }
    }

    // MARK: Volumes mounted inside a tree

    @Test func aPermanentDeleteNeverEntersAVolumeMountedInsideIt() async throws {
        let fx = try Fixture()
        try fx.file("box/mine.txt", "mine")
        try fx.folder("box/inner")
        guard let volume = await FormattedVolume.required("HFS+", mountedAt: fx.url("box/inner/mounted")) else { return }
        try Data("keep".utf8).write(to: volume.url("keep.txt"))
        #expect(FileOps.removePermanently(fx.url("box")) == EXDEV, "the folder holding the mount")
        #expect(volume.names().contains("keep.txt"))
        #expect(FileOps.removePermanently(volume.mount) == EXDEV, "the mount point itself")
        #expect(volume.names().contains("keep.txt"))
        await volume.detach()
    }

    // MARK: One folder at the destination, or all of it

    @Test func aLockedSubfolderInAMergeCanBeSkippedAndIsNamed() async throws {
        let fx = try Fixture()
        try fx.file("src/Box/sub/x.txt", "x")
        try fx.file("src/Box/y.txt", "y")
        let sub = try fx.folder("dst/Box/sub")
        locked(sub)
        defer { unlock(sub) }
        let asked = FailureRecorder()
        _ = await job(.move, [fx.url("src/Box")], to: fx.url("dst"))
            .run(resolveConflict: { _ in ConflictDecision(.merge) }, resolveFailure: record(asked))
        let failure = try #require(asked.all.first)
        #expect(failure.kind == .destinationLocked)
        #expect(failure.allowsSkip)
        #expect(failure.message(verb: "move", volumeName: nil).contains("“sub”"))
        #expect(failure.summary.contains("“sub”"))
        #expect(fx.read("src/Box/sub/x.txt") == "x", "skipped, so kept")
        #expect(fx.read("dst/Box/y.txt") == "y", "the rest carried on")
    }

    @Test func onlyAMissingSubfolderOffersSkip() throws {
        let fx = try Fixture()
        let source = try fx.file("src/a.txt")
        let destination = fx.url("dst")
        func failure(_ target: String, errno code: Int32 = ENOENT, lost: Bool = false) -> TransferFailure {
            TransferFailure.classify(errno: code, source: source, destination: fx.url(target), stage: .copying,
                                     destinationLost: lost, jobDestination: destination)
        }
        let inSubfolder = failure("dst/gone/a.txt")
        #expect(inSubfolder.kind == .volumeUnavailable)
        #expect(inSubfolder.allowsSkip)
        #expect(inSubfolder.message(verb: "copy", volumeName: nil).contains("“gone”"))
        #expect(!failure("dst/a.txt").allowsSkip, "the destination itself is missing")
        #expect(!failure("dst/gone/a.txt", errno: ENOTCONN).allowsSkip, "the whole share went away")
        #expect(!failure("dst/gone/a.txt", lost: true).allowsSkip, "the whole disk went away")
    }

    @Test func permanentDeleteFailuresReadAsSentences() {
        for code in [ENAMETOOLONG, EPERM, EACCES, EROFS, ENOENT, EXDEV] {
            #expect(FileOps.removalFailureReason(errno: code) != String(cString: strerror(code)), "\(code)")
        }
        #expect(FileOps.removalFailureReason(errno: ENAMETOOLONG) == L10n.tr("The path is too long or nested too deeply."))
        #expect(FileOps.removalFailureReason(errno: EIO) == String(cString: strerror(EIO)), "the system's words when there are no better ones")
    }

    // MARK: Crash recovery

    @Test func aJobAbandonedMidItemIsUncertainAndRetryNeverOverwrites() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "fresh")
        try fx.file("dst/a.txt", "partial leftover")
        let directory = try fx.folder("journal")
        let journal = try JobJournal(directory: directory, kind: .copy, sources: [fx.url("src/a.txt")], destination: fx.url("dst"),
                                     pid: 999_999)
        journal.markRunning()
        journal.record(0, .started, destination: fx.url("dst/a.txt"))
        journal.abandon()
        let interrupted = try #require(JobJournal.interrupted(in: directory, isRunning: { _ in false }).first)
        #expect(interrupted.uncertain.map(\.source) == [fx.url("src/a.txt")])
        #expect(interrupted.retryableSources == [fx.url("src/a.txt")])
        let conflicts = Counter()
        _ = await FileTransfer(kind: interrupted.kind, sources: interrupted.retryableSources, destination: interrupted.destination,
                               disposeReplaced: fx.disposer)
            .run(resolveConflict: { _ in conflicts.increment(); return ConflictDecision(.skip) })
        #expect(conflicts.count == 1, "the leftover is a conflict, never assumed finished")
        #expect(fx.read("dst/a.txt") == "partial leftover")
    }

    @Test func aTornLastLineAndADeadProcessAreRecovered() throws {
        let fx = try Fixture()
        let directory = try fx.folder("journal")
        let journal = try JobJournal(directory: directory, kind: .move, sources: [fx.url("a"), fx.url("b")], destination: fx.url("dst"),
                                     pid: 999_998)
        journal.markRunning()
        journal.record(0, .committed, destination: fx.url("dst/a"))
        journal.abandon()
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"i\":1,\"s\":\"com".utf8))
        try handle.close()
        let live = JobJournal.interrupted(in: directory, isRunning: { _ in true })
        #expect(live.isEmpty, "a running process's journal is left alone")
        let job = try #require(JobJournal.interrupted(in: directory, isRunning: { _ in false }).first)
        #expect(job.completed.map(\.source) == [fx.url("a")])
        #expect(job.notDone.map(\.source) == [fx.url("b")], "the torn line counts for nothing")
    }

    @Test func unusableJournalsAreSkipped() throws {
        let fx = try Fixture()
        let directory = try fx.folder("journal")
        try Data("not json at all".utf8).write(to: directory.appendingPathComponent("garbage.jsonl"))
        try Data().write(to: directory.appendingPathComponent("empty.jsonl"))
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: directory.appendingPathComponent("binary.jsonl"))
        let huge = directory.appendingPathComponent("huge.jsonl")
        try Data("x".utf8).write(to: huge)
        #expect(truncate(huge.path, 1 << 32) == 0, "sparse: costs no disk")
        #expect(JobJournal.interrupted(in: directory, isRunning: { _ in false }).isEmpty)
    }

    // MARK: Every failure has words

    @Test(arguments: FailureKind.allCases)
    func everyFailureKindExplainsItself(kind: FailureKind) {
        let failure = TransferFailure(source: URL(fileURLWithPath: "/a/b.txt"), destination: URL(fileURLWithPath: "/c/b.txt"),
                                      stage: .copying, kind: kind, code: EIO, bytesNeeded: 10)
        #expect(!failure.title.isEmpty)
        #expect(!failure.message(verb: "copy", volumeName: "Disk").isEmpty)
        #expect(!failure.hint.isEmpty)
        #expect(!failure.summary.isEmpty)
    }
}
