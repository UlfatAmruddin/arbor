import Foundation
import Testing
@testable import ArborCore

@Suite("What the clipboard may hand over as files (FE-101)")
struct ClipboardFilesTests {
    private let a = URL(fileURLWithPath: "/Users/me/a.txt")
    private let b = URL(fileURLWithPath: "/Users/me/b.txt")

    private func read(_ urls: [URL], itemCount: Int? = nil, volumeRoots: Set<String> = []) -> ClipboardFiles.Contents {
        ClipboardFiles.read(itemCount: itemCount ?? urls.count, urls: { urls }, isVolumeRoot: { volumeRoots.contains($0.path) })
    }

    @Test func localFilesAreKeptInOrder() {
        #expect(read([b, a]) == .files([b, a]))
    }

    @Test func anEmptyClipboardIsNothing() {
        #expect(read([]) == .nothing)
    }

    @Test func tooManyItemsAreRefusedWithoutReadingThem() {
        var asked = false
        let result = ClipboardFiles.read(itemCount: ClipboardFiles.maxItems + 1, urls: { asked = true; return [] }, isVolumeRoot: { _ in false })
        #expect(result == .refused(.tooManyItems(ClipboardFiles.maxItems + 1)))
        #expect(!asked)
    }

    @Test func exactlyTheLimitIsRead() {
        var asked = false
        _ = ClipboardFiles.read(itemCount: ClipboardFiles.maxItems, urls: { asked = true; return [] }, isVolumeRoot: { _ in false })
        #expect(asked)
    }

    @Test func itemsThatWereNotURLsRefuseEverything() {
        #expect(read([a], itemCount: 2) == .refused(.notLocalFiles))
    }

    @Test(arguments: ["https://example.com/a", "ftp://server/a", "file://server/share/a", "file:relative/a",
                      "file:///Users/me/a%00b", "file:///Users/me/a?x=1", "file:///Users/me/a#part", "file:///.file/id=1.2"])
    func oneBadURLRefusesEverything(text: String) throws {
        #expect(read([a, try #require(URL(string: text))]) == .refused(.notLocalFiles))
    }

    @Test func anAbsurdlyLongURLIsRefused() throws {
        let url = try #require(URL(string: "file:///" + String(repeating: "a", count: ClipboardFiles.maxURLBytes)))
        #expect(read([url]) == .refused(.notLocalFiles))
    }

    @Test func localhostIsLocal() throws {
        #expect(read([try #require(URL(string: "file://localhost/Users/me/a.txt"))]) != .refused(.notLocalFiles))
    }

    @Test func dotsAreResolvedBeforeAnythingUsesThePath() throws {
        let url = try #require(URL(string: "file:///Users/me/sub/../a.txt"))
        #expect(read([url]) == .files([a]))
    }

    @Test func aDiskAmongTheFilesRefusesEverything() {
        let disk = URL(fileURLWithPath: "/Volumes/Backup")
        #expect(read([a, disk], volumeRoots: [disk.path]) == .refused(.wholeDisk))
    }

    @Test func aRootReachedThroughDotsIsStillADisk() throws {
        let sneaky = try #require(URL(string: "file:///Volumes/Backup/sub/.."))
        #expect(read([sneaky], volumeRoots: ["/Volumes/Backup"]) == .refused(.wholeDisk))
    }

    @Test func theSameFileTwiceIsPastedOnce() {
        #expect(read([a, b, a]) == .files([a, b]))
    }

    @Test func textIsOnePathPerLineWithoutQuotes() {
        #expect(ClipboardFiles.plainText(for: [a, b]) == "/Users/me/a.txt\n/Users/me/b.txt")
    }

    @Test(arguments: [ItemOutcome.skipped("kept"), .cancelled, .failed("no"), .partial(URL(fileURLWithPath: "/d/a"), "no")])
    func aMoveThatLeftSomethingBehindIsNotFinished(outcome: ItemOutcome) {
        #expect(!report(.move, outcomes: [.succeeded(URL(fileURLWithPath: "/d/a")), outcome]).movedEverything)
    }

    @Test func aCompleteMoveIsFinished() {
        #expect(report(.move, outcomes: [.succeeded(URL(fileURLWithPath: "/d/a")), .merged(URL(fileURLWithPath: "/d/b"))]).movedEverything)
    }

    @Test func aCancelledReportAndACopyAreNot() {
        #expect(!report(.move, outcomes: [.succeeded(URL(fileURLWithPath: "/d/a"))], cancelled: true).movedEverything)
        #expect(!report(.copy, outcomes: [.succeeded(URL(fileURLWithPath: "/d/a"))]).movedEverything)
        #expect(!report(.move, outcomes: []).movedEverything)
    }

    private func report(_ kind: TransferKind, outcomes: [ItemOutcome], cancelled: Bool = false) -> TransferReport {
        let results = outcomes.map { ItemResult(source: URL(fileURLWithPath: "/s/a"), outcome: $0) }
        return TransferReport(kind: kind, destination: URL(fileURLWithPath: "/d"), results: results, details: [],
                              wasCancelled: cancelled, fingerprints: [:])
    }
}
