import Foundation
import Testing
@testable import ArborCore

@Suite("Locations (spec §3.2, FE-002)")
struct LocationTests {
    let volumes: Set<String> = ["/", "/Volumes/USB"]
    func parent(_ l: Location) -> Location? { l.parent(isVolumeRoot: { volumes.contains($0.path) }) }

    @Test func folderParentIsParentFolder() {
        #expect(parent(.folder(URL(fileURLWithPath: "/Users/me/Documents"))) == .folder(URL(fileURLWithPath: "/Users/me")))
        #expect(parent(.folder(URL(fileURLWithPath: "/Volumes/USB/Photos"))) == .folder(URL(fileURLWithPath: "/Volumes/USB")))
    }

    @Test func volumeRootParentIsThisMac() {
        #expect(parent(.folder(URL(fileURLWithPath: "/"))) == .thisMac)
        #expect(parent(.folder(URL(fileURLWithPath: "/Volumes/USB"))) == .thisMac)
        #expect(parent(.folder(URL(fileURLWithPath: "/Volumes/USB/"))) == .thisMac)
    }

    @Test func topLevelPlacesHaveNoParent() {
        for l in [Location.home, .thisMac, .gallery, .network, .trash, .library("Libraries")] {
            #expect(parent(l) == nil)
        }
    }

    @Test func libraryParentIsLibrariesPage() {
        #expect(parent(.library("Documents")) == .library("Libraries"))
    }

    @Test func searchParentIsScope() {
        let scope = URL(fileURLWithPath: "/Users/me")
        #expect(parent(.search(SearchRequest(query: "x", scope: scope))) == .folder(scope))
        #expect(parent(.search(SearchRequest(query: "x"))) == nil)
    }

    @Test func archiveParents() {
        let zip = URL(fileURLWithPath: "/Users/me/a.zip")
        #expect(parent(.archive(zip, innerPath: "x/y")) == .archive(zip, innerPath: "x"))
        #expect(parent(.archive(zip, innerPath: "x")) == .archive(zip, innerPath: ""))
        #expect(parent(.archive(zip, innerPath: "")) == .folder(URL(fileURLWithPath: "/Users/me")))
    }

    @Test func trailingSlashIsTheSameFolder() {
        let a = Location.folder(URL(fileURLWithPath: "/tmp/a"))
        let b = Location.folder(URL(string: "file:///tmp/a/")!)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a.key == "folder:/tmp/a")
    }

    @Test func keysRoundTrip() {
        let all: [Location] = [
            .folder(URL(fileURLWithPath: "/Users/me/My Folder")), .folder(URL(fileURLWithPath: "/")),
            .home, .thisMac, .gallery, .network, .trash,
            .search(SearchRequest(query: "a&b=c + d ü", scope: URL(fileURLWithPath: "/Users/me"), recursive: false)),
            .search(SearchRequest(query: "report")),
            .archive(URL(fileURLWithPath: "/a b/c.zip"), innerPath: "x/ü"),
            .library("Documents"),
        ]
        for l in all {
            let back = Location(key: l.key)
            #expect(back == l, "round trip of \(l.key)")
        }
        if case .search(let r)? = Location(key: all[7].key) {
            #expect(r.query == "a&b=c + d ü")
            #expect(r.recursive == false)
        } else {
            Issue.record("search key did not parse")
        }
    }

    @Test func badKeysAreRejected() {
        #expect(Location(key: "") == nil)
        #expect(Location(key: "folder:relative") == nil)
        #expect(Location(key: "nonsense") == nil)
        #expect(Location(key: "archive?inner=x") == nil)
    }

    @Test func displayNames() {
        #expect(Location.home.displayName == "Home")
        #expect(Location.thisMac.displayName == "This Mac")
        #expect(Location.archive(URL(fileURLWithPath: "/a/c.zip"), innerPath: "").displayName == "c.zip")
        #expect(Location.archive(URL(fileURLWithPath: "/a/c.zip"), innerPath: "x/y").displayName == "y")
        #expect(Location.search(SearchRequest(query: "q")).displayName == "Search Results")
    }

    @Test func keywords() {
        #expect(Location.keyword(" This PC ") == .thisMac)
        #expect(Location.keyword("Recycle Bin") == .trash)
        #expect(Location.keyword("home") == .home)
        #expect(Location.keyword("/Users") == nil)
    }

    @Test func viewModesMatchExplorerShortcutOrder() {
        #expect(ViewMode.allCases.count == 8)
        #expect(ViewMode.extraLargeIcons.shortcutNumber == 1)
        #expect(ViewMode.details.shortcutNumber == 6)
        #expect(ViewMode.content.shortcutNumber == 8)
    }
}

@Suite("History over locations (FE-001)")
struct LocationHistoryTests {
    let docs = Location.folder(URL(fileURLWithPath: "/Users/me/Documents"))

    @Test func mixesVirtualAndFolderLocations() {
        var h = NavigationHistory(start: .home)
        h.visit(docs)
        h.visit(.thisMac)
        #expect(h.goBack()?.location == docs)
        #expect(h.goBack()?.location == .home)
        #expect(h.goForward()?.location == docs)
        #expect(h.current.url?.path == "/Users/me/Documents")
    }

    @Test func revisitingSameFolderWithSlashIsNotANewEntry() {
        var h = NavigationHistory(start: docs)
        h.visit(URL(string: "file:///Users/me/Documents/")!)
        #expect(!h.canGoBack)
    }

    @Test func virtualLocationsHaveNoURL() {
        let h = NavigationHistory(start: .thisMac)
        #expect(h.current.url == nil)
        #expect(h.current.location == .thisMac)
    }

    @Test func selectionRestoresOnVirtualLocations() {
        var h = NavigationHistory(start: .thisMac)
        h.saveState(selectedNames: ["Macintosh HD"], topVisibleName: nil)
        h.visit(docs)
        #expect(h.goBack()?.selectedNames == ["Macintosh HD"])
    }
}

@Suite("Explorer wording (FE-034, FE-085)")
struct ExplorerWordingTests {
    func file(_ name: String, _ size: Int64?) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isFolder: size == nil, size: size)
    }

    @Test func statusBar() {
        #expect(StatusText.explorerSummary(visible: 12, total: 12, query: "", selected: []) == "12 items  |")
        let one = StatusText.explorerSummary(visible: 12, total: 12, query: "", selected: [file("a", 4200)])
        #expect(one.hasPrefix("12 items  |  1 item selected  "))
        #expect(one.hasSuffix("  |"))
        #expect(StatusText.explorerSummary(visible: 2, total: 2, query: "", selected: [file("a", 1), file("f", nil)])
                == "2 items  |  2 items selected  |")
        #expect(StatusText.explorerSummary(visible: 1, total: 9, query: "re", selected: []) == "1 of 9 items match “re”  |")
    }

    @Test func copyAsPathQuotesEachPath() {
        #expect(CopyAsPath.text(for: ["/a b/c.txt"]) == "\"/a b/c.txt\"")
        #expect(CopyAsPath.text(for: ["/a", "/b"]) == "\"/a\"\n\"/b\"")
    }
}
