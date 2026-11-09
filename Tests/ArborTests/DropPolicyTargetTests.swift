import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// The rules every folder drop target shares (FE-107), in the registration suite because they read `ItemHooks`.
extension FeatureRegistrationTests {
    /// Disposable folders: parent/child/grandchild and a file in parent, plus a private pasteboard.
    private final class DropFixture {
        let root: URL, parent: URL, child: URL, grandchild: URL, file: URL
        let pasteboard = NSPasteboard.withUniqueName()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("arbor-tests-drop-\(UUID().uuidString)")
            parent = root.appendingPathComponent("parent")
            child = parent.appendingPathComponent("child")
            grandchild = child.appendingPathComponent("grandchild")
            file = parent.appendingPathComponent("a.txt")
            try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: file)
        }

        deinit {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }

        func dragging(_ urls: [URL], mask: NSDragOperation = [.copy, .move, .generic]) -> FakeDraggingInfo {
            pasteboard.clearContents()
            if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
            return FakeDraggingInfo(pasteboard: pasteboard, window: nil, mask: mask)
        }
    }

    /// Records what `DropPolicy.accept` hands over.
    private func accept(_ info: NSDraggingInfo, onto folder: URL) -> (accepted: Bool, kind: TransferKind?, urls: [URL], folder: URL?) {
        var kind: TransferKind?, urls: [URL] = [], destination: URL?
        let accepted = DropPolicy.accept(info, onto: folder, window: nil) { kind = $0; urls = $1; destination = $2 }
        return (accepted, kind, urls, destination)
    }

    /// A drop handler that claims only drags carrying its own type and records where it was dropped.
    @MainActor private final class DropHandlerProbe {
        static let type = NSPasteboard.PasteboardType("test.arbor.drop-handler-probe")
        static let shared: DropHandlerProbe = {   // handlers can't be removed, so it registers once
            let probe = DropHandlerProbe()
            ItemHooks.registerDropHandler(ItemHooks.DropHandler(
                types: [type],
                operation: { info, _ in info.draggingPasteboard.availableType(from: [type]) == nil ? nil : .link },
                accept: { _, folder, _ in probe.accepted.append(folder); return true }))
            return probe
        }()
        var accepted: [URL] = []
    }

    /// A pasteboard item with the probe's type, and optionally a file URL beside it.
    private func draggingProbeType(on f: DropFixture, file: URL? = nil) -> FakeDraggingInfo {
        let item = NSPasteboardItem()
        item.setData(Data([1]), forType: DropHandlerProbe.type)
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        f.pasteboard.clearContents()
        f.pasteboard.writeObjects([item])
        return FakeDraggingInfo(pasteboard: f.pasteboard, window: nil, mask: [.copy, .move, .generic])
    }

    private func requireNoDragModifiers() throws {
        try #require(NSEvent.modifierFlags.isDisjoint(with: [.option, .command]), "release ⌥ and ⌘ while the tests run")
    }

    @Test func anEmptyDragIsRefusedByAFolderTarget() throws {
        #expect(Self.problem == nil)
        let f = try DropFixture()
        #expect(DropPolicy.operation(f.dragging([]), onto: f.child) == [])
        #expect(!accept(f.dragging([]), onto: f.child).accepted)
    }

    @Test func aDragWithoutFileURLsGoesToTheHandlerThatClaimsIt() throws {
        #expect(Self.problem == nil)
        let f = try DropFixture(), probe = DropHandlerProbe.shared
        probe.accepted.removeAll()
        #expect(DropPolicy.operation(draggingProbeType(on: f), onto: f.child) == .link)
        let result = accept(draggingProbeType(on: f), onto: f.child)
        #expect(result.accepted)
        #expect(probe.accepted == [f.child])
        #expect(result.kind == nil && result.folder == nil)
    }

    @Test func aDragWithFileURLsBypassesTheHandlers() throws {
        try requireNoDragModifiers()
        let f = try DropFixture(), probe = DropHandlerProbe.shared
        probe.accepted.removeAll()
        #expect(DropPolicy.operation(draggingProbeType(on: f, file: f.file), onto: f.child) == .move)
        let result = accept(draggingProbeType(on: f, file: f.file), onto: f.child)
        #expect(result.kind == .move)
        #expect(result.urls.map(\.path) == [f.file.path])
        #expect(probe.accepted.isEmpty)
    }

    @Test func itemsAlreadyInTheFolderAreRefused() throws {
        try requireNoDragModifiers()
        let f = try DropFixture()
        #expect(DropPolicy.operation(f.dragging([f.file]), onto: f.parent) == [])
        let result = accept(f.dragging([f.file]), onto: f.parent)
        #expect(!result.accepted && result.kind == nil)
    }

    @Test func aFolderCannotDropOntoItselfOrItsDescendant() throws {
        let f = try DropFixture()
        for destination in [f.child, f.grandchild] {
            #expect(DropPolicy.operation(f.dragging([f.child]), onto: destination) == [])
            #expect(!accept(f.dragging([f.child]), onto: destination).accepted)
        }
    }

    @Test func aSameVolumeDragMovesToTheFolderItWasDroppedOn() throws {
        try requireNoDragModifiers()
        let f = try DropFixture()
        #expect(DropPolicy.operation(f.dragging([f.file]), onto: f.child) == .move)
        let result = accept(f.dragging([f.file]), onto: f.child)
        #expect(result.accepted)
        #expect(result.kind == .move)
        #expect(result.urls.map(\.path) == [f.file.path])
        #expect(result.folder == f.child)
    }

    @Test func theSourceMaskLimitsTheOperation() throws {
        try requireNoDragModifiers()
        let f = try DropFixture()
        #expect(DropPolicy.operation(f.dragging([f.file], mask: .copy), onto: f.child) == .copy)
        #expect(accept(f.dragging([f.file], mask: .copy), onto: f.child).kind == .copy)
        #expect(DropPolicy.operation(f.dragging([f.file], mask: .link), onto: f.child) == [])
        #expect(!accept(f.dragging([f.file], mask: .link), onto: f.child).accepted)
    }
}
