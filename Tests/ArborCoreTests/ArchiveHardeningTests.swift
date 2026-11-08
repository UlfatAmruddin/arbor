import Foundation
import Testing
@testable import ArborCore

/// Hostile archive values: overflowing ZIP64 fields, absurd sizes, deep names, huge or unreadable listings.
@Suite struct ArchiveHardeningTests {
    private func u16(_ v: UInt16, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    private func u64(_ v: UInt64, _ d: inout Data) { for i in 0..<8 { d.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }

    /// A ZIP64 record (count 1) whose directory offset and size are attacker-chosen, then its locator and EOCD.
    private func zip64(offset: UInt64, size: UInt64, count: UInt64 = 1) -> Data {
        var d = Data()
        u32(0x0606_4B50, &d); u64(44, &d); u16(45, &d); u16(45, &d); u32(0, &d); u32(0, &d)
        u64(count, &d); u64(count, &d); u64(size, &d); u64(offset, &d)
        u32(0x0706_4B50, &d); u32(0, &d); u64(0, &d); u32(1, &d)
        u32(0x0605_4B50, &d); u16(0, &d); u16(0, &d); u16(0xFFFF, &d); u16(0xFFFF, &d)
        u32(0xFFFF_FFFF, &d); u32(0xFFFF_FFFF, &d); u16(0, &d)
        return d
    }

    @Test func zip64DirectoryBoundsCantOverflow() throws {
        let fx = try Fixture()
        let cases: [(UInt64, UInt64)] = [(0xFFFF_FFFF_FFFF_FF00, 0x100), (.max, 1), (1, .max)]
        for (i, (offset, size)) in cases.enumerated() {
            let url = fx.url("bad\(i).zip")
            try zip64(offset: offset, size: size).write(to: url)
            #expect(throws: ZipDirectory.ReadError.truncated) { try ZipDirectory.read(url) }
            #expect(throws: ZipDirectory.ReadError.truncated) { try ZipDirectory.read(url, limit: 20_000) }
            #expect(throws: ZipDirectory.ReadError.truncated) { try ZipDirectory.readRaw(url) }
            #expect(throws: ZipDirectory.ReadError.truncated) { try ZipDirectory.usesWindowsSeparators(url) }
        }
    }

    /// One central-directory record whose ZIP64 extra field declares `uncompressed` and `compressed`.
    private func zip64Record(_ name: String, uncompressed: UInt64, compressed: UInt64) -> Data {
        var d = Data()
        u32(0x0201_4B50, &d); u16(3 << 8 | 45, &d); u16(45, &d); u16(0x0800, &d); u16(0, &d); u16(0, &d); u16(0, &d)
        u32(0, &d); u32(0xFFFF_FFFF, &d); u32(0xFFFF_FFFF, &d)
        u16(UInt16(name.utf8.count), &d); u16(20, &d); u16(0, &d); u16(0, &d); u16(0, &d)
        u32(UInt32(0o100644) << 16, &d); u32(0, &d)
        d.append(contentsOf: Array(name.utf8))
        u16(0x0001, &d); u16(16, &d); u64(uncompressed, &d); u64(compressed, &d)
        return d
    }

    @Test func hugeDeclaredSizesDontOverflowTotals() throws {
        let directory = zip64Record("a", uncompressed: .max, compressed: .max) + zip64Record("b", uncompressed: .max, compressed: 1)
        let entries = try ZipDirectory.parseDirectory(directory, expected: 2)
        #expect(entries.map(\.size) == [ArchiveEntry.maxDeclaredSize, ArchiveEntry.maxDeclaredSize])
        #expect(ArchiveIndex(entries: entries).totalSize == 2 * ArchiveEntry.maxDeclaredSize)
        let plan = ExtractionPlanner.plan(entries: entries, roots: [""])
        #expect(plan.totalBytes == 2 * ArchiveEntry.maxDeclaredSize)
        #expect(ExpansionPolicy().check(archiveSize: 200, totalBytes: plan.totalBytes, freeSpace: nil) == .tooLarge(total: plan.totalBytes))

        #expect(Int64.max.saturatingAdd(1) == .max)
        #expect(Int64.min.saturatingAdd(-1) == .min)
        #expect(Int64(2).saturatingAdd(3) == 5)
        #expect(ArchiveEntry(rawPath: "x", kind: .file, size: -5).size == 0)
    }

    @Test func ratioStaysInRange() {
        func ratio(_ size: Int64?, _ packed: Int64?) -> Int? {
            ArchiveEntry(rawPath: "x", kind: .file, size: size, compressedSize: packed).savedPercent
        }
        #expect(ratio(100, 25) == 75)
        #expect(ratio(1, .max) == 0)       // used to trap converting about -9e20 to Int
        #expect(ratio(.max, 0) == 100)
        #expect(ratio(0, 10) == 0)
        #expect(ratio(nil, 10) == nil && ratio(10, nil) == nil)
    }

    @Test func overlongNamesAndLinkTargetsAreUnsafe() {
        let deep = Array(repeating: "a", count: 512).joined(separator: "/") + "/f"   // 1025 bytes
        #expect(ArchivePath.problem(deep) == .tooLong)
        #expect(ArchivePath.problem(String(deep.dropFirst(2))) == nil)
        let index = ArchiveIndex(entries: [ArchiveEntry(rawPath: deep, kind: .file, size: 1)])
        #expect(index.tooLongCount == 1 && index.unsafeCount == 0 && index.entryCount == 0)
        let target = String(repeating: "b/", count: 600)
        #expect(!ArchivePath.linkStaysInside(entry: ["l"], target: target))
        var resolver = LinkResolver(links: [(["l"], target)], base: [], foldCase: true)
        let inside = resolver.staysInside(["l"], target: target)
        #expect(!inside)
        #expect(ArchivePath.linkStaysInside(entry: ["l"], target: String(target.prefix(1000))))
    }

    @Test func chainedLinkTargetsAreBoundedToo() {
        // "l → x", where x's own target is far too long: resolving l must not expand it.
        let long = String(repeating: "a/", count: 30_000)
        let entries = [ArchiveEntry(rawPath: "x", kind: .symlink, linkTarget: long),
                       ArchiveEntry(rawPath: "l", kind: .symlink, linkTarget: "x")]
        let start = ContinuousClock.now
        let plan = ExtractionPlanner.plan(entries: entries, roots: [""])
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(plan.included.isEmpty && plan.rejected.map(\.reason) == [.linkOutside, .linkOutside])

        // Short targets that chain deeper than any member name can be also count as escaping.
        let step = String(repeating: "b/", count: 400)
        let deep = [ArchiveEntry(rawPath: "n", kind: .symlink, linkTarget: step + "m"),
                    ArchiveEntry(rawPath: step + "m", kind: .symlink, linkTarget: step + "end"),
                    ArchiveEntry(rawPath: "ok", kind: .symlink, linkTarget: step + "f")]
        let deepPlan = ExtractionPlanner.plan(entries: deep, roots: [""])
        #expect(deepPlan.rejected.map(\.entry.rawPath) == ["n", step + "m"])
        #expect(deepPlan.included.map(\.rawPath) == ["ok"])
    }

    @Test func manyLinksToOneLongTargetPlanInLinearTime() {
        // Each link's target is expanded once, however many links lead through it.
        let chain = (0..<31).map { ArchiveEntry(rawPath: "c\($0)", kind: .symlink, linkTarget: String(repeating: "a/../", count: 150) + "c\($0 + 1)") }
        let end = ArchiveEntry(rawPath: "c31", kind: .symlink, linkTarget: String(repeating: "a/", count: 500))
        let links = (0..<100_000).map { ArchiveEntry(rawPath: "l\($0)", kind: .symlink, linkTarget: "c0") }
        let start = ContinuousClock.now
        let plan = ExtractionPlanner.plan(entries: chain + [end] + links, roots: [""])
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(plan.included.count == 100_032 && plan.rejected.isEmpty)

        // Loops still escape, and a chain over 32 deep is refused.
        var resolver = LinkResolver(links: [(["a"], "b"), (["b"], "a/x")], base: [], foldCase: true)
        let loops = [resolver.staysInside(["a"], target: "b"), resolver.staysInside(["b"], target: "a/x")]
        #expect(loops == [false, false])
        let long = (0..<40).map { (["d\($0)"], "d\($0 + 1)") }
        var chained = LinkResolver(links: long, base: [], foldCase: true)
        let tooDeep = chained.staysInside(["d0"], target: "d1")
        var fresh = LinkResolver(links: long, base: [], foldCase: true)
        let shallow = fresh.staysInside(["d30"], target: "d31")
        #expect(!tooDeep && shallow)
    }

    @Test func deepNamesIndexAndPlanCorrectly() throws {
        let path = (0..<300).map { "d\($0 % 10)" }.joined(separator: "/")
        let entries = [
            ArchiveEntry(rawPath: "x/" + path, kind: .file, size: 1),
            ArchiveEntry(rawPath: "x/" + path + "/under-a-file", kind: .file, size: 1),
            ArchiveEntry(rawPath: String(path.prefix(500)) + "/f.txt", kind: .file, size: 1),
        ]
        let shallow = String(path.prefix(500))
        let index = ArchiveIndex(entries: entries)
        #expect(index.children(of: shallow)?.map(\.name) == ["f.txt"])
        #expect(index.node(at: shallow + "/f.txt")?.entry?.size == 1)
        #expect(index.node(at: "x/d0")?.isDirectory == true)
        #expect(index.node(at: "x/" + path)?.isDirectory == true)   // a folder wins over a same-named file
        #expect(index.children(of: shallow + "/nope") == nil)

        let plan = ExtractionPlanner.plan(entries: entries, roots: [""])
        #expect(plan.included.map(\.rawPath) == [shallow + "/f.txt"])
        #expect(plan.rejected.map(\.reason) == [.notAFolder, .insideNonFolder])
    }

    @Test func listingsThatImplyTooManyPathsFailCleanly() throws {
        let deep = ArchiveEntry(rawPath: (1...20).map { "p\($0)" }.joined(separator: "/"), kind: .file)
        #expect(throws: ArchiveError.tooManyEntries) { try ArchiveTool.checkBounds([deep], maxPaths: 10) }
        #expect(throws: ArchiveError.tooManyEntries) { try ArchiveTool.checkBounds([deep, deep], maxEntries: 1) }
        try ArchiveTool.checkBounds([deep, deep], maxPaths: 21)

        let text = (1...5).map { "-rw-r--r--  0 0 0 1 Jan  1  2020 f\($0)" }.joined(separator: "\n")
        #expect(BsdtarListing.parse(text, maxLines: 5).exceededLimit == false)
        let cut = BsdtarListing.parse(text, maxLines: 3)
        #expect(cut.exceededLimit && cut.entries.count == 3)
    }

    private func output(_ text: String, overflowed: Bool = false, cancelled: Bool = false) -> ToolProcess.Output {
        ToolProcess.Output(status: 0, stdout: Data(text.utf8), stderr: "", wasCancelled: cancelled, stdoutOverflowed: overflowed)
    }

    @Test func bsdtarOutputIsBoundedAndUnreadableRowsAreKept() throws {
        let text = """
        -rw-r--r--  0 0 0 5 Jan  1  2020 a.txt
        this row can't be read
        -rw-r--r--  0 0 0 5 Jan  1  2020 d/e/f.txt
        """
        let listing = try ArchiveTool.listing(from: output(text))
        #expect(listing.entries.map(\.rawPath) == ["a.txt", "d/e/f.txt", ""])
        let plan = ExtractionPlanner.plan(entries: listing.entries, roots: [""])
        #expect(plan.rejected.map(\.reason) == [.unreadable])
        #expect(plan.patterns == ["a.txt", "d/e/f.txt"])

        #expect(throws: ArchiveError.tooManyEntries) { try ArchiveTool.listing(from: output(text, overflowed: true)) }
        #expect(throws: ArchiveError.tooManyEntries) { try ArchiveTool.listing(from: output(text, overflowed: false), maxLines: 2) }
        #expect(throws: ArchiveError.tooManyEntries) { try ArchiveTool.listing(from: output(text), maxPaths: 4) }
        #expect(throws: ArchiveError.cancelled) { try ArchiveTool.listing(from: output(text, cancelled: true)) }
        _ = try ArchiveTool.listing(from: output(text), maxLines: 3, maxPaths: 5)
    }

    @Test func linkRowsWithTheSeparatorInTheNameAreUnreadable() {
        // bsdtar prints a link named "q -> a" with target "../../x" as "./q -> a -> ../../x".
        let text = """
        lrwxr-xr-x  0 0 0 0 Jan  1  2020 ./q -> a -> ../../x
        hrw-r--r--  0 0 0 0 Jan  1  2020 h link to b link to /etc/passwd
        lrwxr-xr-x  0 0 0 0 Jan  1  2020 ok -> sub/target
        """
        let listed = BsdtarListing.parse(text)
        #expect(listed.malformedLines == 2)
        #expect(listed.entries.map(\.rawPath) == ["ok"] && listed.entries.first?.linkTarget == "sub/target")
    }

    @Test func zipThatListsTooManyEntriesDoesntFallBackToBsdtar() throws {
        let fx = try Fixture()
        let url = fx.url("huge.zip")
        try zip64(offset: 0, size: 0, count: UInt64(ZipDirectory.maxEntries) + 1).write(to: url)
        #expect(throws: ArchiveError.tooManyEntries) { try ArchiveTool.list(url) }
    }

    @Test func toolOutputPastTheLimitStopsTheTool() throws {
        let output = try ToolProcess().run("/usr/bin/yes", [], stdoutLimit: 1 << 16)
        #expect(output.stdoutOverflowed && !output.wasCancelled)
        #expect(output.stdout.count <= 1 << 16)
        let small = try ToolProcess().run("/bin/echo", ["hi"], stdoutLimit: 1 << 16)
        #expect(!small.stdoutOverflowed && small.stdout == Data("hi\n".utf8))
    }

    @Test func unknownMemberTypesAreListedAndKeptOutOfWholeArchiveExtraction() throws {
        let utc = TimeZone(identifier: "UTC")!
        let text = """
        -rw-r--r--  0 0 0 5 Jan  1  2020 visible.txt
        ?rwxr-xr-x  0 0 0 5 Jan  1  2020 hidden.command
        """
        let listed = BsdtarListing.parse(text, timeZone: utc)
        #expect(listed.malformedLines == 0)
        let hidden = try #require(listed.entries.last)
        #expect(hidden.rawPath == "hidden.command" && hidden.kind == .unknown)
        let plan = ExtractionPlanner.plan(entries: listed.entries, roots: [""])
        #expect(plan.rejected.map(\.reason) == [.unknownType])
        #expect(plan.patterns == ["visible.txt"])   // named one by one, not "everything"

        // The stand-in for an unreadable row also forces per-file names.
        let standIn = ArchiveEntry(rawPath: "", kind: .special)
        let guarded = ExtractionPlanner.plan(entries: [listed.entries[0], standIn], roots: [""])
        #expect(guarded.patterns == ["visible.txt"])
        let index = ArchiveIndex(entries: [standIn])
        #expect(index.unreadableCount == 1 && index.unsafeCount == 0 && index.tooLongCount == 0)
    }

    @Test func listingsMadeOnlyOfUnreadableRowsStillFail() {
        let failed = ToolProcess.Output(status: 1, stdout: Data("garbage\nmore garbage\n".utf8), stderr: "bsdtar: Damaged archive",
                                        wasCancelled: false, stdoutOverflowed: false)
        #expect(throws: ArchiveError.unreadable("Damaged archive")) { try ArchiveTool.listing(from: failed) }
    }

    @Test func hiddenEntriesAreCountedByReason() {
        let deep = Array(repeating: "a", count: 512).joined(separator: "/") + "/f"
        let index = ArchiveIndex(entries: [
            ArchiveEntry(rawPath: "../up", kind: .file), ArchiveEntry(rawPath: deep, kind: .file),
            ArchiveEntry(rawPath: String(repeating: "n", count: 300), kind: .file),
            ArchiveEntry(rawPath: "", kind: .special), ArchiveEntry(rawPath: "ok", kind: .file),
        ])
        #expect(index.unsafeCount == 1 && index.tooLongCount == 2 && index.unreadableCount == 1 && index.entryCount == 1)
    }

    /// Writes `links` (name → target) into a new folder and archives them with bsdtar.
    private func linkArchive(_ fx: Fixture, _ links: [(String, String)]) throws -> URL {
        let source = try fx.folder("links-src")
        for (name, target) in links {
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let archive = fx.url("links.tar")
        let made = try ToolProcess().run("/usr/bin/bsdtar", ["-c", "-f", archive.path, "-C", source.path] + links.map(\.0))
        #expect(made.status == 0)
        return archive
    }

    @Test func linksSpelledWithWiderCaseFoldingCantEscape() throws {
        // APFS treats "ſ" as "s" (and "ß" as "ss"); lowercased() doesn't, so "ſ" used to hide the link "s".
        let fx = try Fixture()
        let archive = try linkArchive(fx, [("s", "."), ("esc", "ſ/ſ/ſ/../../../outside"), ("ss", "."), ("esc2", "ß/../outside"),
                                           ("fine", "S/ſ/s")])
        let listing = try ArchiveTool.listWithBsdtar(archive)
        let plan = ExtractionPlanner.plan(entries: listing.entries, roots: [""])
        #expect(Set(plan.rejected.map(\.entry.rawPath)) == ["esc", "esc2"])
        #expect(Set(plan.rejected.map(\.reason)) == [.linkOutside])
        #expect(Set(plan.included.map(\.rawPath)) == ["s", "ss", "fine"])

        // Even if a plan let them through, the verifier reads the links on disk and removes the escaping ones.
        let staging = try fx.folder("stage")
        let extracted = try ToolProcess().run("/usr/bin/bsdtar", ["-x", "-f", archive.path, "-C", staging.path])
        #expect(extracted.status == 0)
        let folds = FileManager.default.fileExists(atPath: staging.appendingPathComponent("ſ").path)
        let report = ExtractionVerifier.verify(staging: staging, base: [], quarantine: nil)
        #expect(Set(report.removed) == (folds ? ["esc", "esc2"] : []))
        #expect(Set(fx.names("stage")) == Set(["fine", "s", "ss"] + (folds ? [] : ["esc", "esc2"])))
    }

    @Test func verifierFollowsLinksOnDiskInLinearTime() throws {
        let fx = try Fixture()
        let staging = try fx.folder("stage")
        try fx.folder("stage/sub/inner")
        func link(_ name: String, _ target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: fx.url("stage/" + name).path, withDestinationPath: target)
        }
        try link("sub/up", "..")
        try link("sub/inner/deep", "../up/../../x")     // "up" is followed before "..", so this escapes
        try link("sub/inner/ok", "../up/sub/inner")
        try link("a", "b")
        try link("b", "a/x")                           // a loop
        for i in 0..<31 { try link("c\(i)", String(repeating: "n/../", count: 50) + "c\(i + 1)") }
        try link("c31", "sub")
        for i in 0..<3000 { try link("l\(i)", "c0/inner") }
        let start = ContinuousClock.now
        let report = ExtractionVerifier.verify(staging: staging, base: [], quarantine: nil)
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(Set(report.removed) == ["sub/inner/deep", "a", "b"])
        #expect(fx.exists("stage/sub/inner/ok") && fx.names("stage").count == 1 + 32 + 3000)   // sub, c0…c31, l0…
    }
}
