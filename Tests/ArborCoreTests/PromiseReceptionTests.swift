import Foundation
import Testing
@testable import ArborCore

/// A provider scripted by the test; the reader is kept so a test can call it late, or twice.
private final class FakePromise: FilePromiseSource, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]
    private let deliver: @Sendable (URL, @escaping @Sendable (URL, Error?) -> Void) -> Void

    init(names: [String], deliver: @escaping @Sendable (URL, @escaping @Sendable (URL, Error?) -> Void) -> Void) {
        self.names = names
        self.deliver = deliver
    }

    var promisedNames: [String] {
        get { lock.withLock { names } }
        set { lock.withLock { names = newValue } }
    }

    func receive(into folder: URL, reader: @escaping @Sendable (URL, Error?) -> Void) { deliver(folder, reader) }

    /// Writes `name` in full and reports success.
    static func delivering(_ name: String, _ text: String = "content") -> FakePromise {
        FakePromise(names: [name]) { folder, reader in
            let target = folder.appendingPathComponent(name)
            try? Data(text.utf8).write(to: target)
            reader(target, nil)
        }
    }
}

private struct FakeProviderError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private final class Run: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [PromiseReception.Outcome] = []
    private var progressReports: [PromiseReception.Progress] = []
    private var continuation: CheckedContinuation<PromiseReception.Outcome, Never>?

    func finished(_ outcome: PromiseReception.Outcome) {
        let waiting = lock.withLock { () -> CheckedContinuation<PromiseReception.Outcome, Never>? in
            outcomes.append(outcome)
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: outcome)
    }

    func note(_ progress: PromiseReception.Progress) { lock.withLock { progressReports.append(progress) } }

    func outcome() async -> PromiseReception.Outcome {
        await withCheckedContinuation { next in
            let ready = lock.withLock { () -> PromiseReception.Outcome? in
                if let first = outcomes.first { return first }
                continuation = next
                return nil
            }
            if let ready { next.resume(returning: ready) }
        }
    }

    var completions: Int { lock.withLock { outcomes.count } }
    var progress: [PromiseReception.Progress] { lock.withLock { progressReports } }
}

@Suite("Receiving file promises")
struct PromiseReceptionTests {
    /// A destination folder with a file that must never change.
    private final class Place {
        let root: URL, destination: URL, existing: URL
        private(set) var stagings: [URL] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("arbor-tests-promise-\(UUID().uuidString)")
            destination = root.appendingPathComponent("destination")
            existing = destination.appendingPathComponent("report.txt")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("already here".utf8).write(to: existing)
        }

        deinit {
            stagings.forEach(TemporaryFiles.removeTree)
            try? FileManager.default.removeItem(at: root)
        }

        func reception(_ sources: [FilePromiseSource], stall: TimeInterval = 30, quiet: TimeInterval = 0.1) throws -> PromiseReception {
            let reception = try PromiseReception(sources: sources, near: destination, stallLimit: stall, sampleInterval: 0.02, quietWindow: quiet)
            stagings.append(reception.stagingFolder)
            return reception
        }

        func start(_ reception: PromiseReception) -> Run {
            let run = Run()
            reception.start(progress: { run.note($0) }, completion: { run.finished($0) })
            return run
        }

        func receive(_ sources: [FilePromiseSource], stall: TimeInterval = 30, quiet: TimeInterval = 0.1) async throws -> (PromiseReception, PromiseReception.Outcome) {
            let reception = try reception(sources, stall: stall, quiet: quiet)
            return (reception, await start(reception).outcome())
        }

        var destinationNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
        }

        func expectExistingUntouched() throws {
            #expect(try String(contentsOf: existing, encoding: .utf8) == "already here")
            #expect(destinationNames == ["report.txt"])
        }
    }

    private func reasons(_ outcome: PromiseReception.Outcome) -> [PromiseFailure.Reason] { outcome.failures.map(\.reason) }

    @Test func aCompletedPromiseIsReceivedFromStaging() async throws {
        let place = try Place()
        let (reception, outcome) = try await place.receive([FakePromise.delivering("a.txt", "hello")])
        #expect(outcome.failures.isEmpty && !outcome.wasCancelled)
        #expect(outcome.received.map(\.lastPathComponent) == ["a.txt"])
        #expect(outcome.received[0].path.hasPrefix(reception.stagingFolder.path))
        #expect(outcome.received[0].deletingLastPathComponent().lastPathComponent == PromiseReception.slotDisplayName)
        #expect(try String(contentsOf: outcome.received[0], encoding: .utf8) == "hello")
        try place.expectExistingUntouched()
    }

    @Test func anErrorMeansFailureEvenWhenAWholeFileIsThere() async throws {
        let place = try Place()
        let source = FakePromise(names: ["a.txt"]) { folder, reader in
            let target = folder.appendingPathComponent("a.txt")
            try? Data("looks complete".utf8).write(to: target)
            reader(target, FakeProviderError(text: "Mail couldn't fetch it."))
        }
        let (reception, outcome) = try await place.receive([source])
        #expect(outcome.received.isEmpty)
        #expect(outcome.failures == [PromiseFailure(name: "a.txt", reason: .providerError("Mail couldn't fetch it."))])
        reception.discard()
        reception.flush()
        #expect(!FileManager.default.fileExists(atPath: reception.stagingFolder.path))
        try place.expectExistingUntouched()
    }

    @Test func aFileThatExistsIsNotSuccessWithoutTheProvidersWord() async throws {
        let place = try Place()
        let source = FakePromise(names: ["a.txt"]) { folder, _ in
            try? Data("partial".utf8).write(to: folder.appendingPathComponent("a.txt"))
        }
        let (_, outcome) = try await place.receive([source], stall: 0.1)
        #expect(outcome.received.isEmpty)
        #expect(outcome.failures == [PromiseFailure(name: "a.txt", reason: .providerUnavailable)])
        try place.expectExistingUntouched()
    }

    @Test func aProviderThatStaysSilentIsReportedUnavailable() async throws {
        let place = try Place()
        let (_, outcome) = try await place.receive([FakePromise(names: []) { _, _ in }], stall: 0.1)
        #expect(outcome.failures == [PromiseFailure(name: nil, reason: .providerUnavailable)])
    }

    @Test func anUndeclaredPromiseKeepsAFileThatArrivesLate() async throws {
        let place = try Place()
        let source = FakePromise(names: []) { folder, reader in
            let first = folder.appendingPathComponent("one.txt")
            try? Data("1".utf8).write(to: first)
            reader(first, nil)
            // Its own thread: when every test runs at once the shared pool can start this too late.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.2)
                let second = folder.appendingPathComponent("two.txt")
                try? Data("2".utf8).write(to: second)
                reader(second, nil)
            }
        }
        let (_, outcome) = try await place.receive([source], quiet: 1)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.received.map(\.lastPathComponent).sorted() == ["one.txt", "two.txt"])
    }

    @Test func aProviderStillWritingIsNotCalledStalled() async throws {
        let place = try Place()
        let source = FakePromise(names: ["a.bin"]) { folder, reader in
            let target = folder.appendingPathComponent("a.bin")
            // Its own thread: when every test runs at once the shared pool can start this too late.
            Thread.detachNewThread {
                FileManager.default.createFile(atPath: target.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: target) else { return }
                for _ in 0..<16 {
                    try? handle.write(contentsOf: Data(repeating: 1, count: 4096))
                    Thread.sleep(forTimeInterval: 0.1)
                }
                try? handle.close()
                reader(target, nil)
            }
        }
        let (_, outcome) = try await place.receive([source], stall: 1)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.received.count == 1)
    }

    @Test func aReportedSuccessWithNothingThereFails() async throws {
        let place = try Place()
        let source = FakePromise(names: ["a.txt"]) { folder, reader in reader(folder.appendingPathComponent("a.txt"), nil) }
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.received.isEmpty)
        #expect(reasons(outcome) == [.notDelivered])
    }

    @Test func aLocationOutsideItsFolderIsRefused() async throws {
        let place = try Place()
        let outside = place.root.appendingPathComponent("secret.txt")
        try Data("mine".utf8).write(to: outside)
        let source = FakePromise(names: ["secret.txt"]) { _, reader in reader(outside, nil) }
        let (reception, outcome) = try await place.receive([source])
        #expect(outcome.received.isEmpty)
        #expect(reasons(outcome) == [.unsafeDelivery])
        reception.discard()
        reception.flush()
        #expect(try String(contentsOf: outside, encoding: .utf8) == "mine")
    }

    @Test func hostilePathsNeverBecomeSources() async throws {
        let place = try Place()
        let planted = place.root.appendingPathComponent("planted.txt")
        try Data("planted".utf8).write(to: planted)
        let reports: [@Sendable (URL) -> URL] = [
            { $0.appendingPathComponent("../../../../planted.txt") },
            { $0.appendingPathComponent("..") },
            { $0.appendingPathComponent("sub/inner.txt") },
            { _ in URL(string: "https://example.com/a.txt")! },
        ]
        for make in reports {
            let source = FakePromise(names: ["x"]) { folder, reader in
                try? FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
                try? Data("x".utf8).write(to: folder.appendingPathComponent("sub/inner.txt"))
                reader(make(folder), nil)
            }
            let (_, outcome) = try await place.receive([source])
            #expect(outcome.received.isEmpty)
            #expect(reasons(outcome) == [.unsafeDelivery])
        }
        #expect(try String(contentsOf: planted, encoding: .utf8) == "planted")
        try place.expectExistingUntouched()
    }

    @Test func linksAndSpecialFilesAreRefused() async throws {
        let place = try Place()
        let outside = place.root.appendingPathComponent("target.txt")
        try Data("t".utf8).write(to: outside)
        let link = FakePromise(names: ["l"]) { folder, reader in
            let target = folder.appendingPathComponent("l")
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            reader(target, nil)
        }
        let fifo = FakePromise(names: ["f"]) { folder, reader in
            let target = folder.appendingPathComponent("f")
            mkfifo(target.path, 0o600)
            reader(target, nil)
        }
        let (_, outcome) = try await place.receive([link, fifo])
        #expect(outcome.received.isEmpty)
        #expect(reasons(outcome) == [.unsafeDelivery, .unsafeDelivery])
    }

    @Test func aPromisedFolderIsReceived() async throws {
        let place = try Place()
        let source = FakePromise(names: ["Album"]) { folder, reader in
            let album = folder.appendingPathComponent("Album")
            try? FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: album.appendingPathComponent("a.jpg"))
            reader(album, nil)
        }
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.received.map(\.lastPathComponent) == ["Album"])
    }

    @Test func extraReportsAreIgnored() async throws {
        let place = try Place()
        let source = FakePromise(names: ["a.txt"]) { folder, reader in
            let target = folder.appendingPathComponent("a.txt")
            try? Data("a".utf8).write(to: target)
            reader(target, nil)
            reader(target, FakeProviderError(text: "and again"))
            reader(folder.appendingPathComponent("other.txt"), nil)
        }
        let reception = try place.reception([source])
        let run = place.start(reception)
        let outcome = await run.outcome()
        reception.flush()
        #expect(outcome.received.count == 1 && outcome.failures.isEmpty)
        #expect(run.completions == 1)
    }

    @Test func theSameFileReportedTwiceIsReceivedOnce() async throws {
        let place = try Place()
        let source = FakePromise(names: ["a", "b"]) { folder, reader in
            let target = folder.appendingPathComponent("a")
            try? Data("a".utf8).write(to: target)
            reader(target, nil)
            reader(target, nil)
        }
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.received.map(\.lastPathComponent) == ["a"])
    }

    @Test func namesDeclaredOnlyOnceDeliveryStartsAreWaitedFor() async throws {
        let place = try Place()
        final class Reference: @unchecked Sendable { var promise: FakePromise? }
        let reference = Reference()
        let source = FakePromise(names: []) { folder, reader in
            reference.promise?.promisedNames = ["a", "b"]
            let first = folder.appendingPathComponent("a")
            let second = folder.appendingPathComponent("b")
            try? Data("a".utf8).write(to: first)
            try? Data("b".utf8).write(to: second)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reader(second, nil) }
            reader(first, nil)
        }
        reference.promise = source
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.received.map(\.lastPathComponent).sorted() == ["a", "b"])
    }

    @Test func everyFileOfAPromiseThatNeverNamesThemCounts() async throws {
        let place = try Place()
        let source = FakePromise(names: []) { folder, reader in
            for name in ["a", "b", "c"] {
                let target = folder.appendingPathComponent(name)
                try? Data(name.utf8).write(to: target)
                reader(target, nil)
            }
        }
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.received.map(\.lastPathComponent).sorted() == ["a", "b", "c"])
    }

    @Test func oneReportFinishesAPromiseWhoseNamesNeverAppear() async throws {
        let place = try Place()
        let source = FakePromise(names: []) { folder, reader in
            let target = folder.appendingPathComponent("named-by-provider.txt")
            try? Data("x".utf8).write(to: target)
            reader(target, nil)
        }
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.received.map(\.lastPathComponent) == ["named-by-provider.txt"])
    }

    @Test func cancelIgnoresWhatArrivesLaterAndCleansUp() async throws {
        let place = try Place()
        final class Later: @unchecked Sendable { var reader: (@Sendable (URL, Error?) -> Void)?; var folder: URL? }
        let later = Later()
        let source = FakePromise(names: ["report.txt"]) { folder, reader in
            let target = folder.appendingPathComponent("report.txt")
            try? Data("partial".utf8).write(to: target)
            later.reader = reader
            later.folder = folder
        }
        let reception = try place.reception([source])
        let run = place.start(reception)
        reception.cancel()
        let outcome = await run.outcome()
        #expect(outcome.wasCancelled && outcome.received.isEmpty && outcome.failures.isEmpty)

        reception.discard()
        reception.flush()
        #expect(!FileManager.default.fileExists(atPath: reception.stagingFolder.path))
        later.reader?(try #require(later.folder).appendingPathComponent("report.txt"), nil)
        reception.flush()
        #expect(run.completions == 1)
        try place.expectExistingUntouched()
    }

    @Test func someDeliveredAndSomeFailedAreBothReported() async throws {
        let place = try Place()
        let bad = FakePromise(names: ["bad.txt"]) { folder, reader in reader(folder.appendingPathComponent("bad.txt"), FakeProviderError(text: "No.")) }
        let (_, outcome) = try await place.receive([FakePromise.delivering("good.txt"), bad])
        #expect(outcome.received.map(\.lastPathComponent) == ["good.txt"])
        #expect(reasons(outcome) == [.providerError("No.")])
    }

    @Test func progressCountsItemsAndBytesWithoutTrustingANumberFromTheProvider() async throws {
        let place = try Place()
        let slow = FakePromise(names: ["b.bin"]) { folder, reader in
            let target = folder.appendingPathComponent("b.bin")
            try? Data(repeating: 1, count: 2048).write(to: target)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reader(target, nil) }
        }
        let reception = try place.reception([FakePromise.delivering("a.txt", "a"), slow])
        let run = place.start(reception)
        _ = await run.outcome()
        #expect(run.progress.first?.total == 2)
        #expect(run.progress.contains { $0.completed == 1 && abs($0.fraction - 0.5) < 0.001 })
        #expect(run.progress.contains { $0.bytes >= 2048 })
        #expect(run.progress.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }

    @Test func hostileNamesAndErrorsAreSafeToShow() async throws {
        let place = try Place()
        let spoofed = "invoice\u{202E}txt.exe"
        let source = FakePromise(names: [spoofed]) { folder, reader in
            reader(folder.appendingPathComponent("x"), FakeProviderError(text: "bad\nline\u{202E}"))
        }
        let (_, outcome) = try await place.receive([source])
        #expect(outcome.failures == [PromiseFailure(name: "x", reason: .providerError("badline"))])

        let shown = PromiseFailure.summary([PromiseFailure(name: "invoice\u{202E}", reason: .notDelivered)])
        #expect(shown != nil)
        let failed = try await place.receive([FakePromise(names: [spoofed]) { _, _ in }], stall: 0.1).1
        #expect(failed.failures.first?.name == "invoicetxt.exe")
    }

    @Test func sameNamedPromisesKeepApartAndGoThroughTheConflictRules() async throws {
        let place = try Place()
        let (reception, outcome) = try await place.receive([FakePromise.delivering("report.txt", "first"), FakePromise.delivering("report.txt", "second")])
        #expect(outcome.received.count == 2)
        #expect(Set(outcome.received).count == 2)
        let transfer = FileTransfer(kind: .copy, sources: outcome.received, destination: place.destination)
        let report = await transfer.run(resolveConflict: { _ in ConflictDecision(.keepBoth) })
        reception.discard()
        #expect(report.problems.isEmpty)
        #expect(place.destinationNames == ["report (2).txt", "report (3).txt", "report.txt"])
        #expect(try String(contentsOf: place.existing, encoding: .utf8) == "already here")
    }

    @Test func tooManyPromisesAreRefusedBeforeAnythingIsCreated() throws {
        let place = try Place()
        let many = (0...PromiseReception.maxPromises).map { _ in FakePromise.delivering("a") }
        #expect(throws: PromiseReceptionError.tooManyItems) { _ = try place.reception(many) }
        #expect(throws: PromiseReceptionError.nothingOffered) { _ = try place.reception([]) }
    }

    @Test func aSummaryNamesOneFailureAndCapsMany() throws {
        let one = try #require(PromiseFailure.summary([PromiseFailure(name: "a.pdf", reason: .providerUnavailable)]))
        #expect(one.title.contains("a.pdf"))
        #expect(one.detail == PromiseFailure(name: nil, reason: .providerUnavailable).explanation)
        let many = (0..<20).map { PromiseFailure(name: "f\($0)", reason: .notDelivered) }
        let capped = try #require(PromiseFailure.summary(many))
        #expect(capped.title.contains("20"))
        #expect(capped.detail.components(separatedBy: "\n").count == 9)
        #expect(PromiseFailure.summary([]) == nil)
    }
}
