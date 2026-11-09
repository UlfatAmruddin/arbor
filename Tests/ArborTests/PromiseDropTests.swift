import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// The drop rules with a real AppKit promise on a private pasteboard (a real drag can't run in a test).
// One at a time: pasteboard names are reused once released, and the pasteboard server is slow on shared machines.
@Suite("File promise drops", .serialized)
struct PromiseDropTests {
    private final class Provider: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "../promised.txt" }
        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class Dragged {
        let pasteboard = NSPasteboard.withUniqueName()
        let delegate = Provider()
        let promise = NSFilePromiseProvider(fileType: "public.data", delegate: Provider())

        init() {
            promise.delegate = delegate
            pasteboard.clearContents()
            pasteboard.writeObjects([promise])
        }

        deinit { pasteboard.releaseGlobally() }

        func info(mask: NSDragOperation = [.copy, .move, .generic]) -> FakeDraggingInfo {
            FakeDraggingInfo(pasteboard: pasteboard, window: nil, mask: mask)
        }

        var receivers: [NSFilePromiseReceiver] {
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("arbor-tests-promisedrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aPromiseIsOfferedAsACopyAndAMoveOnlySourceIsRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dragged = Dragged()
        #expect(PromiseDrop.operation(dragged.info(), onto: folder) == .copy)
        #expect(PromiseDrop.operation(dragged.info(mask: .generic), onto: folder) == .generic)
        #expect(PromiseDrop.operation(dragged.info(mask: .move), onto: folder) == nil)
    }

    @Test func aPlainPasteboardIsNotAPromise() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        #expect(PromiseDrop.operation(FakeDraggingInfo(pasteboard: pasteboard, window: nil, mask: .every), onto: folder) == nil)
    }

    /// AppKit's receiver delivers only on the drag pasteboard, so here it never answers, which is what a provider that has gone away looks like.
    @MainActor @Test func aRealReceiverWithNoProviderIsReportedUnavailable() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dragged = Dragged()
        let receivers = dragged.receivers
        try #require(receivers.count == 1)
        let reception = try PromiseReception(sources: receivers, near: folder, stallLimit: 0.2, sampleInterval: 0.05)
        defer { reception.discard() }
        let outcome = await withCheckedContinuation { continuation in
            reception.start(progress: { _ in }, completion: { continuation.resume(returning: $0) })
        }
        #expect(outcome.received.isEmpty)
        #expect(outcome.failures.map(\.reason) == [.providerUnavailable])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
