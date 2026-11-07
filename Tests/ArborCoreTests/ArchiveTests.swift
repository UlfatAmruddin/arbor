import Foundation
import Testing
@testable import ArborCore

/// Builds small stored (uncompressed) ZIP files byte by byte, including hostile ones.
struct TestZip {
    struct Member {
        var name: String
        var data: Data
        var unixMode: UInt16 = 0o100644
        var flags: UInt16 = 0x0800
        var nameBytes: [UInt8]? = nil
    }
    var members: [Member] = []

    mutating func file(_ name: String, _ text: String = "x") { members.append(Member(name: name, data: Data(text.utf8))) }
    mutating func folder(_ name: String) { members.append(Member(name: name.hasSuffix("/") ? name : name + "/", data: Data(), unixMode: 0o040755)) }
    mutating func link(_ name: String, to target: String) { members.append(Member(name: name, data: Data(target.utf8), unixMode: 0o120777)) }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    func build() -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: UInt16, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        for m in members {
            let name = m.nameBytes ?? Array(m.name.utf8)
            let crc = Self.crc32(m.data)
            let offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(m.flags, &out); u16(0, &out)
            u16(0x6000, &out); u16(0x5A67, &out)   // 12:00, 2025-03-07
            u32(crc, &out); u32(UInt32(m.data.count), &out); u32(UInt32(m.data.count), &out)
            u16(UInt16(name.count), &out); u16(0, &out)
            out.append(contentsOf: name); out.append(m.data)

            u32(0x0201_4B50, &central); u16(0x0314, &central); u16(20, &central); u16(m.flags, &central); u16(0, &central)
            u16(0x6000, &central); u16(0x5A67, &central)
            u32(crc, &central); u32(UInt32(m.data.count), &central); u32(UInt32(m.data.count), &central)
            u16(UInt16(name.count), &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(UInt32(m.unixMode) << 16, &central); u32(offset, &central)
            central.append(contentsOf: name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out)
        u16(UInt16(members.count), &out); u16(UInt16(members.count), &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }

    func write(to url: URL) throws { try build().write(to: url) }
}

@Suite struct ArchivePathTests {
    @Test func rejectsTraversalAndAbsoluteNames() {
        #expect(ArchivePath.problem("../evil.txt") == .parentReference)
        #expect(ArchivePath.problem("dir/../../evil.txt") == .parentReference)
        #expect(ArchivePath.problem("a/..") == .parentReference)
        #expect(ArchivePath.problem("/etc/passwd") == .absolute)
        #expect(ArchivePath.problem("C:\\Windows\\x") == .absolute)
        #expect(ArchivePath.problem("c:/x") == .absolute)
        #expect(ArchivePath.problem("") == .empty)
        #expect(ArchivePath.problem("./") == .empty)
        #expect(ArchivePath.problem("a\u{0}b") == .invalidCharacter)
        #expect(ArchivePath.problem(String(repeating: "x", count: 256)) == .tooLong)
    }

    @Test func cleansHarmlessNames() {
        #expect(ArchivePath.components("./a//b/") == ["a", "b"])
        #expect(ArchivePath.components("top/./sub dir/x.txt") == ["top", "sub dir", "x.txt"])
        #expect(ArchivePath.components("..hidden/...") == ["..hidden", "..."])
        #expect(ArchivePath.components("a:b") == ["a:b"])   // not a drive letter
    }

    @Test func linkTargetsMustStayInside() {
        #expect(ArchivePath.linkStaysInside(entry: ["a", "l"], target: "../b"))
        #expect(ArchivePath.linkStaysInside(entry: ["a", "l"], target: "./x/../y"))
        #expect(!ArchivePath.linkStaysInside(entry: ["l"], target: "../outside"))
        #expect(!ArchivePath.linkStaysInside(entry: ["a", "l"], target: "/etc"))
        #expect(!ArchivePath.linkStaysInside(entry: ["a", "l"], target: ""))
        #expect(!ArchivePath.linkStaysInside(entry: ["a", "b", "l"], target: "../../../x"))
        // Inside a subfolder being extracted on its own, a link may not climb above that folder.
        #expect(!ArchivePath.linkStaysInside(entry: ["top", "l"], target: "../x", base: ["top"]))
        #expect(ArchivePath.linkStaysInside(entry: ["top", "sub", "l"], target: "../x", base: ["top"]))
    }
}

@Suite struct BsdtarListingTests {
    let now = Date(timeIntervalSince1970: 1_794_085_200)   // 2026-11-07
    let utc = TimeZone(identifier: "UTC")!

    @Test func parsesFilesFoldersAndLinks() throws {
        let text = """
        drwxr-xr-x  0 501    0           0 Nov  7 16:00 top/
        -rw-r--r--  0 501    0           6 Nov  7 16:00 top/a file.txt
        lrwxr-xr-x  0 0      0           0 Nov  7 16:00 top/link -> a file.txt
        hrw-r--r--  0 501    0           0 Nov  7 16:08 hl/two link to hl/one
        -rw-r--r--  0 501    0           5 Nov  7 16:00 top/sub dir/new\\nline.txt
        -rw-r--r--  0 501    0           3 Mar  1  2019 top/caf\\303\\251.txt
        crw-r--r--  0 0      0         3,1 Nov  7 16:00 dev/null
        prw-r--r--  0 0      0           0 Nov  7 16:00 fifo
        -rw-r--r--  0 501    0          12 Nov  7 16:00   leading spaces
        not a listing line
        """
        let result = BsdtarListing.parse(text, now: now, timeZone: utc)
        #expect(result.malformedLines == 1)
        let e = result.entries
        #expect(e.count == 9)
        #expect(e[0].kind == .directory && e[0].rawPath == "top/" && e[0].path == "top")
        #expect(e[1].kind == .file && e[1].rawPath == "top/a file.txt" && e[1].size == 6)
        #expect(e[2].kind == .symlink && e[2].rawPath == "top/link" && e[2].linkTarget == "a file.txt")
        #expect(e[3].kind == .hardlink && e[3].rawPath == "hl/two" && e[3].linkTarget == "hl/one")
        #expect(e[4].rawPath == "top/sub dir/new\nline.txt")
        #expect(e[5].rawPath == "top/café.txt")
        #expect(e[6].kind == .special && e[7].kind == .special)
        #expect(e[8].rawPath == "  leading spaces")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let recent = try #require(e[1].modified)
        #expect(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: recent)
                == DateComponents(year: 2026, month: 11, day: 7, hour: 16, minute: 0))
        let old = try #require(e[5].modified)
        #expect(calendar.component(.year, from: old) == 2019)
    }

    @Test func recentDatesInferTheYear() throws {
        // "Dec 20 10:00" seen in early January belongs to the previous year.
        let january = Date(timeIntervalSince1970: 1_767_312_000)   // 2026-01-02
        let entry = try #require(BsdtarListing.parseLine("-rw-r--r--  0 0 0 1 Dec 20 10:00 x", now: january, timeZone: utc))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(calendar.component(.year, from: try #require(entry.modified)) == 2025)
    }

    @Test func unescapeAndLiteralPatterns() {
        #expect(BsdtarListing.unescape("a\\\\b\\tc\\001") == "a\\b\tc\u{1}")
        #expect(BsdtarListing.unescape("plain") == "plain")
        #expect(BsdtarListing.literalPattern("sub/[b]*?.txt") == "sub/\\[b\\]\\*\\?.txt")
        #expect(BsdtarListing.literalPattern("we\\ird/") == "we\\\\ird")
    }
}

@Suite struct ZipDirectoryTests {
    @Test func readsNamesSizesKindsAndFlags() throws {
        let fx = try Fixture()
        var zip = TestZip()
        zip.folder("top")
        zip.file("top/a.txt", "hello")
        zip.link("top/l", to: "a.txt")
        zip.members.append(.init(name: "secret.txt", data: Data("x".utf8), flags: 0x0801))
        zip.members.append(.init(name: "", data: Data("y".utf8), flags: 0, nameBytes: [0x63, 0x61, 0x66, 0x82, 0x2E, 0x74]))   // "café.t" in CP437
        zip.file("dos\\path.txt")
        zip.file("__MACOSX/top/._a.txt")
        try zip.write(to: fx.url("t.zip"))

        let entries = try ZipDirectory.read(fx.url("t.zip"))
        #expect(entries.map(\.rawPath) == ["top/", "top/a.txt", "top/l", "secret.txt", "café.t", "dos/path.txt"])
        #expect(entries[0].kind == .directory)
        #expect(entries[1].kind == .file && entries[1].size == 5 && entries[1].compressedSize == 5)
        #expect(entries[2].kind == .symlink)
        #expect(entries[3].isEncrypted && !entries[1].isEncrypted)
        #expect(entries[1].modified != nil)
    }

    @Test func emptyZipIsValid() throws {
        let fx = try Fixture()
        #expect(ArchiveNaming.emptyZip.count == 22)
        try ArchiveNaming.emptyZip.write(to: fx.url("e.zip"))
        #expect(try ZipDirectory.read(fx.url("e.zip")).isEmpty)
        // libarchive agrees that it's a valid, empty archive.
        let listing = try ArchiveTool.listWithBsdtar(fx.url("e.zip"))
        #expect(listing.entries.isEmpty && listing.warning == nil)
    }

    @Test func rejectsNonZip() throws {
        let fx = try Fixture()
        try fx.file("x.zip", String(repeating: "not a zip ", count: 10))
        #expect(throws: ZipDirectory.ReadError.notZip) { try ZipDirectory.read(fx.url("x.zip")) }
    }
}

@Suite struct ArchiveIndexTests {
    @Test func synthesizesFoldersAndHidesUnsafeNames() throws {
        let entries = [
            ArchiveEntry(rawPath: "top/a.txt", kind: .file, size: 3),
            ArchiveEntry(rawPath: "top/sub/b.txt", kind: .file, size: 4),
            ArchiveEntry(rawPath: "./top/.hidden", kind: .file, size: 1),
            ArchiveEntry(rawPath: "../evil.txt", kind: .file, size: 1),
            ArchiveEntry(rawPath: "/abs.txt", kind: .file, size: 1),
        ]
        let index = ArchiveIndex(entries: entries)
        #expect(index.unsafeCount == 2)
        #expect(index.entryCount == 3)
        #expect(index.totalSize == 8)
        #expect(index.children(of: "")?.map(\.name) == ["top"])
        #expect(Set(index.children(of: "top")?.map(\.name) ?? []) == ["a.txt", "sub", ".hidden"])
        #expect(index.children(of: "top/sub")?.map(\.name) == ["b.txt"])
        #expect(index.children(of: "nope") == nil)
        #expect(index.node(at: "top/sub")?.isDirectory == true)

        let archive = URL(fileURLWithPath: "/tmp/x.zip")
        let items = try #require(index.items(in: "top", archive: archive, includeHidden: false))
        #expect(Set(items.map(\.name)) == ["a.txt", "sub"])
        let sub = try #require(items.first { $0.name == "sub" })
        #expect(sub.isFolder && sub.size == nil && sub.url.path == "/tmp/x.zip/top/sub")
        #expect(items.first { $0.name == "a.txt" }?.size == 3)
    }

    @Test func itemRefsMapBackToTheArchive() throws {
        let fx = try Fixture()
        try fx.file("in/t.zip")
        let ref = try #require(ArchiveItemRef(url: fx.url("in/t.zip/top/sub dir/a.txt")))
        #expect(ref.archive == fx.url("in/t.zip").standardizedFileURL)
        #expect(ref.innerPath == "top/sub dir/a.txt")
        #expect(ref.name == "a.txt" && ref.parentPath == "top/sub dir")
        #expect(ArchiveItemRef(url: fx.url("in/t.zip")) == nil)              // the archive itself
        #expect(ArchiveItemRef(url: fx.url("in/missing.txt/x")) == nil)      // existing ancestor is a folder
    }

    @Test func typeNames() {
        #expect(ArchiveIndex.typeDescription(name: "a.zip", isDirectory: false) == "Compressed (zipped) Folder")
        #expect(ArchiveIndex.typeDescription(name: "noext", isDirectory: false) == "File")
        #expect(!ArchiveIndex.typeDescription(name: "a.txt", isDirectory: false).isEmpty)
    }
}

@Suite struct ExtractionPlannerTests {
    let hostile = [
        ArchiveEntry(rawPath: "good.txt", kind: .file, size: 5),
        ArchiveEntry(rawPath: "dir/", kind: .directory),
        ArchiveEntry(rawPath: "dir/inner.txt", kind: .file, size: 6),
        ArchiveEntry(rawPath: "../evil.txt", kind: .file, size: 8),
        ArchiveEntry(rawPath: "dir/../../evil2.txt", kind: .file, size: 9),
        ArchiveEntry(rawPath: "/abs.txt", kind: .file, size: 9),
        ArchiveEntry(rawPath: "badlink", kind: .symlink, linkTarget: "/etc"),
        ArchiveEntry(rawPath: "badlink2", kind: .symlink, linkTarget: "../../outside"),
        ArchiveEntry(rawPath: "oklink", kind: .symlink, linkTarget: "dir/inner.txt"),
        ArchiveEntry(rawPath: "badlink/through.txt", kind: .file, size: 1),
        ArchiveEntry(rawPath: "hard", kind: .hardlink, linkTarget: "../etc/passwd"),
        ArchiveEntry(rawPath: "fifo", kind: .special),
        ArchiveEntry(rawPath: "Good.txt", kind: .file, size: 1),
        ArchiveEntry(rawPath: "empty/", kind: .directory),
    ]

    @Test func hostileArchiveKeepsOnlySafeEntries() {
        let plan = ExtractionPlanner.plan(entries: hostile, roots: [""])
        #expect(plan.included.map(\.rawPath) == ["good.txt", "dir/inner.txt", "oklink"])
        #expect(plan.folders == ["dir", "empty"])
        let reasons = Dictionary(plan.rejected.map { ($0.entry.rawPath, $0.reason) }, uniquingKeysWith: { a, _ in a })
        #expect(reasons["../evil.txt"] == .unsafePath)
        #expect(reasons["dir/../../evil2.txt"] == .unsafePath)
        #expect(reasons["/abs.txt"] == .unsafePath)
        #expect(reasons["badlink"] == .linkOutside)
        #expect(reasons["badlink2"] == .linkOutside)
        #expect(reasons["badlink/through.txt"] == .insideNonFolder)
        #expect(reasons["hard"] == .linkOutside)
        #expect(reasons["fifo"] == .specialFile)
        #expect(reasons["Good.txt"] == .caseDuplicate)
        // Rejected entries are present, so every included file is named on its own.
        #expect(plan.patterns == ["good.txt", "dir/inner.txt", "oklink"])
        #expect(plan.totalBytes == 11)
    }

    @Test func cleanArchiveUsesWholeTreePatterns() {
        let clean = [
            ArchiveEntry(rawPath: "top/", kind: .directory),
            ArchiveEntry(rawPath: "top/a [1].txt", kind: .file, size: 2),
            ArchiveEntry(rawPath: "top/sub/b.txt", kind: .file, size: 3),
            ArchiveEntry(rawPath: "other.txt", kind: .file, size: 4),
        ]
        let all = ExtractionPlanner.plan(entries: clean, roots: [""])
        #expect(all.patterns.isEmpty && all.rejected.isEmpty && all.totalBytes == 9)
        let some = ExtractionPlanner.plan(entries: clean, roots: ["top/a [1].txt", "top/sub"], base: "top")
        #expect(some.patterns == ["top/a \\[1\\].txt", "top/sub"])
        #expect(some.included.map(\.rawPath) == ["top/a [1].txt", "top/sub/b.txt"])
        #expect(some.totalBytes == 5)
    }

    @Test func linksMayNotLeaveTheExtractedFolder() {
        let entries = [
            ArchiveEntry(rawPath: "top/sub/l", kind: .symlink, linkTarget: "../../x"),
            ArchiveEntry(rawPath: "top/sub/ok", kind: .symlink, linkTarget: "../y"),
        ]
        let plan = ExtractionPlanner.plan(entries: entries, roots: ["top/sub"], base: "top")
        #expect(plan.included.map(\.rawPath) == ["top/sub/ok"])
        #expect(plan.rejected.map(\.reason) == [.linkOutside])
    }

    @Test func fileWithChildrenIsRejected() {
        let entries = [ArchiveEntry(rawPath: "a", kind: .file, size: 1), ArchiveEntry(rawPath: "a/b", kind: .file, size: 1)]
        let plan = ExtractionPlanner.plan(entries: entries, roots: [""])
        #expect(plan.included.isEmpty)
        #expect(Set(plan.rejected.map(\.reason)) == [.notAFolder, .insideNonFolder])
    }
}

@Suite struct ExpansionPolicyTests {
    @Test func verdicts() {
        let p = ExpansionPolicy()
        let gb: Int64 = 1 << 30
        #expect(p.check(archiveSize: 10 << 20, totalBytes: 50 << 20, freeSpace: 100 * gb) == .ok)
        // 1 MB of zeros expanding to 2 GB: a likely zip bomb.
        if case .suspicious(let ratio) = p.check(archiveSize: 1 << 20, totalBytes: 2 * gb, freeSpace: 100 * gb) {
            #expect(ratio > 2000)
        } else { Issue.record("expected suspicious") }
        // Small archives of zeros are harmless whatever the ratio.
        #expect(p.check(archiveSize: 1_000, totalBytes: 100 << 20, freeSpace: 100 * gb) == .ok)
        #expect(p.check(archiveSize: gb, totalBytes: 2 * gb, freeSpace: gb) == .noSpace(needed: 2 * gb, available: gb))
        #expect(p.check(archiveSize: gb, totalBytes: 2 << 40, freeSpace: nil) == .tooLarge(total: 2 << 40))
        #expect(p.writeLimit(declared: 0) == 64 << 20)
        #expect(p.writeLimit(declared: 10 * gb) == 11 * gb)
    }
}

@Suite struct ArchiveNamingTests {
    @Test func formatsAndBaseNames() {
        #expect(ArchiveFormat.detect(name: "a.ZIP") == .zip)
        #expect(ArchiveFormat.detect(name: "b.tar.gz") == .tarGzip)
        #expect(ArchiveFormat.detect(name: "b.tgz") == .tarGzip)
        #expect(ArchiveFormat.detect(name: "c.tar.bz2") == .tarBzip2)
        #expect(ArchiveFormat.detect(name: "d.txz") == .tarXz)
        #expect(ArchiveFormat.detect(name: "e.7z") == .sevenZip)
        #expect(ArchiveFormat.detect(name: "f.rar") == .rar)
        #expect(ArchiveFormat.detect(name: "g.iso") == .iso)
        #expect(ArchiveFormat.detect(name: "h.cpio") == .cpio)
        #expect(ArchiveFormat.detect(name: ".zip") == nil)
        #expect(ArchiveFormat.detect(name: "notes.txt") == nil)
        #expect(ArchiveFormat.baseName(of: "backup.tar.gz") == "backup")
        #expect(ArchiveFormat.baseName(of: "Photos.zip") == "Photos")
        #expect(ArchiveFormat.baseName(of: "v1.2.zip") == "v1.2")
    }

    @Test func archiveNamesFollowWindows() {
        let none: (String) -> Bool = { _ in false }
        #expect(ArchiveNaming.archiveName(for: "report.docx", isFolder: false, format: .zip, isTaken: none) == "report.zip")
        #expect(ArchiveNaming.archiveName(for: "my.photos", isFolder: true, format: .zip, isTaken: none) == "my.photos.zip")
        #expect(ArchiveNaming.archiveName(for: ".zshrc", isFolder: false, format: .sevenZip, isTaken: none) == ".zshrc.7z")
        #expect(ArchiveNaming.archiveName(for: "Docs", isFolder: true, format: .tar, isTaken: none) == "Docs.tar")
        let taken: Set = ["report.zip", "report (2).zip"]
        #expect(ArchiveNaming.archiveName(for: "report.docx", isFolder: false, format: .zip, isTaken: taken.contains) == "report (3).zip")
        #expect(ArchiveNaming.uniqueName("a.tar.gz", isTaken: { $0 == "a.tar.gz" }) == "a (2).tar.gz")
        #expect(ArchiveNaming.newZipName(isTaken: none) == "New Compressed (zipped) Folder.zip")
        #expect(ArchiveNaming.newZipName(isTaken: { $0 == "New Compressed (zipped) Folder.zip" }) == "New Compressed (zipped) Folder (2).zip")
        #expect(ArchiveNaming.extractionFolder(for: URL(fileURLWithPath: "/x/backup.tar.gz")).path == "/x/backup")
    }

    @Test func hdiutilPlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk9s1</string><key>mount-point</key><string>/Volumes/CD</string></dict>
        </array></dict></plist>
        """
        #expect(DiskImage.mountPoints(fromPlist: Data(plist.utf8)) == [URL(fileURLWithPath: "/Volumes/CD")])
        #expect(DiskImage.isDiskImage(URL(fileURLWithPath: "/a/b.DMG")))
    }
}

/// End-to-end with the system's bsdtar and ditto, in disposable folders.
@Suite struct ArchiveToolTests {
    func tree(_ fx: Fixture) throws {
        try fx.file("src/top/a file.txt", "hello")
        try fx.file("src/top/sub dir/deep/[b]*.txt", "x")
        try fx.file("src/top/café.txt", "é")
        try fx.folder("src/top/empty")
        try FileManager.default.createSymbolicLink(atPath: fx.url("src/top/link").path, withDestinationPath: "a file.txt")
        try fx.file("src/second.txt", "2")
    }

    func extract(_ archive: URL, roots: [String] = [""], base: String = "", into fx: Fixture, _ name: String) throws -> (URL, ExtractionPlanner.Plan) {
        let listing = try ArchiveTool.listWithBsdtar(archive)
        let plan = ExtractionPlanner.plan(entries: listing.entries, roots: roots, base: base)
        let job = try fx.folder("\(name)-job")
        let staging = try fx.folder("\(name)-job/content")
        try ArchiveTool.extract(archive, plan: plan, into: staging, process: ToolProcess())
        _ = job
        return (staging, plan)
    }

    @Test func zipRoundTripWithDitto() throws {
        let fx = try Fixture()
        try tree(fx)
        let zip = fx.url("out/top.zip")
        try fx.folder("out")
        var count = 0
        try ArchiveTool.create(format: .zip, sources: [fx.url("src/top")], output: zip, process: ToolProcess()) { count += 1 }
        #expect(count >= 3)

        let listing = try ArchiveTool.list(zip)
        let index = ArchiveIndex(entries: listing.entries)
        #expect(Set(index.children(of: "top")?.map(\.name) ?? []) == ["a file.txt", "sub dir", "café.txt", "empty", "link"])
        let a = try #require(index.node(at: "top/a file.txt")?.entry)
        #expect(a.size == 5 && a.compressedSize != nil)

        let (staging, plan) = try extract(zip, into: fx, "all")
        #expect(plan.rejected.isEmpty)
        #expect(try String(contentsOf: staging.appendingPathComponent("top/a file.txt"), encoding: .utf8) == "hello")
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("top/sub dir/deep/[b]*.txt").path))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("top/empty").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("top/link").path) == "a file.txt")
        #expect(ExtractionVerifier.verify(staging: staging, base: [], quarantine: nil).removed.isEmpty)
    }

    @Test func singleFileZipHasNoParentFolder() throws {
        let fx = try Fixture()
        try tree(fx)
        try fx.folder("out")
        try ArchiveTool.create(format: .zip, sources: [fx.url("src/second.txt")], output: fx.url("out/s.zip"), process: ToolProcess())
        #expect(try ArchiveTool.list(fx.url("out/s.zip")).entries.map(\.rawPath) == ["second.txt"])
    }

    @Test func multipleItems7zAndTar() throws {
        let fx = try Fixture()
        try tree(fx)
        try fx.folder("out")
        for format in [ArchiveCreateFormat.zip, .sevenZip, .tar] {
            let out = fx.url("out/many.\(format.fileExtension)")
            try ArchiveTool.create(format: format, sources: [fx.url("src/top"), fx.url("src/second.txt")], output: out, process: ToolProcess())
            let names = Set(try ArchiveTool.listWithBsdtar(out).entries.compactMap(\.path))
            #expect(names.contains("top/a file.txt") && names.contains("second.txt"), "\(format)")
            #expect(!names.contains { $0.contains("._") }, "no AppleDouble members in \(format)")
        }
        // Selected subtree only, with brackets that must not act as wildcards.
        let (staging, _) = try extract(fx.url("out/many.7z"), roots: ["top/sub dir"], base: "top", into: fx, "sub")
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("top/sub dir/deep/[b]*.txt").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("top/a file.txt").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("second.txt").path))
    }

    @Test func hostileZipExtractsOnlySafeEntries() throws {
        let fx = try Fixture()
        var zip = TestZip()
        zip.file("good.txt", "fine")
        zip.file("dir/inner.txt", "inner")
        zip.file("../evil.txt", "escaped")
        zip.file("dir/../../evil2.txt", "escaped")
        zip.file("/abs.txt", "absolute")
        zip.link("badlink", to: "/etc")
        zip.link("badlink2", to: "../../outside")
        zip.link("oklink", to: "dir/inner.txt")
        zip.file("badlink/through.txt", "through")
        try fx.folder("arch")
        try zip.write(to: fx.url("arch/evil.zip"))

        let (staging, plan) = try extract(fx.url("arch/evil.zip"), into: fx, "evil")
        #expect(plan.rejected.count == 6)
        let found = (FileManager.default.subpaths(atPath: staging.path) ?? []).sorted()
        #expect(found == ["dir", "dir/inner.txt", "good.txt", "oklink"])
        // Nothing escaped next to or above the staging folder.
        #expect(fx.names("evil-job") == ["content"])
        #expect(!fx.exists("evil.txt") && !fx.exists("evil2.txt") && !fx.exists("outside"))
    }

    @Test func verifierRemovesEscapingLinksAndSpecialFiles() throws {
        let fx = try Fixture()
        let staging = try fx.folder("stage")
        try fx.file("stage/ok.txt", "ok")
        try FileManager.default.createSymbolicLink(atPath: fx.url("stage/out").path, withDestinationPath: "../../x")
        try FileManager.default.createSymbolicLink(atPath: fx.url("stage/abs").path, withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: fx.url("stage/in").path, withDestinationPath: "ok.txt")
        #expect(mkfifo(fx.url("stage/pipe").path, 0o644) == 0)
        #expect(chmod(fx.url("stage/ok.txt").path, 0o4755) == 0)
        let quarantine = Data("0081;00000000;Test;".utf8)
        let report = ExtractionVerifier.verify(staging: staging, base: [], quarantine: quarantine)
        #expect(Set(report.removed) == ["out", "abs", "pipe"])
        #expect(fx.names("stage") == ["in", "ok.txt"])
        var info = stat()
        stat(fx.url("stage/ok.txt").path, &info)
        #expect(info.st_mode & S_ISUID == 0)
        #expect(ExtractionVerifier.quarantine(of: fx.url("stage/ok.txt")) == quarantine)
    }

    @Test func cancellationStopsTheTool() throws {
        let process = ToolProcess()
        process.cancel()
        #expect(throws: CancellationError.self) { try process.run("/bin/sleep", ["5"]) }
    }
}
