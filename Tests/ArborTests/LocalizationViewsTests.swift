import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

@MainActor
@Suite("Views under long or right-to-left text (FE-204)")
struct LocalizationViewsTests {
    private func height(detail: String) -> CGFloat {
        _ = NSApplication.shared
        let button = CommandLinkButton(symbol: "plus.square.on.square", title: "Keep both", detail: detail)
        return button.constraints.first { $0.firstAttribute == .height }?.constant ?? 0
    }

    @Test func aCommandLinkGrowsForADetailThatWraps() {
        let short = height(detail: "Short")
        #expect(short == 52)
        #expect(height(detail: String(repeating: "A long translated sentence. ", count: 8)) > short + 10)
    }

    @Test func aSelectableLabelCopiesAPathWithoutItsMarks() throws {
        let path = "/Users/me/שלום/a.txt"
        let label = PlainCopyLabel(labelWithString: BidiText.path(path, rightToLeftInterface: true))
        let editor = try #require(label.cell?.fieldEditor(for: label))
        editor.string = label.stringValue
        editor.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(editor.writeSelection(to: pasteboard, types: [.rtf, .string]))
        #expect(pasteboard.string(forType: .string) == path)
        #expect(pasteboard.data(forType: .rtf) == nil)
    }
}
