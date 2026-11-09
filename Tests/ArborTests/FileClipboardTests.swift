import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// The clipboard on real AppKit pasteboards, each private to its test; real Finder is checked by hand (FE-101).
@Suite("Clipboard shared with other apps")
struct FileClipboardTests {
    private final class Board {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard: FileClipboard

        init() { clipboard = FileClipboard(pasteboard: pasteboard) }

        deinit { pasteboard.releaseGlobally() }

        /// What another app does when it copies files: nothing Arbor could recognise as its own.
        func copyFromAnotherApp(_ strings: [String], extra: [NSPasteboardItem] = []) {
            pasteboard.clearContents()
            pasteboard.writeObjects(strings.map { string in
                let item = NSPasteboardItem()
                item.setString(string, forType: .fileURL)
                return item
            } + extra)
        }
    }

    private let a = URL(fileURLWithPath: "/Users/me/Documents/a file.txt")
    private let b = URL(fileURLWithPath: "/Users/me/Documents/b.txt")

    @Test func aCopyOffersFileURLsTheOlderTypeAndPlainText() throws {
        let board = Board()
        board.clipboard.write([a, b], kind: .copy)
        let pasteboard = board.pasteboard

        let urls = try #require(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        #expect(urls == [a, b])
        #expect(pasteboard.propertyList(forType: ServicesSelection.legacyFilenames) as? [String] == [a.path, b.path])
        #expect(pasteboard.string(forType: .string) == "\(a.path)\n\(b.path)")
    }

    @Test func aCutLooksExactlyLikeACopyToOtherApps() throws {
        let cut = Board(), copy = Board()
        cut.clipboard.write([a, b], kind: .move)
        copy.clipboard.write([a, b], kind: .copy)

        let cutItems = try #require(cut.pasteboard.pasteboardItems)
        let copyItems = try #require(copy.pasteboard.pasteboardItems)
        #expect(cutItems.map { $0.types.map(\.rawValue) } == copyItems.map { $0.types.map(\.rawValue) })
        #expect(cut.pasteboard.types?.map(\.rawValue) == copy.pasteboard.types?.map(\.rawValue))
    }

    @Test func aCutStaysAMoveOnlyWhileArborsContentIsThere() {
        let board = Board()
        board.clipboard.write([a], kind: .move)
        #expect(board.clipboard.pasteKind(for: [a]) == .move)
        #expect(board.clipboard.isCut(a))

        board.copyFromAnotherApp([a.absoluteString])
        #expect(board.clipboard.pasteKind(for: [a]) == .copy)
        #expect(!board.clipboard.isCut(a))
    }

    @Test func filesFromAnotherAppPasteAsACopy() {
        let board = Board()
        board.copyFromAnotherApp([a.absoluteString, b.absoluteString])
        #expect(board.clipboard.canPaste)
        #expect(board.clipboard.contents() == .files([a, b]))
        #expect(board.clipboard.pasteKind(for: [a, b]) == .copy)
        #expect(board.clipboard.itemCount == 2)
    }

    @Test func anAppUsingTheOlderTypeIsReadToo() {
        let board = Board()
        board.pasteboard.declareTypes([ServicesSelection.legacyFilenames], owner: nil)
        board.pasteboard.setPropertyList([a.path, b.path], forType: ServicesSelection.legacyFilenames)
        #expect(board.clipboard.contents() == .files([a, b]))
    }

    @Test(arguments: ["https://example.com/a", "file://server/share/a", "file:relative/a", "file:///Users/me/a%00b",
                      "file:///Users/me/a?query=1", "file:///.file/id=1.2"])
    func anythingButALocalFileURLRefusesEverything(hostile: String) {
        let board = Board()
        board.copyFromAnotherApp([a.absoluteString, hostile])
        #expect(board.clipboard.contents() == .refused(.notLocalFiles))
        #expect(board.clipboard.readURLs().isEmpty)
    }

    @Test func aFileBesideSomethingElseIsNotPastedAlone() {
        let board = Board()
        let text = NSPasteboardItem()
        text.setString("just words", forType: .string)
        board.copyFromAnotherApp([a.absoluteString], extra: [text])
        #expect(board.clipboard.contents() == .refused(.notLocalFiles))
    }

    @Test func aDiskOnTheClipboardIsRefused() {
        let board = Board()
        board.copyFromAnotherApp(["file:///"])
        #expect(board.clipboard.contents() == .refused(.wholeDisk))
    }

    @Test func textAloneIsNothingToPaste() {
        let board = Board()
        board.clipboard.writePaths("\"/Users/me/a\"")
        #expect(!board.clipboard.canPaste)
        #expect(board.clipboard.contents() == .nothing)
    }

    @Test func aFinishedMoveOfArborsContentEmptiesTheClipboard() {
        let board = Board()
        board.clipboard.write([a], kind: .move)
        board.clipboard.finishedMove(changeCount: board.clipboard.changeCount)
        #expect(!board.clipboard.canPaste)
        #expect(board.clipboard.intent == nil)
        #expect(board.clipboard.itemCount == 0)
    }

    @Test func aFinishedMoveKeepsAnotherAppsContentButStopsOfferingIt() {
        let board = Board()
        board.copyFromAnotherApp([a.absoluteString])
        board.clipboard.finishedMove(changeCount: board.clipboard.changeCount)
        #expect(!board.clipboard.canPaste)
        #expect(board.clipboard.contents() == .nothing)
        #expect(board.clipboard.itemCount == 1)

        board.copyFromAnotherApp([b.absoluteString])
        #expect(board.clipboard.canPaste)
        #expect(board.clipboard.contents() == .files([b]))
    }

    @Test func somethingCutDuringTheMoveIsLeftAlone() {
        let board = Board()
        board.clipboard.write([a], kind: .move)
        let pasted = board.clipboard.changeCount
        board.clipboard.write([b], kind: .move)
        board.clipboard.finishedMove(changeCount: pasted)
        #expect(board.clipboard.canPaste)
        #expect(board.clipboard.isCut(b))
        #expect(board.clipboard.pasteKind(for: [b]) == .move)
    }
}
