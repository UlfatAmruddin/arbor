import Foundation
import Testing
@testable import ArborCore

// Behavior and safety fixes (docs/features/qa-core.md, qa-places.md, file-operations.md).

// MARK: - Undo Move plans (QA-CORE-5)

@Suite struct MoveBackPlanTests {
    @Test func sameVolumeRenamesOtherVolumeJobsAndRefusals() throws {
        let fx = try Fixture()
        let a = try fx.file("vol2/a.txt"), b = try fx.file("vol2/b.txt"), c = try fx.file("vol2/c.txt")
        let d = try fx.file("vol2/sub/d.txt"), here = try fx.file("moved/here.txt")
        try fx.folder("home/one")
        try fx.folder("home/two")
        try fx.file("home/one/taken.txt")
        // Pretend everything under vol2 is another volume.
        let other = fx.url("vol2").path
        let sameVolume: (URL, URL) -> Bool = { x, y in x.path.hasPrefix(other) == y.path.hasPrefix(other) }
        let items = [
            MoveBack.Item(from: a, to: fx.url("home/one/a.txt")),
            MoveBack.Item(from: here, to: fx.url("home/two/here.txt")),
            MoveBack.Item(from: b, to: fx.url("home/two/b.txt")),
            MoveBack.Item(from: c, to: fx.url("home/one/taken.txt")),       // old place taken again
            MoveBack.Item(from: fx.url("vol2/gone.txt"), to: fx.url("home/one/gone.txt")),   // no longer there
            MoveBack.Item(from: d, to: fx.url("home/one/d.txt")),
            MoveBack.Item(from: try fx.file("vol2/e.txt"), to: fx.url("home/deleted/e.txt")),   // old folder gone
        ]
        let plan = MoveBack.plan(items, sameVolume: sameVolume)
        #expect(plan.renames.map(\.from) == [here])
        #expect(plan.transfers.map(\.folder.lastPathComponent) == ["one", "two"], "one job per folder, in order")
        #expect(plan.transfers[0].items.map(\.from) == [a, d])
        #expect(plan.transfers[1].items.map(\.from) == [b])
        #expect(plan.refused.map(\.from.lastPathComponent) == ["c.txt", "gone.txt", "e.txt"])
    }

    @Test func oldNamesComeBackAfterTheJob() {
        let items = [MoveBack.Item(from: URL(fileURLWithPath: "/v/a (2).txt"), to: URL(fileURLWithPath: "/h/a.txt")),
                     MoveBack.Item(from: URL(fileURLWithPath: "/v/b.txt"), to: URL(fileURLWithPath: "/h/b.txt"))]
        let committed = [(source: URL(fileURLWithPath: "/v/a (2).txt"), destination: URL(fileURLWithPath: "/h/a (2).txt")),
                         (source: URL(fileURLWithPath: "/v/b.txt"), destination: URL(fileURLWithPath: "/h/b.txt"))]
        #expect(MoveBack.renamesAfterTransfer(items, committed: committed)
                == [MoveBack.Item(from: URL(fileURLWithPath: "/h/a (2).txt"), to: URL(fileURLWithPath: "/h/a.txt"))])
    }

    /// Cross-volume undo: a move job brings the file back, removing the other copy only after copying.
    @Test func crossVolumeItemsGoBackThroughAMoveJob() async throws {
        guard let volume = ScratchVolume(megabytes: 12) else { return }
        let fx = try Fixture()
        try fx.folder("home")
        let away = volume.mount.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 2 << 20).write(to: away)
        let plan = MoveBack.plan([MoveBack.Item(from: away, to: fx.url("home/big.bin"))])
        #expect(plan.renames.isEmpty && plan.refused.isEmpty)
        let transfer = try #require(plan.transfers.first)
        let job = FileTransfer(kind: .move, sources: transfer.items.map(\.from), destination: transfer.folder)
        let report = await job.run(resolveConflict: { _ in ConflictDecision(.cancel) })
        #expect(report.committed.map(\.destination.lastPathComponent) == ["big.bin"])
        #expect(fx.exists("home/big.bin") && !FileManager.default.fileExists(atPath: away.path))
    }
}

// MARK: - "\" in ZIP names (qa-places #13)

@Suite struct ZipBackslashTests {
    @Test func interpretationFollowsTheHostAndTheExtractor() {
        #expect(ZipNames.interpret("a\\b.txt", windowsSeparators: false) == "a/b.txt", "no \"/\": libarchive splits")
        #expect(ZipNames.interpret("u/lit\\b.txt", windowsSeparators: false) == "u/lit\\b.txt", "Mac/Unix name keeps \"\\\"")
        #expect(ZipNames.interpret("w/mixed\\c.txt", windowsSeparators: true) == "w/mixed/c.txt")
        #expect(ZipNames.isWindowsHost(0) && ZipNames.isWindowsHost(10) && !ZipNames.isWindowsHost(3) && !ZipNames.isWindowsHost(19))
    }

    @Test func traversalWithBackslashesIsRejected() {
        for windows in [true, false] {
            for name in ["..\\..\\evil.txt", "\\abs\\x.txt", "C:\\Windows\\x.txt", "ok\\..\\..\\x.txt", "\\\\server\\share\\x"] {
                let shown = ZipNames.interpret(name, windowsSeparators: windows)
                #expect(ArchivePath.problem(shown) != nil, "\(name) windows=\(windows) → \(shown)")
            }
        }
        // A Mac name that merely contains "\" next to "/" stays one harmless component.
        #expect(ArchivePath.components(ZipNames.interpret("dir/..\\x", windowsSeparators: false)) == ["dir", "..\\x"])
    }

    private func extract(_ zip: URL, roots: [String], fx: Fixture) throws -> (plan: ExtractionPlanner.Plan, files: [String]) {
        let (listing, rewrites) = try ArchiveTool.extractionListing(zip)
        let plan = ExtractionPlanner.plan(entries: listing.entries, roots: roots)
        let staging = try fx.folder("staging-\(UUID().uuidString)")
        if !plan.isEmpty { try ArchiveTool.extract(zip, plan: plan, into: staging, process: ToolProcess(), rewritesBackslashes: rewrites) }
        _ = ExtractionVerifier.verify(staging: staging, base: [], quarantine: nil)
        let base = staging.path + "/"
        let files = (FileManager.default.enumerator(atPath: staging.path)?.allObjects as? [String] ?? [])
            .filter { !FileOps.isPlainFolder(URL(fileURLWithPath: base + $0)) }.sorted()
        // Nothing may land next to the staging folder.
        #expect(fx.names(".").allSatisfy { $0.hasPrefix("staging-") || $0.hasSuffix(".zip") || $0 == ".fixture-trash" })
        return (plan, files)
    }

    @Test func windowsArchiveShowsAndExtractsFolders() throws {
        let fx = try Fixture()
        var zip = TestZip()
        zip.members.append(.init(name: "win\\dir\\a.txt", data: Data("a".utf8), unixMode: 0, flags: 0, host: 0))
        zip.members.append(.init(name: "w/mixed\\c.txt", data: Data("c".utf8), unixMode: 0, flags: 0, host: 10))
        zip.members.append(.init(name: "..\\..\\evil.txt", data: Data("e".utf8), unixMode: 0, flags: 0, host: 0))
        let url = fx.url("win.zip")
        try zip.write(to: url)

        let shown = try ZipDirectory.read(url).map(\.rawPath)
        #expect(shown == ["win/dir/a.txt", "w/mixed/c.txt", "../../evil.txt"])
        #expect(try ZipDirectory.usesWindowsSeparators(url))
        let index = ArchiveIndex(entries: try ZipDirectory.read(url))
        #expect(index.children(of: "")?.map(\.name).sorted() == ["w", "win"], "the unsafe name isn't shown as a folder")

        let one = try extract(url, roots: ["w/mixed"], fx: fx)
        #expect(one.files == ["w/mixed/c.txt"])
        let all = try extract(url, roots: [""], fx: fx)
        #expect(all.files == ["w/mixed/c.txt", "win/dir/a.txt"])
        #expect(all.plan.rejected.map(\.reason) == [.unsafePath], "the traversal entry is reported, not extracted")
        #expect(!FileManager.default.fileExists(atPath: fx.root.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    @Test func macArchiveKeepsBackslashesInNamesWithSlashes() throws {
        let fx = try Fixture()
        var zip = TestZip()
        zip.file("u/lit\\b.txt", "b")        // made on a Mac: "\" is part of the name
        zip.file("plain\\x.txt", "x")        // no "/": read as a folder, as the extractor does
        zip.file("..\\up.txt", "u")          // becomes "../up.txt": rejected
        let url = fx.url("mac.zip")
        try zip.write(to: url)

        #expect(try ZipDirectory.read(url).map(\.rawPath) == ["u/lit\\b.txt", "plain/x.txt", "../up.txt"])
        #expect(try !ZipDirectory.usesWindowsSeparators(url))
        let lit = try extract(url, roots: ["u"], fx: fx)
        #expect(lit.files == ["u/lit\\b.txt"], "the member the view shows is the one extracted")
        let plain = try extract(url, roots: ["plain"], fx: fx)
        #expect(plain.files == ["plain/x.txt"])
        let all = try extract(url, roots: [""], fx: fx)
        #expect(all.plan.rejected.map(\.entry.rawPath) == ["../up.txt"])
    }
}

// MARK: - Display paths (qa-places #14)

@Suite struct DisplayPathTests {
    @Test func privatePrefixIsDroppedWhetherOrNotThePathExists() throws {
        #expect(DisplayPath.of("/private/tmp/x") == "/tmp/x")
        #expect(DisplayPath.of("/private/var/folders/a") == "/var/folders/a")
        #expect(DisplayPath.of("/private/etc") == "/etc")
        #expect(DisplayPath.of("/private/tmpfoo") == "/private/tmpfoo")
        #expect(DisplayPath.of("/Users/x/private/tmp") == "/Users/x/private/tmp")

        let fx = try Fixture()
        let existing = try fx.folder("L1")
        // /var links to /private/var; use the long spelling, as a folder picker or stored library may.
        guard existing.path.hasPrefix("/var/") else { return }
        let real = URL(fileURLWithPath: "/private" + existing.path)
        let missing = real.deletingLastPathComponent().appendingPathComponent("L2")
        let parentShown = { (url: URL) in (DisplayPath.of(url) as NSString).deletingLastPathComponent }
        #expect(parentShown(real) == parentShown(missing), "an existing and a missing folder in one place read alike")
        let library = LibraryDefinition(name: "Test", folders: [real, missing])
        let result = LibraryMerge.list(library, includeHidden: false)
        #expect(result.unavailable.count == 1)
        let text = DisplayPath.quotedList(result.unavailable.map(\.folder))
        #expect(!text.contains("/private/"), "\(text)")
        #expect(result.unavailable.first?.problem.contains("/private/") == false)
    }
}

// MARK: - Queued jobs in the journal (file-operations.md)

@Suite struct WaitingJobJournalTests {
    @Test func aJobThatNeverStartedIsRecognized() throws {
        let fx = try Fixture()
        let dir = fx.url("journal")
        let waiting = try JobJournal(directory: dir, kind: .copy, sources: [fx.url("a")], destination: fx.url("d"), pid: 99_999)
        waiting.abandon()
        let ran = try JobJournal(directory: dir, kind: .copy, sources: [fx.url("b")], destination: fx.url("d"), pid: 99_999)
        ran.markRunning()
        ran.abandon()
        let found = JobJournal.interrupted(in: dir) { _ in false }
        #expect(found.count == 2)
        let byFile = Dictionary(uniqueKeysWithValues: found.map { ($0.file.lastPathComponent, $0) })
        #expect(byFile[waiting.url.lastPathComponent]?.wasWaiting == true)
        #expect(byFile[ran.url.lastPathComponent]?.wasWaiting == false)
        #expect(byFile[ran.url.lastPathComponent]?.items.map(\.status) == [.notDone])
    }

    @Test func aJobThatRanIsNotWaitingEvenIfNothingFinished() async throws {
        let fx = try Fixture()
        try fx.file("src/a.txt")
        try fx.folder("dst")
        let dir = fx.url("journal")
        let journal = try JobJournal(directory: dir, kind: .copy, sources: [fx.url("src/a.txt")], destination: fx.url("dst"), pid: 99_999)
        let transfer = FileTransfer(kind: .copy, sources: [fx.url("src/a.txt")], destination: fx.url("dst"), journal: journal)
        transfer.retainsJournalWhenCancelled = true
        transfer.cancel()   // stopped at once, as when quitting: nothing is copied
        _ = await transfer.run(resolveConflict: { _ in ConflictDecision(.cancel) })
        let found = JobJournal.interrupted(in: dir) { _ in false }
        #expect(found.count == 1 && found.first?.wasWaiting == false)
    }

    @Test func oldJournalsAreNotMistakenForWaitingJobs() throws {
        let fx = try Fixture()
        let dir = try fx.folder("journal")
        let header = #"{"destination":"/d","id":"8D0A4C38-55B8-4E7C-9C59-000000000001","kind":"copy","pid":99999,"sources":["/a"],"started":"2026-11-01T10:00:00Z","version":1}"#
        try (header + "\n").write(to: dir.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
        let found = JobJournal.interrupted(in: dir) { _ in false }
        #expect(found.count == 1 && found[0].wasWaiting == false)
    }
}

// MARK: - Property Loss for folders (file-operations.md)

@Suite("Property Loss covers folders' own properties", .serialized)
struct FolderPropertyLossTests {
    private func transfer(_ fx: Fixture, log: LossLog, answer: @escaping @Sendable (MetadataLoss) -> MetadataLossDecision) -> FileTransfer {
        let t = FileTransfer(kind: .copy, sources: [fx.url("src/Tagged"), fx.url("src/Plain")], destination: fx.url("dst"),
                             options: FileTransfer.Options(allowClone: false, progressInterval: 0))
        t.capabilityCheck = { _ in VolumeCapabilities(nativeExtendedAttributes: false, accessControlLists: false) }
        t.metadataLossResolver = { loss in log.add(loss); return answer(loss) }
        return t
    }

    private func makeSources(_ fx: Fixture) throws {
        try fx.file("src/Tagged/inside.txt")
        try fx.file("src/Plain/inside.txt")
        try (fx.url("src/Tagged") as NSURL).setResourceValue(["Purple"], forKey: .tagNamesKey)
    }

    @Test func aTaggedFolderIsAskedAboutAndSkipLeavesItOut() async throws {
        let fx = try Fixture()
        try makeSources(fx)
        try fx.folder("dst")
        let log = LossLog()
        let report = await transfer(fx, log: log) { _ in MetadataLossDecision(.skip) }.run(resolveConflict: { _ in ConflictDecision(.cancel) })
        #expect(log.all.map(\.source.lastPathComponent) == ["Tagged"], "the plain folder and the files inside aren't asked about")
        #expect(log.all.first?.lost.contains(.tags) == true)
        #expect(!fx.exists("dst/Tagged") && fx.exists("dst/Plain/inside.txt"))
        #expect(report.results.first?.outcome == .skipped("Skipped: the destination can't keep this item's properties."))
    }

    @Test func yesCopiesTheFolderAndCancelStops() async throws {
        let fx = try Fixture()
        try makeSources(fx)
        try fx.folder("dst")
        let report = await transfer(fx, log: LossLog()) { _ in MetadataLossDecision(.copyWithout) }.run(resolveConflict: { _ in ConflictDecision(.cancel) })
        #expect(report.problems.isEmpty && fx.exists("dst/Tagged/inside.txt"))

        let fx2 = try Fixture()
        try makeSources(fx2)
        try fx2.folder("dst")
        let cancelled = await transfer(fx2, log: LossLog()) { _ in MetadataLossDecision(.cancel) }.run(resolveConflict: { _ in ConflictDecision(.cancel) })
        #expect(cancelled.wasCancelled && fx2.names("dst").isEmpty)
    }
}

// MARK: - Headless safety audit

/// Headless runs must never open anything on screen, so app code must reach the system via `SystemOpen`.
@Suite struct SystemOpenAuditTests {
    static let forbidden = [
        "NSWorkspace.shared.open(", "activateFileViewerSelecting", "setDesktopImageURL",
        "setDefaultApplication(", "unmountAndEjectDevice", ".openApplication(at", "launchApplication(",
        "NSSharingServicePicker(", ".perform(withItems", "\"/usr/bin/open\"", "\"/usr/bin/osascript\"", "NSAppleScript(",
        "openURLs(", "selectFile(",
    ]

    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Arbor")
    }

    @Test func systemRequestsGoThroughSystemOpen() throws {
        var offenders: [String] = []
        let files = (FileManager.default.enumerator(atPath: Self.sources.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
        #expect(files.count > 50, "found the app sources")
        for file in files where !file.hasSuffix("Support/SystemOpen.swift") {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for pattern in Self.forbidden where code.contains(pattern) {
                    // SystemOpen's own methods share some names (SystemOpen.openApplication(at:)…).
                    if code.contains(pattern.hasPrefix(".") ? "SystemOpen" + pattern : "SystemOpen." + pattern) { continue }
                    offenders.append("\(file):\(number + 1): \(pattern)")
                }
                // Quick Look's panel and disk images attached without "-nobrowse" show windows too.
                if text.contains("QLPreviewPanel"), code.contains("OrderFront("), code.lowercased().contains("panel") {
                    offenders.append("\(file):\(number + 1): Quick Look panel shown directly")
                }
                if code.contains("\"attach\""), !code.contains("SystemOpen.attachArguments") {
                    offenders.append("\(file):\(number + 1): hdiutil attach without SystemOpen.attachArguments")
                }
            }
        }
        #expect(offenders.isEmpty, "Use SystemOpen instead:\n\(offenders.joined(separator: "\n"))")
    }
}
