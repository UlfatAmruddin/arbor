import CoreGraphics
import Foundation
import Testing
@testable import ArborCore

private func file(_ name: String, folder: Bool = false, hidden: Bool = false, in parent: String = "/tmp/fx") -> FileItem {
    FileItem(url: URL(fileURLWithPath: parent).appendingPathComponent(name), name: name, isFolder: folder, isHidden: hidden)
}

@Suite("Folder Options catalog and draft (FE-042, FE-043, FE-248)")
struct FolderOptionsCatalogTests {
    @Test func advancedSettingsFollowWindowsOrder() {
        let titles = FolderOptionsCatalog.advanced.map(\.title)
        let expected = [
            "Files and Folders", "Always show icons, never thumbnails", "Always show menus",
            "Decrease space between items (compact view)", "Display file icon on thumbnails",
            "Display file size information in folder tips", "Display the full path in the title bar",
            "Hidden files and folders", "Hide empty drives", "Hide extensions for known file types",
            "Hide folder merge conflicts", "Hide protected operating system files (Recommended)",
            "Launch folder windows in a separate process", "Restore previous folder windows at launch",
            "Show drive letters", "Show encrypted or compressed NTFS files in color",
            "Show pop-up description for folder and desktop items", "Show preview handlers in preview pane",
            "Show status bar", "Show sync provider notifications", "Use check boxes to select items",
            "Use Sharing Wizard (Recommended)", "When typing into list view",
            "Navigation pane", "Always show availability status", "Expand to open folder", "Show all folders", "Show libraries",
        ]
        #expect(titles == expected)
    }

    @Test func macOnlyBoundariesAreDisabledWithAReason() {
        for key in ["alwaysShowMenus", "separateProcess", "showDriveLetters", "showCompressedInColor", "sharingWizard",
                    "folderTipSizes", "accountInsights"] {
            let item = FolderOptionsCatalog.item(key)
            #expect(item?.isAvailable == false, "\(key)")
            #expect((item?.unavailableReason ?? "").count > 10)
            #expect(item?.defaultValue == nil)
        }
    }

    @Test func keysAreUnique() {
        let keys = FolderOptionsCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func searchAndGeneralTabs() {
        #expect(FolderOptionsCatalog.search.map(\.key) == ["searchWithoutIndex", "searchIncludeSystemDirectories",
                                                           "searchIncludeCompressedFiles", "searchFileContents"])
        #expect(FolderOptionsCatalog.defaults(for: .search)["searchIncludeSystemDirectories"] == .bool(true))
        #expect(FolderOptionsCatalog.defaults(for: .general)["openTo"] == .string("home"))
        #expect(FolderOptionsCatalog.defaults(for: .general)["clickItems"] == .string("double"))
        #expect(FolderOptionsCatalog.defaults(for: .view)["hiddenFiles"] == .string("hide"))
        #expect(FolderOptionsCatalog.defaults(for: .view)["typingMode"] == .string("select"))
    }

    @Test func draftApplyAndCancelSemantics() {
        var draft = FolderOptionsDraft(current: FolderOptionsCatalog.allDefaults)
        #expect(!draft.isDirty)
        draft.set("showStatusBar", .bool(false))
        draft.set("clickItems", .string("single"))
        #expect(draft.changedKeys == ["clickItems", "showStatusBar"])
        let changes = draft.commit()      // Apply
        #expect(changes == ["showStatusBar": .bool(false), "clickItems": .string("single")])
        #expect(!draft.isDirty)
        draft.set("showStatusBar", .bool(true))
        #expect(draft.isDirty)            // Cancel would drop this; committed still has false
        #expect(draft.committed["showStatusBar"] == .bool(false))
    }

    @Test func restoreDefaultsOnlyTouchesItsPage() {
        var current = FolderOptionsCatalog.allDefaults
        current["showStatusBar"] = .bool(false)
        current["openTo"] = .string("thismac")
        current["searchFileContents"] = .bool(true)
        var draft = FolderOptionsDraft(current: current)
        draft.restoreDefaults(.view)
        #expect(draft["showStatusBar"] == .bool(true))
        #expect(draft["openTo"] == .string("thismac"))
        #expect(draft["searchFileContents"] == .bool(true))
        #expect(draft.changedKeys == ["showStatusBar"])
    }

    @Test func dependentRadiosAndDisabledKeys() {
        var draft = FolderOptionsDraft(current: FolderOptionsCatalog.allDefaults, disabledKeys: ["showLibraries"])
        let underline = FolderOptionsCatalog.item("underlineTitles")!.choices[0]
        #expect(!draft.isEnabled(underline))
        draft.set("clickItems", .string("single"))
        #expect(draft.isEnabled(underline))
        draft.set("showLibraries", .bool(true))
        #expect(draft["showLibraries"] == .bool(false))
    }

    @Test func refreshKeepsUserEdits() {
        var draft = FolderOptionsDraft(current: FolderOptionsCatalog.allDefaults)
        draft.set("showStatusBar", .bool(false))
        var outside = FolderOptionsCatalog.allDefaults
        outside["compactView"] = .bool(true)        // toggled from View ▾ while the dialog is open
        draft.refresh(from: outside)
        #expect(draft["compactView"] == .bool(true))
        #expect(draft["showStatusBar"] == .bool(false))
        #expect(draft.changedKeys == ["showStatusBar"])
    }

    @Test func parsesScriptValues() {
        #expect(OptionValue(parsing: "1") == .bool(true))
        #expect(OptionValue(parsing: "off") == .bool(false))
        #expect(OptionValue(parsing: "thismac") == .string("thismac"))
    }
}

@Suite("Per-folder view precedence (FE-041, FE-052)")
struct ViewPrecedenceTests {
    @Test func appDefaultWhenNothingSaved() {
        let r = ViewSettingsResolver.resolve(template: .generalItems, applied: nil, override: nil)
        #expect(r.source == .appDefault)
        #expect(r.settings.viewMode == "details")
        #expect(r.settings.sortKey == "name")
        #expect(r.settings.groupBy == nil)        // the folder kind's column set decides
        #expect(r.settings.columns == nil)
    }

    @Test func builtInTemplateBeatsAppDefault() {
        let r = ViewSettingsResolver.resolve(template: .pictures, applied: nil, override: nil)
        #expect(r.source == .template(.pictures, applied: false))
        #expect(r.settings.viewMode == "largeIcons")
        #expect(r.settings.sortKey == "name")
    }

    @Test func appliedTemplateBeatsBuiltIn() {
        let applied = FolderViewSettings(viewMode: "list", sortKey: "dateModified", ascending: false)
        let r = ViewSettingsResolver.resolve(template: .pictures, applied: applied, override: nil)
        #expect(r.source == .template(.pictures, applied: true))
        #expect(r.settings.viewMode == "list")
        #expect(r.settings.ascending == false)
        #expect(r.settings.foldersFirst == true)   // inherited from the app default
    }

    @Test func folderOverrideWinsFieldByField() {
        let applied = FolderViewSettings(viewMode: "list", sortKey: "size")
        let override = FolderViewSettings(sortKey: "type", groupBy: "type")
        let r = ViewSettingsResolver.resolve(template: .music, applied: applied, override: override)
        #expect(r.source == .folder)
        #expect(r.settings.viewMode == "list")
        #expect(r.settings.sortKey == "type")
        #expect(r.settings.groupBy == "type")
    }

    @Test func sortByAnyColumn() {
        var s = FolderViewSettings()
        var order = FileSortOrder()
        order.setPrimary(.dimensions, ascending: false, keepPrevious: false)
        s.setSort(order)
        #expect(s.sortKey == "dimensions")
        #expect(s.sortOrder.primaryColumn == .dimensions)
        #expect(s.sortOrder.ascending == false)
        #expect(FolderViewSettings(sortKey: "size").sortOrder.key == .size)
        #expect(FolderViewSettings().sortOrder == FileSortOrder())
    }

    @Test func emptyLayersAreIgnored() {
        let r = ViewSettingsResolver.resolve(template: .documents, applied: FolderViewSettings(), override: FolderViewSettings())
        #expect(r.source == .template(.documents, applied: false))
        #expect(ViewSettingsResolver.resolve(template: .generalItems, applied: FolderViewSettings(), override: FolderViewSettings()).source == .appDefault)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let s = FolderViewSettings(viewMode: "details", sortKey: "size", ascending: false, foldersFirst: false, groupBy: "type",
                                   groupAscending: false, columns: [ColumnSpec(.name, width: 300), ColumnSpec(.dimensions, width: 80)])
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(FolderViewSettings.self, from: data) == s)
    }
}

@Suite("Folder type discovery (FE-040)")
struct TemplateDetectionTests {
    let known = FolderTemplateDetector.KnownFolders(documents: [URL(fileURLWithPath: "/Users/ana/Documents")],
                                                    pictures: [URL(fileURLWithPath: "/Users/ana/Pictures")],
                                                    music: [URL(fileURLWithPath: "/Users/ana/Music")],
                                                    videos: [URL(fileURLWithPath: "/Users/ana/Movies")])

    @Test func knownFoldersByLocation() {
        #expect(FolderTemplateDetector.detect(folder: URL(fileURLWithPath: "/Users/ana/Pictures/"), items: [], known: known) == .pictures)
        #expect(FolderTemplateDetector.detect(folder: URL(fileURLWithPath: "/Users/ana/Movies"), items: [file("a.txt")], known: known) == .videos)
        #expect(FolderTemplateDetector.detect(folder: URL(fileURLWithPath: "/Users/ana/Documents"), items: [file("a.jpg")], known: known) == .documents)
    }

    @Test func contentMajority() {
        let photos = [file("1.JPG"), file("2.heic"), file("3.png"), file("notes.txt"), file("Sub", folder: true)]
        #expect(FolderTemplateDetector.detect(folder: URL(fileURLWithPath: "/x/Trip"), items: photos, known: known) == .pictures)
        let songs = [file("a.mp3"), file("b.flac"), file("cover.jpg")]
        #expect(FolderTemplateDetector.detect(items: songs) == .music)
        let docs = [file("a.pdf"), file("b.docx"), file("c.zip")]
        #expect(FolderTemplateDetector.detect(items: docs) == .documents)
        #expect(FolderTemplateDetector.detect(items: [file("a.mov"), file("b.mp4"), file("c.txt"), file("d.zip")]) == .videos)
    }

    @Test func mixedOrEmptyIsGeneral() {
        #expect(FolderTemplateDetector.detect(items: []) == .generalItems)
        #expect(FolderTemplateDetector.detect(items: [file("A", folder: true), file("B", folder: true)]) == .generalItems)
        #expect(FolderTemplateDetector.detect(items: [file("a.jpg"), file("b.zip"), file("c.swift")]) == .generalItems)
    }

    @Test func insideAKnownFolderInheritsItsType() {
        let sub = URL(fileURLWithPath: "/Users/ana/Pictures/2026/Trip")
        #expect(FolderTemplateDetector.detect(folder: sub, items: [file("a.txt")], known: known) == .pictures)
        #expect(FolderTemplateDetector.detect(folder: URL(fileURLWithPath: "/Users/ana/PicturesOld"), items: [], known: known) == .generalItems)
    }

    @Test func propertiesChoiceWinsThenDownloads() {
        var k = known
        k.downloads = [URL(fileURLWithPath: "/Users/ana/Downloads")]
        let chosen = FolderTemplateDetector.resolve(folder: URL(fileURLWithPath: "/Users/ana/Pictures"), items: [],
                                                    chosen: .music, known: k)
        #expect(chosen == .init(template: .music, kind: .music, chosen: true))
        let downloads = FolderTemplateDetector.resolve(folder: URL(fileURLWithPath: "/Users/ana/Downloads"), items: [file("a.jpg")],
                                                       chosen: nil, known: k)
        #expect(downloads == .init(template: .generalItems, kind: .downloads, chosen: false))
        let inside = FolderTemplateDetector.resolve(folder: URL(fileURLWithPath: "/Users/ana/Downloads/x"), items: [file("a.jpg")],
                                                    chosen: nil, known: k)
        #expect(inside == .init(template: .pictures, kind: .pictures, chosen: false))
    }

    @Test func templateCodesAsItsPropertiesName() throws {
        let data = try JSONEncoder().encode([FolderTemplate.generalItems])
        #expect(String(decoding: data, as: UTF8.self) == "[\"generalItems\"]")
        #expect(FolderTemplate.videos.folderKind == .videos)
    }

    @Test func hiddenFilesDontCount() {
        let items = [file("a.jpg"), file(".DS_Store", hidden: true), file(".x.zip", hidden: true)]
        #expect(FolderTemplateDetector.detect(items: items) == .pictures)
    }

    @Test func tieGoesToPictures() {
        #expect(FolderTemplateDetector.detect(items: [file("a.jpg"), file("b.mp3")]) == .pictures)
    }
}

@Suite("Folder identity and view database (FE-041, FE-248)")
struct FolderViewStoreTests {
    @Test func identitySurvivesRename() throws {
        let fx = try Fixture()
        let a = try fx.folder("Photos")
        let before = FolderIdentity.of(a)
        let renamed = fx.url("Holiday")
        try FileManager.default.moveItem(at: a, to: renamed)
        let after = FolderIdentity.of(renamed)
        #expect(before.path != after.path)
        if before.id != nil { #expect(before.id == after.id) }
        #expect(before.path.hasSuffix("/Photos"))
    }

    @Test func missingFolderFallsBackToPath() {
        let id = FolderIdentity.of(URL(fileURLWithPath: "/nonexistent-arbor-\(UUID().uuidString)/"))
        #expect(id.id == nil)
        #expect(!id.path.hasSuffix("/"))
    }

    @Test func lookupByIdentityThenPath() {
        let store = FolderViewStore(fileURL: nil)
        let s = FolderViewSettings(viewMode: "list")
        store.setOverride(s, for: FolderIdentity(id: "vol:A:ino:1", path: "/a"))
        // Renamed: same id, new path → found, path updated.
        #expect(store.override(for: FolderIdentity(id: "vol:A:ino:1", path: "/b")) == s)
        #expect(store.entries.first?.path == "/b")
        // Replaced: same path, different id → not the same folder.
        #expect(store.override(for: FolderIdentity(id: "vol:A:ino:2", path: "/b")) == nil)
        // Path-only identity (volume without UUID) matches the path.
        #expect(store.override(for: FolderIdentity(id: nil, path: "/b")) == s)
    }

    @Test func pathEntryUpgradesToIdentity() {
        let store = FolderViewStore(fileURL: nil)
        store.setOverride(FolderViewSettings(sortKey: "size"), for: FolderIdentity(id: nil, path: "/n"))
        #expect(store.override(for: FolderIdentity(id: "vol:B:ino:9", path: "/n"))?.sortKey == "size")
        #expect(store.entries.first?.id == "vol:B:ino:9")
    }

    @Test func emptySettingsRemoveTheEntry() {
        let store = FolderViewStore(fileURL: nil)
        let id = FolderIdentity(id: "x", path: "/x")
        store.setOverride(FolderViewSettings(viewMode: "list"), for: id)
        store.setOverride(nil, for: id)
        #expect(store.count == 0)
    }

    @Test func boundedAndPrunesLeastRecentlyUsed() {
        var clock = Date(timeIntervalSince1970: 0)
        let store = FolderViewStore(fileURL: nil, limit: 10, now: { clock })
        for i in 0..<11 {
            clock = clock.addingTimeInterval(60)
            store.setOverride(FolderViewSettings(viewMode: "list"), for: FolderIdentity(id: "id\(i)", path: "/f\(i)"))
        }
        #expect(store.count == 9)
        #expect(store.override(for: FolderIdentity(id: "id0", path: "/f0")) == nil)
        #expect(store.override(for: FolderIdentity(id: "id10", path: "/f10")) != nil)
    }

    @Test func applyToFoldersAndReset() {
        let store = FolderViewStore(fileURL: nil)
        store.setOverride(FolderViewSettings(viewMode: "list"), for: FolderIdentity(id: "p", path: "/p"), template: .pictures)
        store.setOverride(FolderViewSettings(viewMode: "list"), for: FolderIdentity(id: "m", path: "/m"), template: .music)
        store.applyToFolders(FolderViewSettings(viewMode: "tiles"), template: .pictures)
        #expect(store.templateDefault(.pictures)?.viewMode == "tiles")
        #expect(store.override(for: FolderIdentity(id: "p", path: "/p")) == nil)
        #expect(store.override(for: FolderIdentity(id: "m", path: "/m")) != nil)
        store.resetAll()
        #expect(store.count == 0)
        #expect(store.appliedTemplates.isEmpty)
    }

    @Test func persistsToItsFileOnly() throws {
        let fx = try Fixture()
        let db = fx.url("state/FolderViews.json")
        let watched = try fx.folder("Watched")
        let store = FolderViewStore(fileURL: db)
        store.setOverride(FolderViewSettings(viewMode: "list", columns: [ColumnSpec(.name), ColumnSpec(.size, width: 70)]),
                          for: FolderIdentity.of(watched), template: .generalItems)
        store.setTemplateDefault(FolderViewSettings(sortKey: "size"), for: .music)
        try store.save()
        let reopened = FolderViewStore(fileURL: db)
        #expect(reopened.override(for: FolderIdentity.of(watched))?.columns?.last?.width == 70)
        #expect(reopened.templateDefault(.music)?.sortKey == "size")
        #expect(fx.names("Watched").isEmpty)        // never writes .DS_Store or anything into the folder
    }

    @Test func corruptFileStartsEmpty() throws {
        let fx = try Fixture()
        let db = try fx.file("FolderViews.json", "{not json")
        #expect(FolderViewStore(fileURL: db).count == 0)
    }

    @Test func takeChangesOnlyWhenDirty() {
        let store = FolderViewStore(fileURL: nil)
        #expect(store.takeChanges() == nil)
        store.setOverride(FolderViewSettings(viewMode: "list"), for: FolderIdentity(id: "a", path: "/a"))
        #expect(store.takeChanges() != nil)
        #expect(store.takeChanges() == nil)
    }
}

@Suite("Session restore and window placement (FE-024, FE-026, FE-251)")
struct SessionTests {
    @Test func historyRoundTrip() {
        var h = NavigationHistory(start: .home)
        h.visit(.folder(URL(fileURLWithPath: "/a")))
        h.visit(.folder(URL(fileURLWithPath: "/b")))
        h.visit(.folder(URL(fileURLWithPath: "/c")))
        h.goBack()
        let tab = SessionTab(history: h, viewMode: "list", sort: FileSortOrder(key: .size, ascending: false))
        #expect(tab.location == "folder:/b")
        #expect(tab.back == ["home", "folder:/a"])
        #expect(tab.forward == ["folder:/c"])
        let rebuilt = tab.history()!
        #expect(rebuilt.current.location == .folder(URL(fileURLWithPath: "/b")))
        #expect(rebuilt.backStack.map(\.location.key) == ["home", "folder:/a"])
        #expect(rebuilt.forwardStack.map(\.location.key) == ["folder:/c"])
        #expect(tab.sortOrder == FileSortOrder(key: .size, ascending: false))
    }

    @Test func historyIsBounded() {
        var h = NavigationHistory(start: .home)
        for i in 0..<60 { h.visit(.folder(URL(fileURLWithPath: "/f\(i)"))) }
        let tab = SessionTab(history: h, viewMode: "details", sort: FileSortOrder())
        #expect(tab.back.count == SessionState.historyLimit)
        #expect(tab.back.last == "folder:/f58")
    }

    @Test func unreadableKeysAreDropped() {
        let tab = SessionTab(location: "folder:/x", back: ["bogus", "home"], forward: ["folder:relative"])
        let h = tab.history()!
        #expect(h.backStack.map(\.location.key) == ["home"])
        #expect(!h.canGoForward)
        #expect(SessionTab(location: "nope").history() == nil)
    }

    @Test func stateEncodesAndBounds() throws {
        let tabs = (0..<50).map { SessionTab(location: "folder:/t\($0)") }
        let state = SessionState(windows: [SessionWindow(frame: CGRect(x: 10, y: 20, width: 900, height: 600), tabs: tabs, activeTab: 99),
                                           SessionWindow(frame: .zero, tabs: [], activeTab: 0)])
        #expect(state.windows.count == 1)
        #expect(state.windows[0].tabs.count == SessionState.tabLimit)
        #expect(state.windows[0].activeTab == SessionState.tabLimit - 1)
        let decoded = SessionState.decode(state.encoded()!)
        #expect(decoded == state)
        #expect(decoded?.windows[0].rect == CGRect(x: 10, y: 20, width: 900, height: 600))
        #expect(SessionState.decode(Data("garbage".utf8)) == nil)
    }

    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let side = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

    @Test func onScreenFrameIsKept() {
        let f = CGRect(x: 100, y: 100, width: 1000, height: 700)
        #expect(WindowPlacement.recover(f, screens: [main]) == f)
        let onSide = CGRect(x: 1600, y: 200, width: 1200, height: 700)
        #expect(WindowPlacement.recover(onSide, screens: [main, side]) == onSide)
    }

    @Test func frameFromRemovedDisplayMovesToARemainingOne() {
        let onSide = CGRect(x: 1600, y: 200, width: 1200, height: 700)
        let r = WindowPlacement.recover(onSide, screens: [main])
        #expect(main.contains(r))
        #expect(r.size == onSide.size)
    }

    @Test func oversizedFrameShrinks() {
        let big = CGRect(x: 1600, y: 0, width: 1900, height: 1050)
        let r = WindowPlacement.recover(big, screens: [main])
        #expect(main.contains(r))
        #expect(r.width == main.width && r.height == main.height)
    }

    @Test func titleBarAboveTheScreenIsRecovered() {
        let f = CGRect(x: 100, y: 900, width: 800, height: 600)    // top edge at 1500, screen top 875
        #expect(!WindowPlacement.isReachable(f, screens: [main]))
        #expect(main.contains(WindowPlacement.recover(f, screens: [main])))
    }

    @Test func draggedPartlyOffEdgeIsKept() {
        let f = CGRect(x: 1100, y: 100, width: 800, height: 600)   // right part past the edge, title reachable
        #expect(WindowPlacement.recover(f, screens: [main]) == f)
    }
}

@Suite("Protected system items and sync providers (FE-043, FE-045)")
struct SystemItemTests {
    @Test func protectedNames() {
        #expect(ProtectedSystemItems.isProtected(name: ".DS_Store", parentPath: "/Users/ana", isHidden: true))
        #expect(ProtectedSystemItems.isProtected(name: "._photo.jpg", parentPath: "/Volumes/USB", isHidden: true))
        #expect(ProtectedSystemItems.isProtected(name: "usr", parentPath: "/", isHidden: true))
        #expect(!ProtectedSystemItems.isProtected(name: "Applications", parentPath: "/", isHidden: false))
        #expect(!ProtectedSystemItems.isProtected(name: ".zshrc", parentPath: "/Users/ana", isHidden: true))
        #expect(!ProtectedSystemItems.isProtected(name: "Library", parentPath: "/Users/ana", isHidden: true))
        let kept = ProtectedSystemItems.filter([file(".DS_Store", hidden: true), file(".gitignore", hidden: true), file("a.txt")])
        #expect(kept.map(\.name) == [".gitignore", "a.txt"])
    }

    @Test func syncProviders() {
        let home = "/Users/ana"
        #expect(SyncProviderDetector.provider(forPath: "/Users/ana/Library/Mobile Documents/com~apple~CloudDocs/x", home: home)?.name == "iCloud Drive")
        let g = SyncProviderDetector.provider(forPath: "/Users/ana/Library/CloudStorage/GoogleDrive-ana@example.com/My Drive", home: home)
        #expect(g?.name == "Google Drive")
        #expect(g?.root == "/Users/ana/Library/CloudStorage/GoogleDrive-ana@example.com")
        #expect(SyncProviderDetector.provider(forPath: "/Users/ana/Library/CloudStorage/Dropbox", home: home)?.name == "Dropbox")
        #expect(SyncProviderDetector.provider(forPath: "/Users/ana/Library/CloudStorage/OneDrive-Personal/a", home: home)?.name == "OneDrive")
        #expect(SyncProviderDetector.displayName(ofStorageFolder: "SomeSync-x") == "Some Sync")
        #expect(SyncProviderDetector.provider(forPath: "/Users/ana/Documents", home: home) == nil)
        #expect(SyncProviderDetector.provider(forPath: "/Users/ana/Library/CloudStorage", home: home) == nil)
    }
}
