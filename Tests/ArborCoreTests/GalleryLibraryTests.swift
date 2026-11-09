import Foundation
import Testing
@testable import ArborCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

private func photo(_ name: String, _ when: Date, aspect: Double? = nil, folder: String = "/p") -> GalleryItem {
    GalleryItem(url: URL(fileURLWithPath: "\(folder)/\(name)"), date: when, kind: .image, aspect: aspect)
}

@Suite("Gallery timeline (FE-075)")
struct GalleryTimelineTests {
    @Test func groupsByMonthNewestFirst() {
        let items = [photo("a.jpg", date(2026, 3, 2)), photo("b.jpg", date(2026, 11, 5)), photo("c.jpg", date(2026, 11, 20)),
                     photo("d.jpg", date(2025, 11, 30)), photo("e.jpg", date(2026, 3, 31, 23))]
        let months = GalleryTimeline.months(items, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(months.map(\.title) == ["November 2026", "March 2026", "November 2025"])
        #expect(months[0].items.map(\.url.lastPathComponent) == ["c.jpg", "b.jpg"])
        #expect(months[1].items.map(\.url.lastPathComponent) == ["e.jpg", "a.jpg"])
        #expect(months.map(\.items.count).reduce(0, +) == items.count)
    }

    @Test func oldestFirstReversesSectionsAndItems() {
        let items = [photo("a.jpg", date(2026, 3, 2)), photo("b.jpg", date(2026, 11, 5)), photo("c.jpg", date(2026, 11, 20))]
        let months = GalleryTimeline.months(items, newestFirst: false, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(months.map(\.month) == [3, 11])
        #expect(months[1].items.map(\.url.lastPathComponent) == ["b.jpg", "c.jpg"])
    }

    @Test func monthBoundaryFollowsCalendarTimeZone() {
        // 2026-12-01 02:00 UTC is still November in New York.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let items = [photo("late.jpg", date(2026, 12, 1, 2))]
        #expect(GalleryTimeline.months(items, calendar: ny, locale: Locale(identifier: "en_US")).first?.month == 11)
        #expect(GalleryTimeline.months(items, calendar: utc, locale: Locale(identifier: "en_US")).first?.month == 12)
    }

    @Test func tiesAreStableByPath() {
        let same = date(2026, 1, 1)
        let sorted = GalleryTimeline.sorted([photo("b.jpg", same), photo("a.jpg", same), photo("a10.jpg", same), photo("a2.jpg", same)])
        #expect(sorted.map(\.url.lastPathComponent) == ["a.jpg", "a2.jpg", "a10.jpg", "b.jpg"])
    }

    @Test func yearsForRail() {
        let items = [photo("a", date(2026, 11, 1)), photo("b", date(2026, 2, 1)), photo("c", date(2024, 7, 1)), photo("d", date(2024, 1, 1))]
        let months = GalleryTimeline.months(items, calendar: utc)
        let years = GalleryTimeline.years(months)
        #expect(years.map(\.year) == [2026, 2024])
        #expect(years.map(\.firstSection) == [0, 2])
    }

    @Test func bestDatePrefersTakenThenEarlierFileDate() {
        let now = date(2026, 11, 7)
        #expect(GalleryTimeline.bestDate(taken: date(2020, 1, 1), created: date(2019, 1, 1), modified: nil, now: now) == date(2020, 1, 1))
        #expect(GalleryTimeline.bestDate(taken: nil, created: date(2021, 1, 1), modified: date(2022, 1, 1), now: now) == date(2021, 1, 1))
        // A copied photo: created today, modified years ago.
        #expect(GalleryTimeline.bestDate(taken: nil, created: date(2026, 11, 7), modified: date(2023, 5, 1), now: now) == date(2023, 5, 1))
        // A camera with a bad clock (year 2099) or a 1601 zero date falls through.
        #expect(GalleryTimeline.bestDate(taken: date(2099, 1, 1), created: nil, modified: date(2022, 1, 1), now: now) == date(2022, 1, 1))
        #expect(GalleryTimeline.bestDate(taken: Date(timeIntervalSince1970: -11_644_473_600), created: nil, modified: nil, now: now) == nil)
    }

    @Test func parsesExifDates() {
        let tz = TimeZone(identifier: "UTC")!
        #expect(GalleryTimeline.parseExifDate("2024:03:15 14:30:05", timeZone: tz) == utc.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 14, minute: 30, second: 5)))
        #expect(GalleryTimeline.parseExifDate("2024-03-15", timeZone: tz) == utc.date(from: DateComponents(year: 2024, month: 3, day: 15)))
        #expect(GalleryTimeline.parseExifDate("0000:00:00 00:00:00", timeZone: tz) == nil)
        #expect(GalleryTimeline.parseExifDate("garbage", timeZone: tz) == nil)
    }

    @Test func aspectAppliesOrientation() {
        #expect(GalleryTimeline.aspect(width: 4000, height: 3000) == 4000.0 / 3000.0)
        #expect(GalleryTimeline.aspect(width: 4000, height: 3000, orientation: 6) == 3000.0 / 4000.0)
        #expect(GalleryTimeline.aspect(width: 0, height: 3000) == nil)
    }
}

@Suite("Justified grid")
struct JustifiedLayoutTests {
    @Test func fullRowsSpanTheWidthAndLastRowKeepsTargetHeight() {
        let aspects: [Double?] = [1.5, 1.0, 0.75, 1.33, 1.5, 1.0, nil]
        let rows = JustifiedLayout.rows(aspects: aspects, width: 600, targetHeight: 150, spacing: 4)
        #expect(rows.flatMap(\.indexes) == Array(0..<aspects.count))
        for row in rows.dropLast() {
            let last = row.frames.last!
            #expect(abs(last.x + last.width - 600) < 0.001)
            #expect(row.height <= 150 * 1.6)
        }
        #expect(rows.last?.height == 150)
        // Tiles in a row don't overlap and keep the spacing.
        for row in rows {
            for (a, b) in zip(row.frames, row.frames.dropFirst()) { #expect(abs(b.x - (a.x + a.width) - 4) < 0.001) }
        }
    }

    @Test func extremeAspectsAreClamped() {
        let rows = JustifiedLayout.rows(aspects: [20, 0.01], width: 1000, targetHeight: 100, spacing: 0)
        #expect(rows.count == 1)
        #expect(rows[0].frames[0].width == JustifiedLayout.maxAspect * 100)
        #expect(rows[0].frames[1].width == JustifiedLayout.minAspect * 100)
    }

    @Test func emptyAndZeroWidth() {
        #expect(JustifiedLayout.rows(aspects: [], width: 500, targetHeight: 100, spacing: 2).isEmpty)
        #expect(JustifiedLayout.rows(aspects: [1], width: 0, targetHeight: 100, spacing: 2).isEmpty)
    }
}

@Suite("Gallery collection (FE-075, FE-239)")
struct GalleryCollectionTests {
    let home = URL(fileURLWithPath: "/Users/me")

    @Test func defaultIsPicturesAndPhotoLibraryIsNeverAScanTarget() {
        var c = GalleryCollection.defaults(home: home)
        #expect(c.scanRoots.map(\.path) == ["/Users/me/Pictures"])
        #expect(GalleryScanRules.isExcluded(path: "/Users/me/Pictures/Photos Library.photoslibrary/originals/A/x.heic"))
        #expect(GalleryScanRules.isExcluded(path: "/Users/me/Pictures/Old.migratedphotolibrary"))
        #expect(!GalleryScanRules.isExcluded(path: "/Users/me/Pictures/Trips/x.heic"))
        let r1 = c.add(URL(fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary"))
        #expect(!r1)
        let r2 = c.add(URL(fileURLWithPath: "/Users/me/Pictures/"))   // already there
        #expect(!r2)
    }

    @Test func nestedSourcesScanOnceAndUncheckedSubfolderHides() {
        var c = GalleryCollection.defaults(home: home)
        let r3 = c.add(URL(fileURLWithPath: "/Users/me/Pictures/Trips"))
        #expect(r3)
        let r4 = c.add(URL(fileURLWithPath: "/Volumes/Card/DCIM"))
        #expect(r4)
        #expect(c.scanRoots.map(\.path) == ["/Users/me/Pictures", "/Volumes/Card/DCIM"])
        c.setIncluded(URL(fileURLWithPath: "/Users/me/Pictures/Trips"), false)
        #expect(GalleryScanRules.isVisible(path: "/Users/me/Pictures/a.jpg", in: c))
        #expect(!GalleryScanRules.isVisible(path: "/Users/me/Pictures/Trips/b.jpg", in: c))
        c.setIncluded(URL(fileURLWithPath: "/Users/me/Pictures"), false)
        #expect(c.scanRoots.map(\.path) == ["/Volumes/Card/DCIM"])
        #expect(!GalleryScanRules.isVisible(path: "/Users/me/Pictures/a.jpg", in: c))
        #expect(!GalleryScanRules.isVisible(path: "/Users/other/a.jpg", in: c))
    }

    @Test func removingASourceOnlyEditsTheList() {
        var c = GalleryCollection.defaults(home: home)
        c.remove(URL(fileURLWithPath: "/Users/me/Pictures"))
        #expect(c.sources.isEmpty)
        #expect(c.scanRoots.isEmpty)
    }

    @Test func kindsFromExtensionsAndContentTypes() {
        #expect(GalleryScanRules.kind(forExtension: "HEIC") == .image)
        #expect(GalleryScanRules.kind(forExtension: "mov") == .video)
        #expect(GalleryScanRules.kind(forExtension: "txt") == nil)
        #expect(GalleryScanRules.kind(forContentTypeTree: ["public.jpeg", "public.image", "public.data"]) == .image)
        #expect(GalleryScanRules.kind(forContentTypeTree: ["com.apple.quicktime-movie", "public.movie"]) == .video)
    }

    @Test func itemSetIsBoundedAndKeepsNewest() {
        var set = GalleryItemSet(limit: 3)
        set.insert((1...5).map { photo("\($0).jpg", date(2026, $0, 1)) })
        #expect(set.count == 3)
        #expect(Set(set.all.map(\.url.lastPathComponent)) == ["3.jpg", "4.jpg", "5.jpg"])
        #expect(set.droppedForLimit == 2)
        set.insert([photo("5.jpg", date(2026, 5, 1))])   // same path replaces, doesn't duplicate
        #expect(set.count == 3)
        set.retain { $0.hasSuffix("4.jpg") }
        #expect(set.all.map(\.url.lastPathComponent) == ["4.jpg"])
    }
}

@Suite("Libraries (FE-076, FE-238, FE-239)")
struct LibraryTests {
    let home = URL(fileURLWithPath: "/Users/me")

    @Test func defaultsHaveOneFolderEach() {
        let libs = LibraryLogic.defaults(home: home)
        #expect(libs.map(\.name) == ["Documents", "Music", "Pictures", "Videos"])
        #expect(libs.map { $0.folders } == [["/Users/me/Documents"], ["/Users/me/Music"], ["/Users/me/Pictures"], ["/Users/me/Movies"]])
        #expect(libs.allSatisfy { $0.saveLocation == $0.folders.first })
    }

    @Test func removingTheSaveLocationMovesItToTheNextFolder() {
        var lib = LibraryDefinition(name: "Documents", folders: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")])
        #expect(lib.saveLocation == "/a")
        let r5 = lib.setSaveLocation(URL(fileURLWithPath: "/b"))
        #expect(r5)
        let r6 = lib.setSaveLocation(URL(fileURLWithPath: "/elsewhere"))
        #expect(!r6)
        lib.remove(URL(fileURLWithPath: "/b"))
        #expect(lib.saveLocation == "/c")
        lib.remove(URL(fileURLWithPath: "/c"))
        #expect(lib.saveLocation == "/a")
        lib.remove(URL(fileURLWithPath: "/a"))
        #expect(lib.saveLocation == nil)
        let first = lib.add(URL(fileURLWithPath: "/x"))
        #expect(first == .added)
        let sameFolder = lib.add(URL(fileURLWithPath: "/x/"))
        #expect(sameFolder == .alreadyIncluded)
    }

    @Test func saveLocationResolution() {
        var lib = LibraryDefinition(name: "Music", folders: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])
        lib.setSaveLocation(URL(fileURLWithPath: "/b"))
        #expect(LibraryLogic.resolveSaveLocation(lib) { _ in true } == .folder(URL(fileURLWithPath: "/b"), isFallback: false))
        #expect(LibraryLogic.resolveSaveLocation(lib) { $0.path == "/a" } == .folder(URL(fileURLWithPath: "/a"), isFallback: true))
        if case .unavailable(let reason) = LibraryLogic.resolveSaveLocation(lib, isUsable: { _ in false }) {
            #expect(reason.contains("Music"))
        } else {
            Issue.record("expected unavailable")
        }
        let empty = LibraryDefinition(name: "Videos", folders: [])
        #expect(LibraryLogic.resolveSaveLocation(empty) { _ in true }.url == nil)
    }

    @Test func mergeDedupesByFolderIdentityNotByName() {
        func entry(_ folder: String, _ name: String) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "\(folder)/\(name)"), name: name, isFolder: false)
        }
        let result = LibraryMerge.merge([
            LibrarySourceListing(folder: URL(fileURLWithPath: "/a"), folderID: "1:10", items: [entry("/a", "x.txt"), entry("/a", "y.txt")]),
            LibrarySourceListing(folder: URL(fileURLWithPath: "/b"), folderID: "1:20", items: [entry("/b", "x.txt")]),
            LibrarySourceListing(folder: URL(fileURLWithPath: "/link-to-a"), folderID: "1:10", items: [entry("/link-to-a", "x.txt")]),
            LibrarySourceListing(folder: URL(fileURLWithPath: "/gone"), folderID: nil, items: [], problem: "missing"),
        ])
        #expect(result.items.map(\.url.path) == ["/a/x.txt", "/a/y.txt", "/b/x.txt"])
        #expect(result.duplicateFolders.map(\.path) == ["/link-to-a"])
        #expect(result.unavailable.map(\.folder.path) == ["/gone"])
    }

    @Test func listsRealFoldersAndRecognizesSymlinkedDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-lib-\(UUID().uuidString)")
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "1".write(to: a.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "2".write(to: b.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("LinkToA")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let lib = LibraryDefinition(name: "Documents", folders: [a, b, link, root.appendingPathComponent("Missing")])
        let result = LibraryMerge.list(lib, includeHidden: false)
        #expect(result.items.count == 2)
        #expect(Set(result.items.map { $0.url.deletingLastPathComponent().lastPathComponent }) == ["A", "B"])
        #expect(result.duplicateFolders.map(\.lastPathComponent) == ["LinkToA"])
        #expect(result.unavailable.count == 1)
        #expect(LibraryMerge.folderColumnText(for: a.appendingPathComponent("same.txt")) == "A (\(root.standardizedFileURL.path))")
    }

    @Test func definitionsRoundTripThroughJSON() throws {
        let libs = LibraryLogic.defaults(home: home)
        let data = try JSONEncoder().encode(libs)
        #expect(try JSONDecoder().decode([LibraryDefinition].self, from: data) == libs)
    }
}
