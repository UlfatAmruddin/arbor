import Foundation
import Testing
@testable import ArborCore

@Suite("Explorer wording: sizes and types")
struct ExplorerFormatTests {
    @Test func detailsSizeIsAlwaysWholeKilobytesRoundedUp() {
        #expect(ExplorerSize.detailsColumn(0) == "0 KB")
        #expect(ExplorerSize.detailsColumn(1) == "1 KB")
        #expect(ExplorerSize.detailsColumn(1023) == "1 KB")
        #expect(ExplorerSize.detailsColumn(1024) == "1 KB")
        #expect(ExplorerSize.detailsColumn(1025) == "2 KB")
        #expect(ExplorerSize.detailsColumn(12_345 * 1024) == "12,345 KB")
        #expect(ExplorerSize.detailsColumn(4_628_594_688) == "4,520,112 KB")
        #expect(ExplorerSize.kilobytes(-5) == 0)
    }

    @Test func detailsColumnsUseKilobytesAndOtherPlacesAdaptiveUnits() {
        #expect(ColumnValues.text(.bytes(2_400)) == "3 KB")
        #expect(StatusText.bytes(2_400) == "2.34 KB")
        #expect(StatusText.bytes(512) == "512 bytes")
        #expect(StatusText.bytes(14_900_000) == "14.2 MB")
        let one = StatusText.explorerSummary(visible: 3, total: 3, query: "",
                                             selected: [FileItem(url: URL(fileURLWithPath: "/tmp/a"), name: "a", isFolder: false, size: 2_400)])
        #expect(one == "3 items  |  1 item selected  2.34 KB  |")
    }

    @Test func folderRowsHaveNoSizeInDetails() {
        let folder = FileItem(url: URL(fileURLWithPath: "/tmp/f"), name: "f", isFolder: true)
        #expect(ColumnValues.text(ColumnValues.value(folder, .size, lookup: nil), column: .size) == "")
    }

    @Test func typeNamesUseExplorerWordsOnlyWhereMacOSDiffers() {
        #expect(ExplorerTypeName.name(localized: "Alias", typeIdentifier: "com.apple.alias-file", isFolder: false) == "Shortcut")
        #expect(ExplorerTypeName.name(localized: "Alias", typeIdentifier: nil, isFolder: false) == "Shortcut")
        #expect(ExplorerTypeName.name(localized: "Plain Text Document", typeIdentifier: "public.plain-text", isFolder: false)
                == "Plain Text Document")
        #expect(ExplorerTypeName.name(localized: nil, typeIdentifier: nil, isFolder: true) == "Folder")
        #expect(ExplorerTypeName.name(localized: "Alias", typeIdentifier: "public.symlink", isFolder: false,
                                      isSymbolicLink: true, targetDescription: "PNG image") == "PNG image")
        #expect(ExplorerTypeName.name(localized: "Alias", typeIdentifier: "public.symlink", isFolder: false,
                                      isSymbolicLink: true, targetDescription: nil) == "Symbolic link")
    }

    @Test func inWindowMenusUseSentenceCase() {
        #expect(ExplorerMenuWording.inWindowTitle("Open in New Tab") == "Open in new tab")
        #expect(ExplorerMenuWording.inWindowTitle("Copy as Path") == "Copy as path")
        #expect(ExplorerMenuWording.inWindowTitle("Group By") == "Group by")
        #expect(ExplorerMenuWording.inWindowTitle("Close Tabs to the Right") == "Close tabs to the right")
        // Proper names and already-correct titles are untouched.
        #expect(ExplorerMenuWording.inWindowTitle("Pin to Quick access") == "Pin to Quick access")
        #expect(ExplorerMenuWording.inWindowTitle("Show in Finder") == "Show in Finder")
        #expect(ExplorerMenuWording.inWindowTitle("Extract All…") == "Extract All…")
        // Every mapped title differs from its source only in letter case (and a dropped ellipsis).
        for (from, to) in ExplorerMenuWording.inWindow {
            #expect(from.replacingOccurrences(of: "…", with: "").lowercased().hasPrefix(to.replacingOccurrences(of: "…", with: "").lowercased())
                    || to == "Disconnect network drive")
        }
    }

    @Test func recentLocationsAreMostRecentFirstWithoutDuplicates() {
        var recent = RecentLocations(limit: 3)
        let a = Location.folder(URL(fileURLWithPath: "/tmp/a")), b = Location.folder(URL(fileURLWithPath: "/tmp/b"))
        recent.record(a)
        recent.record(.home)
        recent.record(b)
        recent.record(a)
        #expect(recent.entries == [a, b, .home])
        recent.record(.search(SearchRequest(query: "x", scope: URL(fileURLWithPath: "/tmp"))))
        #expect(recent.entries == [a, b, .home])
        recent.record(.thisMac)
        #expect(recent.entries == [.thisMac, a, b])
        recent.clear()
        #expect(recent.entries.isEmpty)
    }

    @Test func listingTypesAliasesAsShortcutsAndLinksByTarget() throws {
        let fx = try Fixture()
        let target = try fx.file("notes.txt", "hello")
        try fx.folder("Projects")
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: fx.url("notes.txt - Shortcut"))
        try FileManager.default.createSymbolicLink(at: fx.url("link.txt"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: fx.url("Projects link"), withDestinationURL: fx.url("Projects"))
        let plain = try #require(FileItem(url: target)).typeDescription
        #expect(FileItem(url: fx.url("notes.txt - Shortcut"))?.typeDescription == "Shortcut")
        #expect(FileItem(url: fx.url("link.txt"))?.typeDescription == plain)
        #expect(FileItem(url: fx.url("Projects link"))?.typeDescription == FileItem(url: fx.url("Projects"))?.typeDescription)
        #expect(plain != "Shortcut")
    }
}
