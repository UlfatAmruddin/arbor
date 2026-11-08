import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// Browse notes and extraction alerts name the real reason items are hidden or left out.
@Suite struct ArchiveNotesTests {
    @Test func notesNameTheReasonItemsAreHidden() {
        let deep = Array(repeating: "a", count: 512).joined(separator: "/") + "/f"
        let unreadable = ArchiveIndex(entries: [ArchiveEntry(rawPath: "", kind: .special), ArchiveEntry(rawPath: "", kind: .special)])
        #expect(ArchiveProvider.hiddenItemsNote(unreadable) == nil)
        #expect(ArchiveProvider.unreadableItemsNote(unreadable)?.contains("couldn't be read") == true)

        let long = ArchiveIndex(entries: [ArchiveEntry(rawPath: deep, kind: .file)])
        #expect(ArchiveProvider.hiddenItemsNote(long)?.contains("too long") == true)
        #expect(ArchiveProvider.unreadableItemsNote(long) == nil)

        let outside = ArchiveIndex(entries: [ArchiveEntry(rawPath: "../x", kind: .file), ArchiveEntry(rawPath: deep, kind: .file)])
        #expect(ArchiveProvider.hiddenItemsNote(outside)?.contains("points outside it") == true)
        #expect(ArchiveProvider.hiddenItemsNote(ArchiveIndex(entries: [ArchiveEntry(rawPath: "ok", kind: .file)])) == nil)
    }

    @Test func rejectionReasonsAreInTheStringTable() throws {
        let table = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/en.lproj/Localizable.strings")
        let keys = try #require(NSDictionary(contentsOf: table) as? [String: String]).keys
        let texts = ExtractionPlanner.Rejection.allCases.map(\.text)
        #expect(Set(texts).count == texts.count, "each reason reads differently")
        for text in texts + [ExtractionPlanner.unreadableName, "Nothing could be extracted safely.", "…and %d more."] {
            #expect(keys.contains(text), "\(text) is missing from Localizable.strings")
        }
    }

    @Test func rejectionTextShowsEachReason() {
        let rejected = [(ArchiveEntry(rawPath: "", kind: .special), ExtractionPlanner.Rejection.unreadable),
                        (ArchiveEntry(rawPath: "odd", kind: .unknown), .unknownType)]
            + (0..<8).map { (ArchiveEntry(rawPath: "l\($0)", kind: .symlink), ExtractionPlanner.Rejection.linkOutside) }
        let text = ArchiveJobs.rejectionText(rejected, header: "Header")
        #expect(text.contains("• \(ExtractionPlanner.unreadableName): \(ExtractionPlanner.Rejection.unreadable.text)"))
        #expect(text.contains("• odd: Arbor doesn't know what kind of item it is."))
        #expect(text.hasSuffix("\n…and 2 more."))
    }
}
