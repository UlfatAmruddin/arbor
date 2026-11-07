import Foundation
import Testing
@testable import ArborCore

@Suite("Memory and responsiveness (FE-228, FE-243, FE-251, FE-252)")
struct PerformanceTests {
    // MARK: Kinds per extension

    @Test func kindsMatchLaunchServicesPerFile() throws {
        let fixture = try Fixture()
        let names = ["a.txt", "b.pdf", "c.docx", "d.xlsx", "e.png", "f.JPG", "g.md", "h.zip", "i.csv", "j.json", "k.swift",
                     "l.mov", "m.tar.gz", "n.heic", "o.rtf", "p.html", "q.mp3", "r.numbers", "s.xyzunknown", "noextension",
                     "t.", "Résumé.pages", "u.webloc", "v.dmg", "w.plist"]
        for name in names { try fixture.file(name) }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("dotted.folder"), withIntermediateDirectories: true)
        for name in names + ["folder", "dotted.folder"] {
            let url = fixture.root.appendingPathComponent(name)
            let expected = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
            let item = try #require(FileItem(url: URL(fileURLWithPath: url.path)))
            #expect(item.typeDescription == expected, "\(name)")
        }
    }

    @Test func pathExtensionMatchesNSString() {
        for name in ["a.txt", "archive.tar.gz", ".hidden", "plain", "trailing.", "x.y z", "Ünïcødé.JPEG", "v1. draft", "a.b.c"] {
            #expect(TypeDescriptions.pathExtension(name) == (name as NSString).pathExtension, "\(name)")
        }
    }

    @Test func listedItemsDropCachedResourceValues() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", "hello")
        let items = try DirectoryLister.list(fixture.root, includeHidden: false)
        let item = try #require(items.first { $0.name == "a.txt" })
        #expect(item.size == 5)
        #expect(item.typeDescription.isEmpty == false)
    }

    // MARK: Large sorts

    private func sample(_ count: Int) -> [FileItem] {
        let words = ["Report", "report", "résumé", "Resume", "file", "File 10", "file 9", "ｆｕｌｌ", "draft", "Zeta", "alpha", "e\u{301}clair", "éclair"]
        let kinds = ["PDF document", "Plain Text", "Folder", "JPEG image"]
        return (0..<count).map { i in
            let name = "\(words[i % words.count]) \(i % 37).\(["txt", "pdf", "md"][i % 3])"
            let folder = i % 11 == 0
            return FileItem(url: URL(fileURLWithPath: "/fixture/\(i % 5)/\(name)"), name: name, isFolder: folder,
                            size: folder || i % 13 == 0 ? nil : Int64((i * 7919) % 5000),
                            modified: i % 17 == 0 ? nil : Date(timeIntervalSince1970: Double((i * 104_729) % 100_000)),
                            typeDescription: kinds[i % kinds.count])
        }
    }

    @Test(.serialized, arguments: [(SortKey.name, true, true), (.name, false, false), (.type, true, true), (.size, false, true),
                      (.dateModified, true, false)])
    func largeSortMatchesReference(_ key: SortKey, _ ascending: Bool, _ foldersFirst: Bool) {
        let items = sample(LargeSort.parallelThreshold + 1_000).shuffled()
        var order = FileSortOrder(key: key, ascending: ascending, foldersFirst: foldersFirst)
        if key != .name { order.thenBy = [SortCriterion(ColumnID("name"), ascending: !ascending)] }
        let reference = items.sorted { FileSorter.precedes($0, $1, order) }
        #expect(LargeSort.sorted(items, by: order, parallel: true) == reference)
        #expect(LargeSort.sorted(items, by: order, parallel: false) == reference)
        #expect(LargeSort.isSorted(reference, by: order))
        #expect(LargeSort.sorted(reference, by: order) == reference)
    }

    @Test func standardCompareMatchesFoundation() {
        let names = ["a", "A", "b", "file2", "file10", "File 2", "résumé", "resume", "Résumé", "e\u{301}", "é", "ｆｕｌｌ", "full",
                     "_x", "-x", " x", "x", "😀", "日本", "Ωmega", "omega", "a.b", "a-b", "a b", "A10b", "a9b", ""]
        for x in names {
            for y in names {
                let expected = x.localizedStandardCompare(y)
                let actual = LargeSort.standardCompare(NSString(string: x) as CFString, NSString(string: y) as CFString,
                                                       locale: CFLocaleCopyCurrent())
                #expect(actual == expected, "\(x) vs \(y)")
            }
        }
    }

    @Test func parallelSortSortsIntegers() {
        var values = (0..<50_001).map { ($0 * 7919) % 50_001 }
        LargeSort.parallelSort(&values) { $0 < $1 }
        #expect(values == Array(0..<50_001))
    }

    // MARK: Folder kind detection

    @Test func templateDetectionPerExtensionMatchesPerFile() {
        for mix in [["jpg", "JPG", "png", "txt"], ["mov", "zip", "noext", "mp4"], ["mp3", "m4a", "txt"], ["pdf", "docx", "jpg"]] {
            let names = (0..<300).map { "file \($0).\(mix[$0 % mix.count])" }
            let items = names.map { FileItem(url: URL(fileURLWithPath: "/x/\($0)"), name: $0, isFolder: false) }
            var counts: [FolderTemplate: Int] = [:]
            for name in names { if let kind = FolderTemplateDetector.kind(of: name) { counts[kind, default: 0] += 1 } }
            var best = FolderTemplate.generalItems, bestCount = 0
            for t in [FolderTemplate.pictures, .videos, .music, .documents] where (counts[t] ?? 0) > bestCount { best = t; bestCount = counts[t] ?? 0 }
            let expected = Double(bestCount) / 300 >= FolderTemplateDetector.threshold ? best : .generalItems
            #expect(FolderTemplateDetector.detect(items: items) == expected, "\(mix)")
        }
    }

    // MARK: Stall recorder

    @Test func stallRecorderKeepsOnlyLongPasses() {
        let recorder = StallRecorder(thresholdMilliseconds: 50, capacity: 3)
        #expect(!recorder.record(milliseconds: 49, label: "nav"))
        #expect(recorder.record(milliseconds: 51, label: "nav:a"))
        recorder.record(milliseconds: 200, label: "snapshot:/x")
        recorder.record(milliseconds: 80, label: "scroll")
        recorder.record(milliseconds: 90, label: "nav:b")
        #expect(recorder.totalCount == 4)
        #expect(recorder.stalls.count == 3)
        recorder.ignoredLabels = ["snapshot"]
        #expect(recorder.stalls(matching: "nav").map(\.milliseconds) == [90])
        #expect(recorder.summary() == "count=2 max=90ms total=170ms")
        recorder.reset()
        #expect(recorder.summary() == "count=0 max=0ms total=0ms")
    }

    // MARK: Cache registry and listing budget

    @Test func registryTrimsEveryCacheAndReportsSizes() {
        let registry = CacheRegistry()
        var trimmed: [String] = []
        let cache = ByteBudgetCache<Int, Int>(byteLimit: 1000)
        for i in 0..<10 { cache.insert(i, for: i, cost: 100) }
        registry.register("numbers", budget: 1000, bytes: { cache.totalCost }, count: { cache.count }) { level in
            trimmed.append("numbers")
            cache.trim(toBytes: level == .critical ? 0 : cache.byteLimit / 4)
        }
        registry.register("other", budget: 10, bytes: { 5 }, count: { 1 }) { _ in trimmed.append("other") }
        #expect(registry.totalBytes == 1005)
        registry.trim(.warning)
        #expect(cache.totalCost == 200)
        registry.trim(.critical)
        #expect(cache.totalCost == 0)
        #expect(trimmed == ["numbers", "other", "numbers", "other"])
        #expect(registry.summary.contains("numbers=0.0MB/0"))
        registry.register("other", budget: 10, bytes: { 7 }, count: { 1 }) { _ in }
        #expect(registry.entries.count == 2)
    }

    @Test func listingBudgetEvictsOldestInactiveByBytes() {
        var budget = ListingBudget(byteLimit: 1000)
        #expect(budget.touch("a", cost: 400, active: ["a"]).isEmpty)
        #expect(budget.touch("b", cost: 400, active: ["b"]).isEmpty)
        // c pushes the total to 1200: the oldest inactive listing (a) goes.
        #expect(budget.touch("c", cost: 400, active: ["c"]) == ["a"])
        #expect(budget.totalCost == 800)
        // An active listing is never evicted, even over budget.
        #expect(budget.touch("d", cost: 900, active: ["b", "c", "d"]).isEmpty)
        #expect(budget.touch("b", cost: 400, active: ["b"]) == ["c", "d"])
        budget.remove("b")
        #expect(budget.totalCost == 0)
        #expect(budget.trim(toBytes: 0, active: []) == [])
    }

    @Test func listingCostGrowsWithNames() {
        let short = FileItem(url: URL(fileURLWithPath: "/a"), name: "a", isFolder: false)
        let long = FileItem(url: URL(fileURLWithPath: "/" + String(repeating: "x", count: 100)), name: String(repeating: "x", count: 100), isFolder: false)
        #expect(CacheBudgets.listingCost(long) > CacheBudgets.listingCost(short))
        #expect(CacheBudgets.totalBytes >= CacheBudgets.thumbnailBytes)
    }

    // MARK: Process metrics

    @Test func processMetricsAreSane() {
        let m = ProcessMetrics.current()
        #expect(m.footprint > 1 << 20)
        #expect(m.peakFootprint >= m.footprint)
        #expect(m.cpuSeconds > 0)
        #expect((ProcessMetrics.secondsSinceLaunch() ?? -1) >= 0)
    }

    // MARK: Volume lookups

    @Test func mountTableKnowsTheRootAndNotOrdinaryFolders() throws {
        let fixture = try Fixture()
        #expect(MountPoints.shared.isMountPoint("/"))
        #expect(!MountPoints.shared.isMountPoint(fixture.root.path))
        #expect(Location.isVolumeRoot(URL(fileURLWithPath: "/")))
        #expect(!Location.isVolumeRoot(fixture.root))
    }

    @Test func volumeIdentityIsCached() throws {
        let fixture = try Fixture()
        let a = try fixture.file("a.txt")
        let b = try fixture.file("sub/b.txt")
        #expect(FileOps.sameVolumeCached(a, b))
        #expect(FileOps.sameVolumeCached(a, b))
        #expect(FileOps.sameVolumeCached(a, b) == FileOps.sameVolume(a, b))
        #expect(!FileOps.sameVolumeCached(a, fixture.root.appendingPathComponent("missing/x")))
    }
}

@Suite("Change-event throttle (FE-229)")
struct EventThrottleTests {
    private func near(_ x: Double?, _ y: Double) -> Bool { x.map { abs($0 - y) < 1e-9 } ?? false }

    @Test func firstChangeIsQuickAndBurstsAreSpaced() {
        var throttle = EventThrottle(quietDelay: 0.15, minimumSpacing: 1.0)
        #expect(near(throttle.event(at: 10), 0.15))
        #expect(throttle.event(at: 10.05) == nil)     // folded into the scheduled reload
        throttle.fired(at: 10.15)
        // A change right after a reload waits for the spacing, not the quiet delay.
        let delay = throttle.event(at: 10.2)
        #expect(abs((delay ?? 0) - 0.95) < 0.0001)
        #expect(throttle.event(at: 10.5) == nil)
        throttle.fired(at: 11.15)
        // After a quiet period the next change is quick again.
        #expect(near(throttle.event(at: 20), 0.15))
        throttle.reset()
        #expect(near(throttle.event(at: 20.01), 0.15))
    }

    @Test func continuousChangesStillReloadEverySecond() {
        var throttle = EventThrottle()
        var fires: [Double] = []
        var pending: Double?
        var t = 0.0
        while t < 5 {
            if let at = pending, t >= at { throttle.fired(at: t); fires.append(t); pending = nil }
            if let delay = throttle.event(at: t) { pending = t + delay }
            t += 0.01
        }
        #expect(fires.count >= 4)
        #expect(zip(fires.dropFirst(), fires).allSatisfy { $0 - $1 >= 0.99 })
    }
}
