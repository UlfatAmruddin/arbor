import Foundation
import Testing
@testable import ArborCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

@Suite("Frequent folders (FE-072)")
struct FolderFrequencyTests {
    @Test func ranksByVisitsAndNeedsTwoVisits() {
        var f = FolderFrequency()
        for _ in 0..<3 { f.recordVisit("/a", at: now) }
        for _ in 0..<5 { f.recordVisit("/b/", at: now) }
        f.recordVisit("/once", at: now)
        #expect(f.ranked(now: now, limit: 10) == ["/b", "/a"])
        #expect(f.ranked(now: now, limit: 10, minimumVisits: 1).last == "/once")
    }

    @Test func oldVisitsFade() {
        var f = FolderFrequency()
        for _ in 0..<6 { f.recordVisit("/old", at: days(120)) }   // 6 × 1/16
        for _ in 0..<2 { f.recordVisit("/new", at: now) }
        #expect(f.ranked(now: now, limit: 10) == ["/new", "/old"])
    }

    @Test func excludesPinnedAndLimits() {
        var f = FolderFrequency()
        for path in ["/a", "/b", "/c"] { f.recordVisit(path, at: now); f.recordVisit(path, at: now) }
        #expect(f.ranked(now: now, limit: 1, excluding: ["/b/"]).count == 1)
        #expect(!f.ranked(now: now, limit: 10, excluding: ["/b/"]).contains("/b"))
    }

    @Test func boundedEvictsLeastImportant() {
        var f = FolderFrequency(capacity: 2)
        for _ in 0..<4 { f.recordVisit("/keep", at: now) }
        f.recordVisit("/weak", at: days(60))
        f.recordVisit("/fresh", at: now)
        #expect(f.entries.count == 2)
        #expect(Set(f.entries.map(\.path)) == ["/keep", "/fresh"])
    }

    @Test func renameMergesAndRemoveForgets() {
        var f = FolderFrequency()
        f.recordVisit("/x", at: now); f.recordVisit("/x", at: now); f.recordVisit("/y", at: now)
        f.rename("/x", to: "/y")
        #expect(f.entries.count == 1 && f.entries[0].count == 3)
        f.remove("/y")
        #expect(f.entries.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var f = FolderFrequency()
        f.recordVisit("/a", at: now)
        let decoded = try JSONDecoder().decode(FolderFrequency.self, from: JSONEncoder().encode(f))
        #expect(decoded == f)
    }
}

@Suite("Recent files merge (FE-072, FE-206, FE-239)")
struct RecentMergeTests {
    @Test func dedupesByPathKeepingNewest() {
        let arbor = [RecentEntry(path: "/f/a.txt", date: days(1), source: .arbor)]
        let spot = [RecentEntry(path: "/f/a.txt/", date: days(2), source: .spotlight),
                    RecentEntry(path: "/f/b.txt", date: days(3), source: .spotlight)]
        let merged = RecentMerge.merge([arbor, spot], cutoff: days(30), limit: 10)
        #expect(merged.map(\.path) == ["/f/a.txt", "/f/b.txt"])
        #expect(merged[0].date == days(1) && merged[0].source == .arbor)
    }

    @Test func cutoffAndLimit() {
        let list = (0..<40).map { RecentEntry(path: "/f/\($0)", date: days(Double($0)), source: .spotlight) }
        let merged = RecentMerge.merge([list], cutoff: days(30), limit: 20)
        #expect(merged.count == 20)
        #expect(merged.first?.path == "/f/0")
        #expect(RecentMerge.merge([list], cutoff: days(30), limit: 100).count == 31)
    }

    @Test func removedStaysHiddenUntilOpenedAgain() {
        let old = RecentEntry(path: "/f/a", date: days(2), source: .spotlight)
        let removed = ["/f/a": days(1)]
        #expect(RecentMerge.merge([[old]], removed: removed, cutoff: days(30), limit: 10).isEmpty)
        let reopened = RecentEntry(path: "/f/a", date: now, source: .arbor)
        #expect(RecentMerge.merge([[old, reopened]], removed: removed, cutoff: days(30), limit: 10).count == 1)
    }

    @Test func clearHistoryHidesEverythingBefore() {
        let list = [RecentEntry(path: "/a", date: days(3), source: .spotlight), RecentEntry(path: "/b", date: now, source: .arbor)]
        #expect(RecentMerge.merge([list], clearedAt: days(1), cutoff: days(30), limit: 10).map(\.path) == ["/b"])
    }

    @Test func pruneDropsExpiredMarks() {
        let pruned = RecentMerge.prune(removed: ["/a": days(40), "/b": days(2)], cutoff: days(30))
        #expect(pruned.keys.sorted() == ["/b"])
    }

    @Test func eligibility() {
        #expect(RecentMerge.isEligible(path: "/Users/me/Documents/a.txt", home: "/Users/me"))
        #expect(!RecentMerge.isEligible(path: "/Users/me/Library/Caches/x.db", home: "/Users/me"))
        #expect(!RecentMerge.isEligible(path: "/Users/me/.config/x", home: "/Users/me"))
        #expect(!RecentMerge.isEligible(path: "/Applications/Tool.app/Contents/x.plist", home: "/Users/me"))
    }

    @Test func recentLogMovesToFrontAndIsBounded() {
        var log = RecentLog(capacity: 2)
        log.record(ItemReference(path: "/a"), at: days(3))
        log.record(ItemReference(path: "/b"), at: days(2))
        log.record(ItemReference(path: "/a"), at: days(1))
        log.record(ItemReference(path: "/c"), at: now)
        #expect(log.records.map(\.reference.path) == ["/c", "/a"])
    }
}

@Suite("Item references keep real identity (FE-239)")
struct ItemReferenceTests {
    @Test func followsRenameAndIgnoresReplacement() throws {
        let fx = try Fixture()
        let original = try fx.file("docs/report.txt", "v1")
        let ref = ItemReference(url: original)
        #expect(ref.resolve()?.lastPathComponent == "report.txt")

        try FileManager.default.moveItem(at: original, to: fx.url("docs/renamed.txt"))
        #expect(ref.resolve()?.lastPathComponent == "renamed.txt")

        // A new file at the old path is a different item; the reference still points at the original.
        try fx.file("docs/report.txt", "impostor")
        #expect(ref.resolve()?.lastPathComponent == "renamed.txt")
    }

    @Test func deletedThenRecreatedIsNotTheOriginal() throws {
        let fx = try Fixture()
        let file = try fx.file("a.txt", "one")
        let ref = ItemReference(url: file)
        try FileManager.default.removeItem(at: file)
        try fx.file("a.txt", "two")
        #expect(ref.resolve() == nil)
    }

    @Test func goneOrTrashedResolvesToNil() throws {
        let fx = try Fixture()
        let file = try fx.file("a.txt")
        let ref = ItemReference(url: file)
        try fx.folder("x/.Trash")
        try FileManager.default.moveItem(at: file, to: fx.url("x/.Trash/a.txt"))
        #expect(ref.resolve() == nil)
        #expect(ItemReference(path: fx.url("missing.txt").path).resolve() == nil)
    }

    @Test func removingAReferenceNeverTouchesTheFile() throws {
        let fx = try Fixture()
        let file = try fx.file("keep.txt", "data")
        var log = RecentLog()
        log.record(ItemReference(url: file), at: now)
        log.clear()
        var freq = FolderFrequency()
        freq.recordVisit(fx.root.path, at: now)
        freq.clear()
        #expect(fx.read("keep.txt") == "data")
    }

    @Test func normalizesPrivateTmp() {
        #expect(HomePaths.normalized("/private/tmp/x/") == "/tmp/x")
        #expect(HomePaths.normalized("/private/var/folders/a") == "/var/folders/a")
    }
}

@Suite("This Mac capacity and drives (FE-074)")
struct CapacityTests {
    @Test func threeSignificantDigitsTruncated() {
        #expect(CapacityText.size(476_000_000_000) == "476 GB")
        #expect(CapacityText.size(15_990_000_000) == "15.9 GB")
        #expect(CapacityText.size(1_819_000_000_000) == "1.81 TB")
        #expect(CapacityText.size(999_999_999) == "999 MB")
        #expect(CapacityText.size(1_000_000_000) == "1.00 GB")
        #expect(CapacityText.size(512) == "512 bytes")
        #expect(CapacityText.size(0) == "0 bytes")
        #expect(CapacityText.size(15_900_000_000) == "15.9 GB")
    }

    @Test func freeOfTotalWording() {
        #expect(CapacityText.freeOfTotal(free: 120_500_000_000, total: 494_380_000_000) == "120 GB free of 494 GB")
    }

    @Test func barFractionAndRedThreshold() {
        #expect(CapacityText.usedFraction(free: 25, total: 100) == 0.75)
        #expect(CapacityText.usedFraction(free: nil, total: 100) == 0)
        #expect(!CapacityText.isNearlyFull(free: 10, total: 100))
        #expect(CapacityText.isNearlyFull(free: 9, total: 100))
        #expect(!CapacityText.isNearlyFull(free: nil, total: nil))
    }

    private func vol(_ name: String, _ kind: VolumeSummary.Kind, total: Int64? = 100) -> VolumeSummary {
        VolumeSummary(url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, kind: kind, total: total, free: 50)
    }

    @Test func sectionsAndOrder() {
        let all = [vol("Share", .network, total: nil), vol("Zip", .external), vol("Backup", .diskImage),
                   vol("Macintosh HD", .startup), vol("Card", .removable, total: 0), vol("Data", .internal)]
        let shown = VolumeSections.sections(all, hideEmpty: true)
        #expect(shown.map(\.title) == ["Devices and drives", "Network locations"])
        #expect(shown[0].volumes.map(\.name) == ["Macintosh HD", "Data", "Backup", "Zip"])
        #expect(shown[1].volumes.map(\.name) == ["Share"])
        let withEmpty = VolumeSections.sections(all, hideEmpty: false)
        #expect(withEmpty[0].volumes.map(\.name).contains("Card"))
        #expect(VolumeSections.sections([vol("A", .startup)], hideEmpty: true).map(\.title) == ["Devices and drives"])
    }

    @Test func networkNamesIncludeServer() {
        #expect(VolumeSections.displayName(volumeName: "Media", kind: .network, server: "nas.local") == "Media (nas.local)")
        #expect(VolumeSections.displayName(volumeName: "Media", kind: .external, server: "nas.local") == "Media")
        #expect(VolumeSections.displayName(volumeName: "Media", kind: .network, server: nil) == "Media")
    }
}
