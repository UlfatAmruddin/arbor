import Foundation
import Testing
@testable import ArborCore

private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
private let work = URL(fileURLWithPath: "/Users/me/work", isDirectory: true)

private func parse(_ text: String, base: URL? = work) -> PathCompletionQuery? {
    PathCompletionQuery.parse(text, base: base, homeDirectory: home)
}

private func entry(_ name: String, folder: Bool = false, hidden: Bool = false) -> PathCompletionEntry {
    PathCompletionEntry(name: name, isFolder: folder, isHidden: hidden)
}

@Suite("Address completion: parsing typed text (FE-006)")
struct PathCompletionQueryTests {
    @Test func absolutePathSplitsAtTheLastSlash() throws {
        let query = try #require(parse("/Users/me/Doc"))
        #expect(query.literalPrefix == "/Users/me/")
        #expect(query.folder.path == "/Users/me")
        #expect(query.typedName == "Doc")
    }

    @Test func rootAndTrailingSlash() throws {
        #expect(try #require(parse("/")).folder.path == "/")
        #expect(try #require(parse("/Us")).folder.path == "/")
        let query = try #require(parse("/Users/me/"))
        #expect(query.folder.path == "/Users/me")
        #expect(query.typedName.isEmpty)
    }

    @Test func tildeFormsKeepWhatWasTyped() throws {
        let query = try #require(parse("~/Doc"))
        #expect(query.literalPrefix == "~/")
        #expect(query.folder.path == "/Users/me")
        #expect(query.typedName == "Doc")
        #expect(try #require(parse("~/a/b")).folder.path == "/Users/me/a")
        #expect(parse("~") == nil)
    }

    @Test func relativeTextUsesTheBaseOrHome() throws {
        #expect(try #require(parse("na")).folder.path == "/Users/me/work")
        #expect(try #require(parse("a/b")).folder.path == "/Users/me/work/a")
        #expect(try #require(parse("na", base: nil)).folder.path == "/Users/me")
    }

    @Test func dotsAreRemovedLexically() throws {
        #expect(try #require(parse("/Users/me/../you/x")).folder.path == "/Users/you")
        #expect(try #require(parse("../x")).folder.path == "/Users/me")
        #expect(try #require(parse("./a/x")).folder.path == "/Users/me/work/a")
        #expect(try #require(parse("/../../x")).folder.path == "/")
        #expect(try #require(parse("/a//b///c")).folder.path == "/a/b")
    }

    @Test(arguments: [
        "", " x", "\u{00A0}x", "\"x", "'x", "~root", "~root/x", "//server/share", "\\\\server\\share", "file:///tmp/x",
        "smb://host/share", "HTTP://x", "C:", "C:\\x", "C:/x", "shell:downloads", "SHELL:Downloads", "a\u{0}b", "a\nb", "/tmp/\u{7}",
    ]) func formsThatNeverReachTheDisk(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func oversizedTextIsRefused() {
        #expect(parse("/" + String(repeating: "a", count: 1_023)) != nil)
        #expect(parse("/" + String(repeating: "a", count: 1_024)) == nil)
    }

    /// `URL(fileURLWithPath:)` without `isDirectory:` stats the path, which would block on a hung share.
    @Test func theFolderNeverDependsOnWhatIsOnDisk() throws {
        let fixture = try Fixture()
        try fixture.folder("real")
        try fixture.file("plain")
        for name in ["real", "plain", "missing"] {
            let query = try #require(parse(fixture.root.appendingPathComponent(name).path + "/x"))
            #expect(query.folder.hasDirectoryPath, "\(name)")
        }
    }

    /// `standardizedFileURL` removes /private only when the path exists, which means asking the disk.
    @Test func privatePathsStayAsTyped() throws {
        #expect(try #require(parse("/private/tmp/x")).folder.path == "/private/tmp")
        #expect(try #require(parse("/private/no-such-folder/x")).folder.path == "/private/no-such-folder")
    }
}

@Suite("Address completion: rows (FE-006)")
struct PathCompletionCandidateTests {
    private func rows(_ entries: [PathCompletionEntry], _ text: String, hidden: Bool = false) throws -> [String] {
        PathCompletion.candidates(in: entries, for: try #require(parse(text)), includeHidden: hidden).rows.map(\.text)
    }

    @Test func theTypedFormIsKept() throws {
        #expect(try rows([entry("Documents", folder: true)], "~/Doc") == ["~/Documents/"])
        #expect(try rows([entry("Documents", folder: true)], "/Users/me/doc") == ["/Users/me/Documents/"])
        #expect(try rows([entry("a.txt")], "../a") == ["../a.txt"])
    }

    @Test func matchingIgnoresCaseUnicodeFormAndWidth() throws {
        #expect(try rows([entry("Report.txt")], "/x/REP") == ["/x/Report.txt"])
        #expect(try rows([entry("Caf\u{00E9}.txt")], "/x/Cafe\u{0301}") == ["/x/Caf\u{00E9}.txt"])
        #expect(try rows([entry("Cafe\u{0301}.txt")], "/x/Caf\u{00E9}") == ["/x/Cafe\u{0301}.txt"])
        #expect(try rows([entry("Doc.txt")], "/x/\u{FF24}oc") == ["/x/Doc.txt"])
    }

    @Test func hiddenItemsNeedThePreferenceOrADot() throws {
        let entries = [entry(".git", folder: true, hidden: true), entry("visible")]
        #expect(try rows(entries, "/x/") == ["/x/visible"])
        #expect(try rows(entries, "/x/", hidden: true) == ["/x/.git/", "/x/visible"])
        #expect(try rows(entries, "/x/.") == ["/x/.git/"])
    }

    @Test func theLimitIsReported() throws {
        let entries = (0..<13).map { entry("file\($0)") }
        let capped = PathCompletion.candidates(in: entries, for: try #require(parse("/x/file")), includeHidden: false)
        #expect(capped.rows.count == PathCompletion.rowLimit)
        #expect(capped.hasMore)
        let exact = PathCompletion.candidates(in: Array(entries.prefix(12)), for: try #require(parse("/x/file")), includeHidden: false)
        #expect(exact.rows.count == 12)
        #expect(!exact.hasMore)
    }

    @Test(arguments: [
        "bad\nname", "bad\u{0}name", "evil\u{202E}txt", "evil\u{2066}txt", "ends with space ", "ends with nbsp\u{00A0}", "two/parts", "",
    ]) func hostileNamesAreNeverOffered(_ name: String) throws {
        #expect(try rows([entry(name)], "/x/").isEmpty)
    }

    @Test func aFolderOfRejectedNamesStopsTheScan() throws {
        let hostile = (0..<(PathCompletion.rejectedLimit + 5)).map { entry("f\($0)\u{7}") }
        let query = try #require(parse("/x/f"))
        let stopped = PathCompletion.candidates(in: hostile + [entry("fine")], for: query, includeHidden: false)
        #expect(stopped.rows.isEmpty)
        #expect(stopped.hasMore)
        let underLimit = Array(hostile.prefix(PathCompletion.rejectedLimit - 1)) + [entry("fine")]
        let kept = PathCompletion.candidates(in: underLimit, for: query, includeHidden: false)
        #expect(kept.rows.map(\.name) == ["fine"])
        #expect(!kept.hasMore)
    }

    @Test func aTrailingSpaceCountsAsRejected() throws {
        let names = (0..<PathCompletion.rejectedLimit).map { entry("f\($0) ") }
        #expect(PathCompletion.candidates(in: names, for: try #require(parse("/x/f")), includeHidden: false).hasMore)
    }

    @Test(arguments: [
        (true, true, PathCompletionNotice?.some(.moreMatches)),
        (false, true, PathCompletionNotice?.none),
        (true, false, PathCompletionNotice?.some(.partialListing)),
        (false, false, PathCompletionNotice?.some(.partialListing)),
    ]) func theNoticeNeverPromisesWhatTypingCantDo(_ hasMore: Bool, _ complete: Bool, _ expected: PathCompletionNotice?) {
        #expect(PathCompletion.notice(hasMore: hasMore, listingIsComplete: complete) == expected)
    }

    @Test func joinersStayBecauseRealNamesUseThem() throws {
        #expect(try rows([entry("می\u{200C}خواهم.txt")], "/x/") == ["/x/می\u{200C}خواهم.txt"])
    }

    /// Width-insensitive matching is how a bare name like `~user` can come up at all.
    @Test(arguments: [
        ("C", "C:"), ("\u{FF5E}", "~user"), ("\u{FF5E}", "~"), ("s", "shell:x"), ("\\", "\\\\server"),
        ("\u{FF02}", "\"quoted\""), ("\u{FF07}", "'quoted'"),
    ]) func namesThatWouldParseAsSomethingElseAreDroppedWhenBare(_ typed: String, _ name: String) throws {
        let query = try #require(parse(typed))
        #expect(PathCompletion.candidates(in: [entry(name)], for: query, includeHidden: true).rows.isEmpty)
    }

    @Test func aRowIdenticalToTheTextIsDropped() throws {
        #expect(try rows([entry("a.txt")], "/x/a.txt").isEmpty)
        #expect(try rows([entry("a.txt"), entry("a.txt.bak")], "/x/a.txt").count == 2)
        #expect(try rows([entry("a", folder: true)], "/x/a") == ["/x/a/"])
    }

    @Test(arguments: ["network", "home", "trash", "bin", "gallery", "computer", "this mac", "recycle bin"])
    func placeKeywordsAreOnlyOfferedWhereTheyReachTheItem(_ name: String) throws {
        let bare = entry(name)
        let query = try #require(parse(String(name.prefix(2))))
        #expect(PathCompletion.candidates(in: [bare], for: query, includeHidden: false).rows.isEmpty)
        #expect(PathCompletion.candidates(in: [entry(name, folder: true)], for: query, includeHidden: false).rows.map(\.text) == [name + "/"])
        #expect(try rows([bare], "/x/").count == 1)
    }

    @Test func aFolderNamedTildeReachedThroughWidthIsNotOffered() throws {
        let query = try #require(parse("\u{FF5E}"))
        #expect(PathCompletion.candidates(in: [entry("~", folder: true)], for: query, includeHidden: false).rows.isEmpty)
    }

    /// Whatever is offered must open the item it names, through the same steps Return takes.
    @Test func everyOfferedRowResolvesToItsItem() throws {
        let names = ["plain", "with space", "network", "home", "trash", "bin", "gallery", "computer", "~", "~x", "C:", "D:x", "a:b",
                     "shell:downloads", "smb:", "..x", "...", "'q", "\"q", "Caf\u{00E9}", "Cafe\u{0301}", "\u{FF24}oc", "\\\\s", "-dash"]
        let entries = names.flatMap { [entry($0), entry($0, folder: true)] }
        let resolver = PathResolver(homeDirectory: home, probe: { _ in true })
        let bareStarts = ["p", "w", "n", "h", "t", "b", "g", "c", "\u{FF5E}", "D", "a", "s", "-", "\\", ".", "\u{FF02}", "\u{FF07}"]
        var offeredCount = 0
        for text in bareStarts + ["/Users/me/work/", "~/work/", "../work/", "./"] {
            let query = try #require(parse(text))
            let offered = PathCompletion.candidates(in: entries, for: query, includeHidden: true, limit: entries.count).rows
            offeredCount += offered.count
            for row in offered {
                #expect(Location.keyword(row.text) == nil, "\(row.text)")
                guard case .success(.folder(let url)) = resolver.resolve(row.text, relativeTo: work) else {
                    Issue.record("\(row.text) did not resolve")
                    continue
                }
                let expected = query.folder.appendingPathComponent(row.name, isDirectory: false).path
                #expect(url.path == expected, "\(row.text)")
            }
        }
        #expect(offeredCount > names.count)
    }
}

@Suite("Address completion: bounded listing (FE-006)")
struct BoundedListingTests {
    private func listing(_ folder: URL, limit: Int = 100, timeLimit: TimeInterval = 30,
                         cancellation: ScanCancellation = ScanCancellation()) -> BoundedListing {
        DirectoryLister.boundedEntries(of: folder, limit: limit, timeLimit: timeLimit, cancellation: cancellation)
    }

    @Test func foldersComeFirstThenNaturalOrder() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("list")
        for name in ["b10.txt", "b2.txt"] { try fixture.file("list/\(name)") }
        try fixture.folder("list/z")
        let result = listing(root)
        #expect(result.entries.map(\.name) == ["z", "b2.txt", "b10.txt"])
        #expect(result.isComplete)
        #expect(!result.wasCancelled)
    }

    @Test func theCapStopsTheScan() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("list")
        for index in 0..<5 { try fixture.file("list/\(index)") }
        let result = listing(root, limit: 3)
        #expect(result.entries.count == 3)
        #expect(!result.isComplete)
    }

    @Test func theTimeLimitGivesAPartialResult() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("list")
        try fixture.file("list/a")
        let result = listing(root, timeLimit: 0)
        #expect(result.entries.isEmpty)
        #expect(!result.isComplete)
        #expect(!result.wasCancelled)
    }

    @Test func cancellationIsReportedAndKeepsNothing() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("list")
        try fixture.file("list/a")
        let cancellation = ScanCancellation()
        cancellation.cancel()
        let result = listing(root, cancellation: cancellation)
        #expect(result.wasCancelled)
        #expect(result.entries.isEmpty)
    }

    @Test func linksAreNotFollowed() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("list")
        let target = try fixture.folder("target")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        #expect(listing(root).entries == [entry("link")])
    }

    @Test func aFolderReachedThroughALinkIsListed() throws {
        let fixture = try Fixture()
        let target = try fixture.folder("target")
        try fixture.file("target/inner.txt")
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = listing(link)
        #expect(result.entries == [entry("inner.txt")])
        #expect(result.isComplete)
    }

    @Test func aBrokenLinkIsEmpty() throws {
        let fixture = try Fixture()
        let link = fixture.root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.root.appendingPathComponent("gone").path)
        let result = listing(link)
        #expect(result.entries.isEmpty)
        #expect(!result.isComplete)
    }

    @Test func hiddenFlagsAreReported() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("list")
        try fixture.file("list/.dot")
        #expect(listing(root).entries == [entry(".dot", hidden: true)])
    }

    @Test func missingFolderIsEmpty() throws {
        let fixture = try Fixture()
        let result = listing(fixture.root.appendingPathComponent("missing", isDirectory: true))
        #expect(result.entries.isEmpty)
        #expect(!result.isComplete)
    }

    @Test(.enabled(if: getuid() != 0)) func deniedFolderIsEmpty() throws {
        let fixture = try Fixture()
        let root = try fixture.folder("locked")
        try fixture.file("locked/a")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let result = listing(root)
        #expect(result.entries.isEmpty)
        #expect(!result.isComplete)
    }

    @Test func placeholderDownloadsAreOffOnlyDuringTheScan() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        let during = DirectoryLister.withoutDatalessMaterialization { getiopolicy_np(type, IOPOL_SCOPE_THREAD) }
        #expect(during == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == before)
    }
}

@Suite("Address completion: volumes (FE-006)")
struct VolumeClassTests {
    private let mounts = [
        MountEntry(path: "/", isLocal: true, fileSystemType: "apfs"),
        MountEntry(path: "/Volumes/Share", isLocal: false, fileSystemType: "smbfs"),
        MountEntry(path: "/Volumes/Share/Disk", isLocal: true, fileSystemType: "apfs"),
        MountEntry(path: "/System/Volumes/Data/home", isLocal: false, fileSystemType: "autofs"),
        MountEntry(path: "/Volumes/Caf\u{00E9}", isLocal: false, fileSystemType: "nfs"),
    ]

    @Test func theLongestMountWins() {
        #expect(MountPoints.classify("/Users/me", mounts: mounts) == .local)
        #expect(MountPoints.classify("/Volumes/Share", mounts: mounts) == .network)
        #expect(MountPoints.classify("/Volumes/Share/a", mounts: mounts) == .network)
        #expect(MountPoints.classify("/Volumes/Share/Disk/a", mounts: mounts) == .local)
    }

    @Test func aSimilarNameIsNotInsideTheMount() {
        #expect(MountPoints.classify("/Volumes/Shared/a", mounts: mounts) == .local)
    }

    @Test func caseAndUnicodeFormDontMatter() {
        #expect(MountPoints.classify("/volumes/SHARE/a", mounts: mounts) == .network)
        #expect(MountPoints.classify("/Volumes/Cafe\u{0301}/a", mounts: mounts) == .network)
    }

    @Test func autofsEntriesAreAutomounts() {
        #expect(MountPoints.classify("/System/Volumes/Data/home/me", mounts: mounts) == .automount)
    }

    @Test(arguments: ["/home", "/home/me", "/HOME/me", "/net", "/net/server/x", "/Network/Servers", "/Network/Servers/nas/a"])
    func theEntriesMacOSShipsAreAutomountsWhateverTheTableSays(_ path: String) {
        #expect(MountPoints.classify(path, mounts: mounts) == .automount)
    }

    @Test func similarNamesAreNotAutomounts() {
        #expect(MountPoints.classify("/homework", mounts: mounts) == .local)
        #expect(MountPoints.classify("/network/other", mounts: mounts) == .local)
    }

    @Test func theLiveTableClassifiesTheRoot() {
        #expect(MountPoints.shared.volumeClass(containing: "/") == .local)
        #expect(MountPoints.shared.volumeClass(containing: "/home/someone") == .automount)
    }
}

@Suite("Address completion: lanes (FE-006)")
struct PathListingQueueTests {
    /// Blocks each scan until released, and records the cancellation it was given.
    private final class Gate: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var seen: [ScanCancellation] = []

        var scans: [ScanCancellation] { lock.withLock { seen } }

        func lister(_ folder: URL, _ lane: PathCompletionLane, _ cancellation: ScanCancellation) -> BoundedListing {
            lock.withLock { seen.append(cancellation) }
            started.signal()
            release.wait()
            return BoundedListing(entries: [], isComplete: true, wasCancelled: cancellation.isCancelled)
        }
    }

    private let callbacks = DispatchQueue(label: "test.listing.callbacks")
    private let folder = URL(fileURLWithPath: "/x", isDirectory: true)

    private func lane(cap: Int = 2, timeout: TimeInterval = 30) -> PathCompletionLane {
        PathCompletionLane(debounce: 0, scanTimeLimit: 1, queueTimeout: timeout, entryCap: 10, inFlightCap: cap)
    }

    private func start(_ queue: PathListingQueue, _ key: String, finished: @escaping (BoundedListing) -> Void = { _ in },
                       late: @escaping (BoundedListing) -> Void = { _ in }) -> PathListingQueue.Job? {
        callbacks.sync { queue.start(key: key, folder: folder, finished: finished, late: late) }
    }

    private func makeQueue(_ gate: Gate, lane: PathCompletionLane) -> PathListingQueue {
        PathListingQueue(lane: lane, label: "test.listing", callbackQueue: callbacks, lister: { gate.lister($0, $1, $2) })
    }

    @Test(arguments: [PathCompletionLane.local, .network])
    func aScanAlwaysEndsBeforeItsQueueTimesOut(_ lane: PathCompletionLane) {
        #expect(lane.scanTimeLimit < lane.queueTimeout)
        #expect(lane.debounce > 0 && lane.entryCap > 0 && lane.inFlightCap > 0)
    }

    @Test func aFullLaneRefusesNewFoldersButStillJoinsRunningOnes() {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane(cap: 1))
        #expect(start(queue, "a") != nil)
        gate.started.wait()
        #expect(start(queue, "b") == nil)
        #expect(start(queue, "a") != nil)
        gate.release.signal()
    }

    @Test func aFinishedListingIsDelivered() async {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane())
        let result = await withCheckedContinuation { continuation in
            _ = start(queue, "a", finished: { continuation.resume(returning: $0) })
            gate.release.signal()
        }
        #expect(result.isComplete)
    }

    @Test func aJoinedRequestCancelsTheScanThatIsActuallyRunning() {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane())
        _ = start(queue, "a")
        gate.started.wait()
        let joined = start(queue, "a")
        #expect(gate.scans.count == 1)
        callbacks.sync { if let joined { queue.cancel(joined) } }
        #expect(gate.scans[0].isCancelled)
        gate.release.signal()
    }

    @Test func rejoiningACancelledScanReportsItsCancellation() async {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane())
        let first = start(queue, "a")
        gate.started.wait()
        callbacks.sync { if let first { queue.cancel(first) } }
        let result = await withCheckedContinuation { continuation in
            _ = start(queue, "a", finished: { continuation.resume(returning: $0) })
            gate.release.signal()
        }
        #expect(result.wasCancelled)
    }

    @Test func aCancelledRequestGetsNoCallback() async {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane())
        let called = Locked(false)
        let first = start(queue, "a", finished: { _ in called.value = true })
        gate.started.wait()
        callbacks.sync { if let first { queue.cancel(first) } }
        gate.release.signal()
        await waitUntilIdle(queue)
        #expect(!called.value)
    }

    @Test func aResultAfterTheTimeoutGoesToLateOnly() async {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane(timeout: 0.01))
        let finished = Locked(false)
        let result = await withCheckedContinuation { continuation in
            _ = start(queue, "a", finished: { _ in finished.value = true }, late: { continuation.resume(returning: $0) })
            gate.started.wait()
            callbacks.asyncAfter(deadline: .now() + 0.05) { gate.release.signal() }
        }
        #expect(result.isComplete)
        #expect(!finished.value)
    }

    @Test func aNewScanAfterTheLastEndedGetsAFreshToken() async {
        let gate = Gate()
        let queue = makeQueue(gate, lane: lane())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = start(queue, "a", finished: { _ in continuation.resume() })
            gate.started.wait()
            gate.release.signal()
        }
        await waitUntilIdle(queue)
        _ = start(queue, "a")
        gate.started.wait()
        gate.release.signal()
        #expect(gate.scans.count == 2)
        #expect(gate.scans[0] !== gate.scans[1])
    }

    private func waitUntilIdle(_ queue: PathListingQueue) async {
        for _ in 0..<2_000 {
            if callbacks.sync(execute: { !queue.isRunning(key: "a") }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("the queue never went idle")
    }

    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
