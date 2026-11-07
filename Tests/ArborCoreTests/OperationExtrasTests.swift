import Foundation
import Testing
@testable import ArborCore

private let plain = FileTransfer.Options(allowClone: false, progressInterval: 0)
private let noConflicts: FileTransfer.ConflictResolver = { _ in ConflictDecision(.cancel) }

final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

// MARK: - Operation history (FE-126)

@Suite("Operation history (FE-126)")
struct OperationHistoryTests {
    @Test func recordFromReportKeepsPerItemResultsAndRetryFolders() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt", "A")
        try fx.file("src/F/ok.txt", "ok")
        try fx.file("src/F/locked.txt", "L")
        try fx.folder("dst/F")
        try fx.file("dst/F/locked.txt", "existing")
        let job = FileTransfer(kind: .copy, sources: [fx.url("src/a.txt"), fx.url("src/F")], destination: fx.url("dst"),
                               disposeReplaced: fx.disposer, options: plain)
        // Merge the folder, skip the clashing file inside it.
        let report = await job.run(resolveConflict: { c in ConflictDecision(c.kind == .folderOverFolder ? .merge : .skip) })
        let record = OperationRecord(report: report, started: Date(timeIntervalSinceNow: -5))
        #expect(record.kind == .copy)
        #expect(record.items.filter { !$0.nested }.map(\.outcome) == [.succeeded, .merged])
        let nested = try #require(record.items.first { $0.nested })
        #expect(nested.outcome == .skipped)
        #expect(nested.message?.isEmpty == false)
        #expect(nested.retryFolder == fx.url("dst/F").path, "a nested item retries into the matching destination folder")
        #expect(record.counts.done == 2 && record.counts.skipped == 1)
        #expect(record.countsText == "2 done · 1 skipped")
        #expect(record.retryPlan().isEmpty, "skips aren't retried")
    }

    @Test func retryPlanOffersOnlyFailedItemsThatStillExist() {
        let items = [
            OperationRecord.Item(source: "/s/a", outcome: .failed, message: "Access denied", retryFolder: "/d"),
            OperationRecord.Item(source: "/s/b", outcome: .succeeded, destination: "/d/b", retryFolder: "/d"),
            OperationRecord.Item(source: "/s/gone", outcome: .cancelled, retryFolder: "/d"),
            OperationRecord.Item(source: "/s/F", outcome: .partial, destination: "/d/F", retryFolder: "/d"),
            OperationRecord.Item(source: "/s/F/x", outcome: .failed, retryFolder: "/d/F", nested: true),
            OperationRecord.Item(source: "/s/G/y", outcome: .failed, retryFolder: "/d/G", nested: true),
        ]
        let record = OperationRecord(kind: .copy, sources: ["/s/a", "/s/b", "/s/gone", "/s/F"], destination: "/d",
                                     started: Date(), finished: Date(), items: items)
        let plan = record.retryPlan { $0 != "/s/gone" }
        #expect(plan.map(\.folder) == ["/d", "/d/F", "/d/G"])
        #expect(plan[0].sources == ["/s/a"], "the partly copied F isn't copied again whole")
        #expect(plan[1].sources == ["/s/F/x"], "only its failed item, into the matching folder")
        #expect(plan[2].sources == ["/s/G/y"])
        let wholeFailed = OperationRecord(kind: .copy, sources: ["/s/H"], destination: "/d", started: Date(), finished: Date(), items: [
            .init(source: "/s/H", outcome: .failed, retryFolder: "/d"),
            .init(source: "/s/H/z", outcome: .failed, retryFolder: "/d/H", nested: true),
        ])
        #expect(wholeFailed.retryPlan { _ in true }.map(\.sources) == [["/s/H"]], "a folder that failed whole is retried whole")
        #expect(record.counts == OperationRecord.Counts(done: 1, skipped: 0, failed: 2, cancelled: 1),
                "problems inside F count once, through F")
    }

    @Test func storeIsBoundedNewestFirstAndPersists() throws {
        let fx = try Fixture()
        let file = fx.url("history/history.json")
        let store = OperationHistoryStore(fileURL: file, limit: 3)
        for i in 0..<5 {
            store.add(OperationRecord(kind: .copy, sources: ["/s/\(i)"], destination: "/d", started: Date(),
                                      finished: Date(timeIntervalSince1970: 1_000_000 + Double(i)), items: []))
        }
        #expect(store.records.count == 3)
        #expect(store.records.map(\.sources[0]) == ["/s/4", "/s/3", "/s/2"])
        let reopened = OperationHistoryStore(fileURL: file, limit: 3)
        #expect(reopened.records == store.records)
        reopened.update(reopened.records[0].id) { $0.wasCancelled = true }
        #expect(OperationHistoryStore(fileURL: file).records[0].wasCancelled)
        reopened.clear()
        #expect(OperationHistoryStore(fileURL: file).records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func itemsPerJobAreCapped() {
        let results = (0..<300).map { ItemResult(source: URL(fileURLWithPath: "/s/\($0)"), outcome: .failed("x")) }
        let report = TransferReport(kind: .copy, destination: URL(fileURLWithPath: "/d"), results: results, details: [],
                                    wasCancelled: false, fingerprints: [:])
        let record = OperationRecord(report: report, started: Date())
        #expect(record.items.count == OperationHistoryStore.itemLimit)
        #expect(record.omittedItems == 300 - OperationHistoryStore.itemLimit)
        #expect(record.countsText.contains("more not listed"))
    }

    @Test func recordFromInterruptedJournal() throws {
        let fx = try Fixture()
        let a = try fx.file("src/a.txt"), b = try fx.file("src/b.txt")
        try fx.folder("dst")
        let journal = try JobJournal(directory: fx.url("jobs"), kind: .move, sources: [a, b], destination: fx.url("dst"), pid: 999_999)
        journal.record(0, .committed, destination: fx.url("dst/a.txt"))
        journal.record(1, .started, destination: fx.url("dst/b.txt"))
        journal.abandon()
        let job = try #require(JobJournal.interrupted(in: fx.url("jobs"), isRunning: { _ in false }).first)
        let record = OperationRecord(interrupted: job)
        #expect(record.wasInterrupted)
        #expect(record.kind == .move)
        #expect(record.items.map(\.outcome) == [.succeeded, .uncertain])
        #expect(record.retryPlan().first?.sources == [b.path])
    }
}

// MARK: - Queue (FE-127)

@Suite("Transfer queue (FE-127)")
struct TransferSchedulerTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func defaultRunsEverythingAtOnceLikeExplorer() {
        var s = TransferScheduler()
        #expect(s.add(a, drives: ["disk1"]) == [a])
        #expect(s.add(b, drives: ["disk1"]) == [b])
        #expect(s.running == [a, b])
        #expect(s.waiting.isEmpty)
    }

    @Test func sameDriveJobsWaitOtherDrivesStart() {
        var s = TransferScheduler(queueSameDrive: true)
        #expect(s.add(a, drives: ["disk1", "disk2"]) == [a])
        #expect(s.add(b, drives: ["disk2"]) == [])
        #expect(s.add(c, drives: ["disk3"]) == [c], "a job on another drive isn't held back")
        #expect(s.reason(for: b) == "Waiting for another operation on the same drive")
        #expect(s.remove(a) == [b])
        #expect(s.running == [b, c])
    }

    @Test func concurrencyLimitStartsInQueueOrder() {
        var s = TransferScheduler(concurrencyLimit: 1)
        #expect(s.add(a, drives: ["x"]) == [a])
        #expect(s.add(b, drives: ["y"]) == [])
        #expect(s.add(c, drives: ["z"]) == [])
        #expect(s.position(of: b) == 1 && s.position(of: c) == 2)
        #expect(s.reason(for: c) == "Waiting: one operation at a time")
        #expect(s.move(c, by: -1) == [])
        #expect(s.waiting == [c, b], "moved up")
        #expect(!s.canMove(c, by: -1))
        #expect(s.remove(a) == [c])
        #expect(s.remove(c) == [b])
    }

    @Test func deferHoldsAJobUntilEverythingElseIsDone() {
        var s = TransferScheduler(concurrencyLimit: 1)
        _ = s.add(a, drives: ["x"])
        _ = s.add(b, drives: ["x"])
        _ = s.add(c, drives: ["x"])
        _ = s.setDeferred(b, true)
        #expect(s.waiting == [c, b])
        #expect(s.reason(for: b) == "Deferred until other operations finish")
        #expect(!s.canMove(c, by: 1), "a deferred job can't be swapped with a normal one")
        #expect(s.remove(a) == [c])
        _ = s.reconfigure(queueSameDrive: false, concurrencyLimit: 0)
        #expect(s.running == [c], "deferred b still waits while c runs, even without a limit")
        #expect(s.remove(c) == [b])
    }

    @Test func startNowIgnoresTheRulesAndReconfigureReleasesWaitingJobs() {
        var s = TransferScheduler(queueSameDrive: true, concurrencyLimit: 1)
        _ = s.add(a, drives: ["x"])
        _ = s.add(b, drives: ["x"])
        _ = s.add(c, drives: ["y"])
        #expect(s.startNow(b) == [b])
        #expect(s.running == [a, b])
        #expect(s.startNow(b) == [], "already running")
        #expect(s.reconfigure(queueSameDrive: false, concurrencyLimit: 0) == [c])
        _ = s.add(d, drives: ["x"])
        #expect(s.running.count == 4)
    }

    @Test func driveIdentityResolvesMissingPathsThroughTheirParent() throws {
        let fx = try Fixture()
        let here = FileOps.driveIdentity(fx.root)
        #expect(here != nil)
        #expect(FileOps.driveIdentity(fx.url("not/yet/there")) == here)
    }
}

// MARK: - Verification (FE-130)

@Suite("Copy verification (FE-130)")
struct CopyVerifierTests {
    @Test func identicalCopiesVerifyInBoundedChunks() async throws {
        let fx = try Fixture()
        var data = Data(count: 3 * 1024 * 1024 + 17)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try fx.folder("src/F/sub")
        try data.write(to: fx.url("src/F/big.bin"))
        try fx.file("src/F/sub/a.txt", "A")
        try FileManager.default.createSymbolicLink(atPath: fx.url("src/F/link").path, withDestinationPath: "sub/a.txt")
        try fx.folder("dst")
        let report = await FileTransfer(kind: .copy, sources: [fx.url("src/F")], destination: fx.url("dst"), options: plain)
            .run(resolveConflict: noConflicts)
        let (pairs, excluded) = CopyVerifier.pairs(for: report)
        #expect(pairs.count == 1)
        let progress = TickCounter()
        let result = CopyVerifier.verify(pairs, excluding: excluded, chunkSize: 64 * 1024) { _ in progress.bump() }
        #expect(result.isVerified)
        #expect(result.filesChecked == 3)
        #expect(result.bytesChecked == Int64(data.count) + 1)
        #expect(progress.value > 40, "streamed in 64 KB pieces")
        #expect(try CopyVerifier.sha256Hex(fx.url("src/F/big.bin")) == CopyVerifier.sha256Hex(fx.url("dst/F/big.bin")))
    }

    @Test func detectsChangedBytesSizeDifferencesMissingFilesAndLinks() throws {
        let fx = try Fixture()
        try fx.file("src/F/same.txt", "same")
        try fx.file("src/F/flip.txt", "abcdef")
        try fx.file("src/F/size.txt", "short")
        try fx.file("src/F/missing.txt", "m")
        try FileManager.default.createSymbolicLink(atPath: fx.url("src/F/l").path, withDestinationPath: "same.txt")
        try fx.file("dst/F/same.txt", "same")
        try fx.file("dst/F/flip.txt", "abcdeX")
        try fx.file("dst/F/size.txt", "longer text")
        try FileManager.default.createSymbolicLink(atPath: fx.url("dst/F/l").path, withDestinationPath: "flip.txt")
        try fx.file("dst/F/extra.txt", "merged in earlier")
        let result = CopyVerifier.verify([(fx.url("src/F"), fx.url("dst/F"))])
        let reasons = Dictionary(uniqueKeysWithValues: result.failures.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.reason) })
        #expect(reasons.keys.sorted() == ["flip.txt", "l", "missing.txt", "size.txt"])
        #expect(reasons["flip.txt"]?.contains("SHA-256") == true)
        #expect(reasons["size.txt"]?.contains("sizes differ") == true)
        #expect(reasons["missing.txt"] == "The copy is missing.")
        #expect(!result.isVerified)
    }

    @Test func skippedItemsAreExcludedAndCancelStops() throws {
        let fx = try Fixture()
        try fx.file("src/F/kept.txt", "new")
        try fx.file("dst/F/kept.txt", "old, the user skipped replacing it")
        let excluded: Set<URL> = [fx.url("src/F/kept.txt")]
        #expect(CopyVerifier.verify([(fx.url("src/F"), fx.url("dst/F"))], excluding: excluded).isVerified)
        let control = TransferControl()
        control.cancel()
        #expect(CopyVerifier.verify([(fx.url("src/F"), fx.url("dst/F"))], control: control).cancelled)
    }

    @Test func movesAreNotVerified() {
        let report = TransferReport(kind: .move, destination: URL(fileURLWithPath: "/d"),
                                    results: [ItemResult(source: URL(fileURLWithPath: "/s/a"), outcome: .succeeded(URL(fileURLWithPath: "/d/a")))],
                                    details: [], wasCancelled: false, fingerprints: [:])
        #expect(CopyVerifier.pairs(for: report).pairs.isEmpty)
    }
}

// MARK: - "Copy without its properties?" (spec §9.5)

final class LossLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MetadataLoss] = []
    func add(_ loss: MetadataLoss) { lock.withLock { items.append(loss) } }
    var all: [MetadataLoss] { lock.withLock { items } }
}

@Suite("Destination capabilities and lost properties", .serialized)
struct MetadataLossTests {
    @Test func apfsKeepsEverything() throws {
        let fx = try Fixture()
        let caps = VolumeCapabilities.of(fx.root)
        #expect(caps.nativeExtendedAttributes)
        #expect(caps.accessControlLists)
        #expect(caps.keepsEverything)
        #expect(VolumeCapabilities.of(fx.url("missing/folder")) == caps, "a missing folder uses its existing parent")
    }

    @Test func inventoryIgnoresSystemAttributesAndEmptyFinderInfo() throws {
        let fx = try Fixture()
        let plainFile = try fx.file("plain.txt")
        setxattr(plainFile.path, "com.apple.quarantine", "0081;0;x;", 9, 0, 0)
        var zeros = [UInt8](repeating: 0, count: 32)
        setxattr(plainFile.path, "com.apple.FinderInfo", &zeros, 32, 0, 0)
        #expect(MetadataInventory.of(plainFile).isEmpty)
        let tagged = try fx.file("tagged.txt")
        try (tagged as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        setxattr(tagged.path, "org.example.note", "n", 1, 0, 0)
        _ = ScratchVolume.run("/bin/chmod", ["+a", "everyone deny delete", tagged.path])
        defer { _ = ScratchVolume.run("/bin/chmod", ["-N", tagged.path]) }
        let inventory = MetadataInventory.of(tagged)
        #expect(inventory.contains(.tags))
        #expect(inventory.contains(.otherAttributes))
        #expect(inventory.contains(.accessList))
        let fat = VolumeCapabilities(nativeExtendedAttributes: false, accessControlLists: false)
        #expect(fat.losses(inventory) == inventory)
        let smbWithStreams = VolumeCapabilities(nativeExtendedAttributes: true, accessControlLists: false)
        #expect(smbWithStreams.losses(inventory) == [.accessList])
        #expect(MetadataInventory([.tags, .accessList]).description == "Finder tags and access-list permissions")
    }

    private func job(_ fx: Fixture, _ sources: [String], caps: VolumeCapabilities, log: LossLog,
                     answer: @escaping @Sendable (MetadataLoss) -> MetadataLossDecision) -> FileTransfer {
        let t = FileTransfer(kind: .copy, sources: sources.map(fx.url), destination: fx.url("dst"), options: plain)
        t.capabilityCheck = { _ in caps }
        t.metadataLossResolver = { loss in log.add(loss); return answer(loss) }
        return t
    }

    @Test func asksOnlyForItemsWithPropertiesAndHonorsSkipAndDoThisForAll() async throws {
        let fx = try Fixture()
        try fx.file("src/plain.txt")
        for name in ["t1.txt", "t2.txt", "t3.txt"] {
            try (try fx.file("src/\(name)") as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)
        }
        try fx.folder("dst")
        let fat = VolumeCapabilities(nativeExtendedAttributes: false, accessControlLists: false, formatName: "ExFAT", volumeName: "STICK")
        let log = LossLog()
        let report = await job(fx, ["src/plain.txt", "src/t1.txt", "src/t2.txt", "src/t3.txt"], caps: fat, log: log) { loss in
            loss.source.lastPathComponent == "t1.txt" ? MetadataLossDecision(.skip) : MetadataLossDecision(.copyWithout, applyToRemaining: true)
        }.run(resolveConflict: noConflicts)
        #expect(log.all.map(\.source.lastPathComponent) == ["t1.txt", "t2.txt"], "plain file never asked; t3 covered by 'for all'")
        #expect(log.all.first?.lost.contains(.tags) == true)
        #expect(report.results.map(\.outcome) == [
            .succeeded(fx.url("dst/plain.txt")),
            .skipped("Skipped: the destination can't keep this item's properties."),
            .succeeded(fx.url("dst/t2.txt")), .succeeded(fx.url("dst/t3.txt")),
        ])
        #expect(!fx.exists("dst/t1.txt"))
    }

    @Test func cancelStopsTheJobAndFullVolumesNeverAsk() async throws {
        let fx = try Fixture()
        try (try fx.file("src/t.txt") as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)
        try fx.file("src/later.txt")
        try fx.folder("dst")
        let log = LossLog()
        let cancelled = await job(fx, ["src/t.txt", "src/later.txt"], caps: VolumeCapabilities(nativeExtendedAttributes: false, accessControlLists: true),
                                  log: log) { _ in MetadataLossDecision(.cancel) }.run(resolveConflict: noConflicts)
        #expect(cancelled.wasCancelled)
        #expect(fx.names("dst").isEmpty)
        let quiet = LossLog()
        let report = await job(fx, ["src/t.txt"], caps: .full, log: quiet) { _ in MetadataLossDecision(.cancel) }.run(resolveConflict: noConflicts)
        #expect(quiet.all.isEmpty)
        #expect(report.problems.isEmpty && fx.exists("dst/t.txt"))
    }

    /// One real exFAT image (disk images are slow to make; FAT32 takes the same code path).
    @Test func exFATCantHoldAttributesOrAccessListsAndACopyAsks() async throws {
        guard let volume = await FormattedVolume.make("ExFAT") else { return }
        let caps = VolumeCapabilities.of(volume.mount)
        #expect(!caps.nativeExtendedAttributes, "no native extended attributes")
        #expect(!caps.accessControlLists, "no ACLs")
        #expect(!caps.formatName.isEmpty)
        let fx = try Fixture()
        let src = try fx.file("src/t.txt")
        try (src as NSURL).setResourceValue(["Green"], forKey: .tagNamesKey)
        let log = LossLog()
        let t = FileTransfer(kind: .copy, sources: [src], destination: volume.mount, options: plain)
        t.metadataLossResolver = { loss in log.add(loss); return MetadataLossDecision(.copyWithout) }
        let report = await t.run(resolveConflict: noConflicts)
        #expect(log.all.count == 1)
        #expect(log.all.first?.capabilities.nativeExtendedAttributes == false)
        #expect(report.committed.count == 1)
    }
}

// MARK: - Compress to ▸ Additional options (FE-168)

@Suite("Archive creation options (FE-168)")
struct ArchiveOptionsTests {
    @Test func argumentsForEachFormatAndLevel() {
        let s = [URL(fileURLWithPath: "/w/a"), URL(fileURLWithPath: "/w/b")]
        let out = URL(fileURLWithPath: "/w/x"), list = URL(fileURLWithPath: "/w/l")
        func args(_ o: ArchiveCreateOptions) -> String { o.bsdtarArguments(sources: s, output: out, listFile: list).joined(separator: " ") }
        let base = ArchiveCreateOptions(name: "x.zip", destinationFolder: URL(fileURLWithPath: "/w"))
        #expect(args(base).contains("--format zip --options zip:compression=deflate,zip:compression-level=6"))
        var store = base; store.method = .store
        #expect(args(store).contains("--options zip:compression=store "))
        let seven = ArchiveCreateOptions(format: .sevenZip, method: .lzma, level: .maximum, name: "x.7z", destinationFolder: out)
        #expect(args(seven).contains("--format 7zip --options 7zip:compression=lzma1,7zip:compression-level=9"))
        let tgz = ArchiveCreateOptions(format: .tarGzip, level: .fastest, includeHiddenItems: false, name: "x.tar.gz", destinationFolder: out)
        #expect(args(tgz).contains("--format paxr --gzip --options gzip:compression-level=1 --exclude */.*"))
        let gz = ArchiveCreateOptions(format: .gzip, name: "a.gz", destinationFolder: out)
        #expect(args(gz).contains("--format raw --gzip"))
        #expect(ArchiveCreateOptions(format: .tar, method: .store, name: "t", destinationFolder: out).method == .none, "invalid method falls back")
        #expect(ArchiveCreateOptions.name("report.zip", withExtensionFor: .tarXz) == "report.tar.xz")
        #expect(ArchiveCreateOptions.name("backup.tar.gz", withExtensionFor: .sevenZip) == "backup.7z")
        #expect(ArchiveOutputFormat.available(forSingleFile: false).allSatisfy { !$0.isSingleFile })
    }

    @Test func problemsAreExplained() throws {
        let fx = try Fixture()
        let folder = try fx.folder("F")
        let file = try fx.file("a.txt")
        let other = try fx.file("sub/b.txt")
        var o = ArchiveCreateOptions(format: .gzip, name: "F.gz", destinationFolder: fx.root)
        #expect(o.problem(for: [folder])?.contains("compresses one file") == true)
        #expect(o.problem(for: [file]) == nil)
        o.format = .zip
        #expect(o.problem(for: [file, other]) == "The items must be in the same folder.")
        o.name = "  "
        #expect(o.problem(for: [file]) == "Type a name for the archive.")
        o.name = "a/b.zip"
        #expect(o.problem(for: [file]) != nil)
    }

    private func entries(_ archive: URL) throws -> [String] {
        try ArchiveTool.listWithBsdtar(archive).entries.compactMap(\.path).sorted()
    }

    @Test func roundTripsWithHiddenItemsExcludedOrIncluded() throws {
        let fx = try Fixture()
        try fx.file("w/F/a.txt", String(repeating: "hello ", count: 2000))
        try fx.file("w/F/.secret", "s")
        try fx.file("w/F/.cache/x", "x")
        try fx.file("w/.top", "selected on purpose")
        let sources = [fx.url("w/F"), fx.url("w/.top")]
        for format in [ArchiveOutputFormat.zip, .sevenZip, .tarGzip, .tarBzip2, .tarXz, .tar] {
            let hidden = fx.url("out-\(format.rawValue)-all.\(format.fileExtension)")
            // Fastest level: xz and LZMA at higher levels need hundreds of MB while other tests run.
            try ArchiveTool.create(ArchiveCreateOptions(format: format, level: .fastest, name: hidden.lastPathComponent, destinationFolder: fx.root),
                                   sources: sources, output: hidden, process: ToolProcess())
            #expect(try entries(hidden).contains { $0.hasSuffix(".secret") }, "\(format): hidden included")
            let clean = fx.url("out-\(format.rawValue)-clean.\(format.fileExtension)")
            try ArchiveTool.create(ArchiveCreateOptions(format: format, level: .fastest, includeHiddenItems: false, name: clean.lastPathComponent, destinationFolder: fx.root),
                                   sources: sources, output: clean, process: ToolProcess())
            let names = try entries(clean)
            #expect(!names.contains { $0.contains(".secret") || $0.contains(".cache") }, "\(format): \(names)")
            #expect(names.contains { $0.hasSuffix("a.txt") })
            #expect(names.contains(".top"), "\(format): a selected dot file is kept")
        }
        let stored = fx.url("stored.zip"), maximum = fx.url("max.zip")
        try ArchiveTool.create(ArchiveCreateOptions(format: .zip, method: .store, name: "stored.zip", destinationFolder: fx.root),
                               sources: [fx.url("w/F")], output: stored, process: ToolProcess())
        try ArchiveTool.create(ArchiveCreateOptions(format: .zip, level: .maximum, name: "max.zip", destinationFolder: fx.root),
                               sources: [fx.url("w/F")], output: maximum, process: ToolProcess())
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        #expect(size(stored) > size(maximum) + 5000, "store keeps 12 KB of text uncompressed")
    }

    @Test func singleFileGzipDecompressesToTheOriginal() throws {
        let fx = try Fixture()
        let file = try fx.file("notes.txt", "single file contents")
        let out = fx.url("notes.txt.gz")
        try ArchiveTool.create(ArchiveCreateOptions(format: .gzip, name: "notes.txt.gz", destinationFolder: fx.root),
                               sources: [file], output: out, process: ToolProcess())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", out.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == "single file contents")
    }
}

// MARK: - Security tab ACL editing (FE-153)

@Suite("Access-list editing (FE-153)", .serialized)
struct ACLEditingTests {
    @Test func addRemoveAndUndo() throws {
        let fx = try Fixture()
        let file = try fx.file("f.txt")
        defer { try? ACLEditor.restore(nil, to: file) }   // never leave an undeletable fixture
        #expect(ACLEditor.text(file) == nil)
        #expect(ACLEditor.canEdit(file))
        let rule = ACLRule(principal: ACLPrincipal(.group, "everyone"), allow: false, level: .write)
        let added = try ACLEditor.add(rule, to: file)
        #expect(added.before == nil)
        let entries = ACLEntry.read(file)
        #expect(entries.count == 1)
        #expect(entries[0].name == "everyone" && !entries[0].allow)
        #expect(Set(entries[0].permissions) == Set(rule.permissions(isFolder: false)))
        #expect(EffectiveAccess.test(file).write == false, "deny write takes effect for the owner too")
        try ACLEditor.undo(added)
        #expect(ACLEntry.read(file).isEmpty)
        #expect(EffectiveAccess.test(file).write)

        _ = try ACLEditor.add(ACLRule(principal: ACLPrincipal(.group, "staff"), allow: true, level: .read), to: file)
        _ = try ACLEditor.add(ACLRule(principal: ACLPrincipal(.group, "everyone"), allow: false, level: .modify), to: file)
        let order = ACLEntry.read(file).map(\.name)
        let removeIndex = try #require(order.firstIndex(of: "staff"))
        #expect(!ACLEntry.read(file).contains { !$0.allow && $0.permissions.contains("readsecurity") },
                "a Deny never locks the owner out of the list")
        let removed = try ACLEditor.remove(at: removeIndex, from: file)
        #expect(ACLEntry.read(file).map(\.name) == ["everyone"])
        #expect(removed.summary == "Removed: Allow staff (group): Read")
        #expect(ACLEntry.read(file).first?.levelTitle(isFolder: false) == "Modify", "a Deny of Modify is still called Modify")
        try ACLEditor.undo(removed)
        #expect(Set(ACLEntry.read(file).map(\.name)) == ["staff", "everyone"], "undo puts the removed entry back")
    }

    @Test func undoRefusesWhenChangedSince() throws {
        let fx = try Fixture()
        let file = try fx.file("f.txt")
        defer { try? ACLEditor.restore(nil, to: file) }
        let change = try ACLEditor.add(ACLRule(principal: ACLPrincipal(.group, "staff"), allow: true, level: .read), to: file)
        _ = ScratchVolume.run("/bin/chmod", ["+a", "everyone deny delete", file.path])   // someone else's change
        #expect(throws: ACLEditError.changedSinceEdit) { try ACLEditor.undo(change) }
        #expect(ACLEntry.read(file).count == 2, "nothing was removed")
    }

    @Test func folderInheritanceUnknownNamesAndPresets() throws {
        let fx = try Fixture()
        let folder = try fx.folder("F")
        defer { _ = ScratchVolume.run("/bin/chmod", ["-RN", folder.path]) }
        let rule = ACLRule(principal: ACLPrincipal(.group, "staff"), allow: true, level: .modify, inherit: true)
        #expect(rule.chmodEntry(isFolder: true).hasPrefix("group:staff allow list,add_file,search"))
        try ACLEditor.add(rule, to: folder)
        let entry = try #require(ACLEntry.read(folder).first)
        #expect(entry.flags.contains("file_inherit") && entry.flags.contains("directory_inherit"))
        let child = try fx.file("F/new.txt")
        #expect(ACLEntry.read(child).first?.isInherited == true, "new items inside inherit it")
        #expect(throws: ACLEditError.unknownPrincipal("no-such-user-arbor")) {
            try ACLEditor.add(ACLRule(principal: ACLPrincipal(.user, "no-such-user-arbor"), allow: true, level: .read), to: folder)
        }
        #expect(ACLPermissionLevel.fullControl.permissions(isFolder: false).contains("chown"))
        #expect(!ACLPermissionLevel.read.permissions(isFolder: true).contains("add_file"))
        #expect(ACLEditor.localGroups().first == "everyone")
        #expect(ACLEditor.currentUserGroups().contains { $0.name == "staff" })
        #expect(!ACLEditor.canChangeOwner)
    }

    @Test func groupChangeToOwnGroup() throws {
        let fx = try Fixture()
        let file = try fx.file("g.txt")
        let staff = try #require(ACLEditor.currentUserGroups().first { $0.name == "staff" })
        try ACLEditor.changeGroup(file, to: staff.id)
        #expect(try ItemSecurity.read(file).groupName == "staff")
    }
}

// MARK: - Time Machine versions (FE-155)

@Suite("Time Machine backups (FE-155)")
struct TimeMachineBackupTests {
    @Test func parsesListingAndClassifiesErrors() {
        let text = "/Volumes/.timemachine/ABC/2026-11-01-120000.backup/2026-11-01-120000.backup\n/Volumes/Backup/2026-11-07-093000.backup\n"
        let list = TimeMachineBackups.parseList(text)
        #expect(list.count == 2)
        #expect(TimeMachineBackups.date(ofBackup: list[1]).map { Calendar.current.component(.day, from: $0) } == 7)
        #expect(TimeMachineBackups.date(ofBackup: URL(fileURLWithPath: "/x/2026-11-07-093000.inprogress")) == nil)
        #expect(TimeMachineBackups.classify(stdout: text, stderr: "", status: 0, configured: true) == .backups(list))
        let denied = "No machine directory found for host.\nPOSIXError(_nsError: Error Domain=NSPOSIXErrorDomain Code=1 \"Operation not permitted\")"
        #expect(TimeMachineBackups.classify(stdout: denied, stderr: "", status: 1, configured: true) == .needsFullDiskAccess)
        #expect(TimeMachineBackups.classify(stdout: denied, stderr: "", status: 1, configured: false) == .notConfigured)
        if case .unavailable = TimeMachineBackups.classify(stdout: "", stderr: "disk not found", status: 1, configured: true) {} else {
            Issue.record("expected unavailable")
        }
    }

    @Test func relativePathsCoverTheDataVolume() {
        let root = URL(fileURLWithPath: "/")
        #expect(TimeMachineBackups.relativePaths(of: URL(fileURLWithPath: "/Users/ana/a.txt"), volumeRoot: root) == ["Users/ana/a.txt"])
        #expect(TimeMachineBackups.relativePaths(of: URL(fileURLWithPath: "/System/Volumes/Data/Users/ana/a.txt"),
                                                 volumeRoot: URL(fileURLWithPath: "/System/Volumes/Data")) == ["Users/ana/a.txt"])
        #expect(TimeMachineBackups.relativePaths(of: URL(fileURLWithPath: "/Volumes/Work/p/q"),
                                                 volumeRoot: URL(fileURLWithPath: "/Volumes/Work")) == ["p/q"])
    }

    @Test func findsDistinctVersionsNewestFirst() throws {
        let fx = try Fixture()
        let item = URL(fileURLWithPath: "/Users/ana/Documents/report.txt")
        func backup(_ name: String, _ contents: String?, modified: TimeInterval) throws -> URL {
            let root = try fx.folder("tm/\(name).backup")
            try fx.folder("tm/\(name).backup/Macintosh HD - Data")
            if let contents {
                let file = try fx.file("tm/\(name).backup/Macintosh HD - Data/Users/ana/Documents/report.txt", contents)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
            }
            return root
        }
        let b1 = try backup("2026-11-01-100000", "v1", modified: 1000)
        let b2 = try backup("2026-11-02-100000", "v2", modified: 2000)
        let b3 = try backup("2026-11-03-100000", "v2", modified: 2000)   // unchanged since b2
        let b4 = try backup("2026-11-04-100000", nil, modified: 0)        // deleted then
        let versions = TimeMachineBackups.versions(of: item, volumeRoot: URL(fileURLWithPath: "/"), in: [b1, b4, b3, b2])
        #expect(versions.map(\.date) == [b3, b1].compactMap(TimeMachineBackups.date(ofBackup:)))
        #expect(versions.allSatisfy { $0.url.path.hasSuffix("Macintosh HD - Data/Users/ana/Documents/report.txt") })
        #expect(versions.first?.size == 2)
        #expect(versions.allSatisfy { !$0.isFolder })
    }
}
