import Foundation
import Testing
@testable import ArborCore

/// RAR through Arbor's real archive code, with stored RAR4 and RAR5 archives built by `TestRar` (FE-167).
@Suite struct RarArchiveTests {
    typealias Format = TestRar.Format

    private func rarURL(_ fx: Fixture, _ rar: TestRar, name: String = "t.rar") throws -> URL {
        let url = fx.url(name)
        try rar.write(to: url)
        return url
    }

    /// Lists, plans and extracts as the extraction job does, into a staging folder inside `<name>-job`.
    private func extract(_ archive: URL, roots: [String] = [""], base: String = "", in fx: Fixture,
                         _ name: String = "out") throws -> (staging: URL, plan: ExtractionPlanner.Plan) {
        let (listing, rewrites) = try ArchiveTool.extractionListing(archive)
        let plan = ExtractionPlanner.plan(entries: listing.entries, roots: roots, base: base)
        try fx.folder("\(name)-job")
        let staging = try fx.folder("\(name)-job/content")
        try ArchiveTool.extract(archive, plan: plan, into: staging, process: ToolProcess(), rewritesBackslashes: rewrites)
        return (staging, plan)
    }

    private func subpaths(_ folder: URL) -> [String] { (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted() }

    // MARK: Listing, dates and bytes

    @Test(arguments: Format.allCases) func listsNestedFoldersAndSizes(_ format: Format) throws {
        let fx = try Fixture()
        var rar = TestRar(format)
        rar.folder("top")
        rar.file("top/a file.txt", "hello")
        rar.file("top/sub/deep/[b]*.txt", "x")
        rar.folder("top/empty")
        let listing = try ArchiveTool.list(rarURL(fx, rar))
        #expect(listing.warning == nil && !listing.entries.contains(where: \.isEncrypted))

        let index = ArchiveIndex(entries: listing.entries)
        #expect(index.children(of: "")?.map(\.name) == ["top"])
        #expect(Set(index.children(of: "top")?.map(\.name) ?? []) == ["a file.txt", "sub", "empty"])
        #expect(index.node(at: "top/sub")?.isDirectory == true && index.node(at: "top/sub")?.entry == nil)
        let file = try #require(index.node(at: "top/a file.txt")?.entry)
        #expect(file.kind == .file && file.size == 5)
        #expect(index.node(at: "top/empty")?.entry?.kind == .directory)
    }

    @Test(arguments: Format.allCases) func keepsUnicodeNames(_ format: Format) throws {
        let fx = try Fixture()
        var rar = TestRar(format)
        rar.members.append(.init(name: "café/日本.txt", content: Data("名前".utf8), unicodeName: format == .rar4))
        let url = try rarURL(fx, rar)
        #expect(try ArchiveTool.list(url).entries.map(\.rawPath) == ["café/日本.txt"])
        let (staging, _) = try extract(url, in: fx)
        #expect(try String(contentsOf: staging.appendingPathComponent("café/日本.txt"), encoding: .utf8) == "名前")
    }

    @Test(arguments: Format.allCases) func datesComeFromTheHeaders(_ format: Format) throws {
        let fx = try Fixture()
        // Within six months bsdtar prints the minute; older dates only the day.
        let recent = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 2).rounded(.down) * 2 - 7_200)
        var rar = TestRar(format)
        rar.file("old.txt")
        rar.file("recent.txt", modified: recent)
        let url = try rarURL(fx, rar)
        let listing = try ArchiveTool.list(url)
        func parts(_ date: Date?, _ units: Set<Calendar.Component>) -> DateComponents? { date.map { Calendar.current.dateComponents(units, from: $0) } }

        let old = try #require(listing.entries.first { $0.rawPath == "old.txt" })
        #expect(parts(old.modified, [.year, .month, .day]) == parts(TestRar.defaultDate, [.year, .month, .day]))
        let new = try #require(listing.entries.first { $0.rawPath == "recent.txt" })
        let minute: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        #expect(parts(new.modified, minute) == parts(recent, minute))

        let (staging, _) = try extract(url, in: fx)
        func onDisk(_ name: String) throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: staging.appendingPathComponent(name).path)[.modificationDate] as? Date
        }
        #expect(try onDisk("old.txt") == TestRar.defaultDate)
        #expect(try onDisk("recent.txt") == recent)
    }

    @Test(arguments: Format.allCases) func extractedBytesMatch(_ format: Format) throws {
        let fx = try Fixture()
        let binary = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 ^ $0 >> 8) })
        var rar = TestRar(format)
        rar.folder("top")
        rar.file("top/a.txt", "hello rar\n")
        rar.members.append(.init(name: "top/sub/data.bin", content: binary))
        rar.file("top/sub/[b]*.txt", "brackets")
        rar.members.append(.init(name: "top/zero.txt"))
        rar.folder("top/empty")
        let url = try rarURL(fx, rar)

        let (staging, plan) = try extract(url, in: fx)
        #expect(plan.rejected.isEmpty && plan.totalBytes == 10 + 300_000 + 8)
        #expect(subpaths(staging) == ["top", "top/a.txt", "top/empty", "top/sub", "top/sub/[b]*.txt", "top/sub/data.bin", "top/zero.txt"])
        #expect(try Data(contentsOf: staging.appendingPathComponent("top/a.txt")) == Data("hello rar\n".utf8))
        #expect(try Data(contentsOf: staging.appendingPathComponent("top/sub/data.bin")) == binary)
        #expect(try Data(contentsOf: staging.appendingPathComponent("top/zero.txt")).isEmpty)
        #expect(ExtractionVerifier.verify(staging: staging, base: [], quarantine: nil).removed.isEmpty)

        // One folder only, with brackets that must not act as wildcards.
        let (part, _) = try extract(url, roots: ["top/sub"], base: "top", in: fx, "part")
        #expect(subpaths(part) == ["top", "top/sub", "top/sub/[b]*.txt", "top/sub/data.bin"])
    }

    @Test(arguments: Format.allCases) func anArchiveWithNoMembersIsEmptyNotAnError(_ format: Format) throws {
        let fx = try Fixture()
        let listing = try ArchiveTool.list(rarURL(fx, TestRar(format)))
        #expect(listing.entries.isEmpty && listing.warning == nil)
        #expect(ExtractionPlanner.plan(entries: listing.entries, roots: [""]).isEmpty)
    }

    @Test(arguments: Format.allCases) func serviceBlocksDontDisturbTheWalk(_ format: Format) throws {
        let fx = try Fixture()
        var rar = TestRar(format)
        rar.hasServiceBlock = true
        rar.file("a.txt")
        let url = try rarURL(fx, rar)
        #expect(RarHeaders.traits(of: url) == RarHeaders.Traits())
        #expect(try ArchiveTool.list(url).entries.map(\.rawPath) == ["a.txt"])
    }

    // MARK: Hostile names

    @Test(arguments: Format.allCases) func hostileRarExtractsOnlySafeEntries(_ format: Format) throws {
        let fx = try Fixture()
        var rar = TestRar(format)
        rar.file("good.txt", "fine")
        rar.file("dir/inner.txt", "inner")
        rar.file("../escape.txt", "escaped")
        rar.file("dir/../../evil2.txt", "escaped")
        rar.file(fx.url("abs-escape.txt").path, "absolute")
        rar.link("badlink", to: "/etc")
        rar.link("badlink2", to: "../../outside")
        rar.link("oklink", to: "dir/inner.txt")
        rar.file("badlink/through.txt", "through")
        rar.fifo("pipe")
        try fx.folder("arch")
        let url = try rarURL(fx, rar, name: "arch/evil.rar")

        let index = ArchiveIndex(entries: try ArchiveTool.list(url).entries)
        #expect(index.unsafeCount == 3)
        #expect(index.node(at: "good.txt") != nil && index.node(at: "../escape.txt") == nil)

        let (staging, plan) = try extract(url, in: fx, "evil")
        #expect(plan.rejected.count == 7)
        #expect(subpaths(staging) == ["dir", "dir/inner.txt", "good.txt", "oklink"])
        #expect(try String(contentsOf: staging.appendingPathComponent("good.txt"), encoding: .utf8) == "fine")
        #expect(fx.names("evil-job") == ["content"])
        #expect(!fx.exists("escape.txt") && !fx.exists("evil2.txt") && !fx.exists("abs-escape.txt") && !fx.exists("outside"))
    }

    @Test func rar4WindowsNamesUseBackslashesAndStayInside() throws {
        let fx = try Fixture()
        var rar = TestRar(.rar4)
        rar.members.append(.init(name: "top\\win.txt", content: Data("win".utf8), windowsHost: true))
        rar.members.append(.init(name: "top\\dir", mode: 0o040755, windowsHost: true))
        rar.members.append(.init(name: "..\\escape.txt", content: Data("escaped".utf8), windowsHost: true))
        rar.members.append(.init(name: "C:\\abs.txt", content: Data("absolute".utf8), windowsHost: true))
        let (staging, plan) = try extract(rarURL(fx, rar), in: fx)
        #expect(plan.rejected.map(\.reason) == [.unsafePath, .unsafePath])
        #expect(subpaths(staging) == ["top", "top/dir", "top/win.txt"])
        #expect(fx.names("out-job") == ["content"] && !fx.exists("escape.txt"))
    }

    @Test func rar5BackslashesAreOrdinaryCharacters() throws {
        // RAR5 names use "/", so libarchive keeps "\\" as part of a single, harmless name.
        let fx = try Fixture()
        var rar = TestRar(.rar5)
        rar.members.append(.init(name: "..\\escape.txt", content: Data("inside".utf8), windowsHost: true))
        let (staging, plan) = try extract(rarURL(fx, rar), in: fx)
        #expect(plan.rejected.isEmpty && subpaths(staging) == ["..\\escape.txt"])
        #expect(fx.names("out-job") == ["content"] && !fx.exists("escape.txt"))
    }

    @Test func legacyNamesThatArentUTF8FailWithTheToolsMessage() throws {
        let fx = try Fixture()
        var rar = TestRar(.rar4)
        rar.members.append(.init(name: "", content: Data("x".utf8), windowsHost: true, rawName: [0x63, 0x61, 0x66, 0xE9, 0x2E, 0x74]))
        let url = try rarURL(fx, rar)
        #expect(try ArchiveTool.list(url).entries.count == 1)
        #expect(throws: ArchiveError.self) { try extract(url, in: fx) }
        #expect(fx.names("out-job/content").isEmpty)
    }

    // MARK: Damage

    /// Bytes up to the start of `name` (somewhere inside that member's header).
    private func prefix(of data: Data, before name: String) throws -> Data {
        data.prefix(upTo: try #require(data.range(of: Data(name.utf8))).lowerBound)
    }

    private func sample(_ format: Format) -> TestRar {
        var rar = TestRar(format)
        rar.file("first.txt", "first member")
        rar.file("second.bin", String(repeating: "0123456789", count: 20))
        return rar
    }

    @Test(arguments: Format.allCases) func truncatedFilesGiveTheNormalErrors(_ format: Format) throws {
        let whole = sample(format).build()
        let unreadable: [(String, Data)] = [
            ("inside the signature", whole.prefix(5)),
            ("only the signature", whole.prefix(format == .rar4 ? 7 : 8)),
            ("inside the main header", whole.prefix(format == .rar4 ? 11 : 12)),
            ("inside the first member's header", try prefix(of: whole, before: "first.txt")),
        ]
        for (label, bytes) in unreadable {
            let fx = try Fixture()
            let url = fx.url("cut.rar")
            try bytes.write(to: url)
            #expect(throws: ArchiveError.self, "\(label)") {
                _ = try ArchiveTool.list(url)
            }
            #expect(throws: ArchiveError.self, "\(label)") { try extract(url, in: fx) }
        }

        let partial: [(String, Data)] = [
            ("inside the second member's header", try prefix(of: whole, before: "second.bin")),
            ("inside the second member's data", whole.prefix(whole.count - 100)),
            ("inside the end block", whole.prefix(whole.count - 3)),
        ]
        for (label, bytes) in partial {
            let fx = try Fixture()
            let url = fx.url("cut.rar")
            try bytes.write(to: url)
            let listing = try ArchiveTool.list(url)
            #expect(listing.entries.first?.rawPath == "first.txt", "\(label)")
            #expect(listing.warning != nil, "\(label)")
            #expect(throws: ArchiveError.self, "\(label)") { try extract(url, in: fx) }
            #expect(fx.names("out-job/content").isEmpty, "\(label)")
        }
    }

    @Test(arguments: Format.allCases) func corruptHeadersGiveTheNormalErrors(_ format: Format) throws {
        let whole = sample(format).build()
        func flipped(_ name: String) throws -> Data {
            var bytes = whole
            bytes[try #require(whole.range(of: Data(name.utf8))).lowerBound] ^= 0xFF
            return bytes
        }
        let fx = try Fixture()
        try flipped("first.txt").write(to: fx.url("first.rar"))
        #expect(throws: ArchiveError.unreadable("Header CRC error")) { try ArchiveTool.list(fx.url("first.rar")) }
        #expect(throws: ArchiveError.self) { try extract(fx.url("first.rar"), in: fx, "first") }

        try flipped("second.bin").write(to: fx.url("second.rar"))
        let listing = try ArchiveTool.list(fx.url("second.rar"))
        #expect(listing.entries.map(\.rawPath) == ["first.txt"] && listing.warning == "Header CRC error")
        #expect(throws: ArchiveError.toolFailed("Header CRC error")) { try extract(fx.url("second.rar"), in: fx, "second") }
    }

    @Test func notARarAndTheOldestSignatureAreUnreadable() throws {
        let fx = try Fixture()
        try fx.file("plain.rar", String(repeating: "not an archive ", count: 8))
        #expect(throws: ArchiveError.self) { try ArchiveTool.list(fx.url("plain.rar")) }
        try (Data("RE~^".utf8) + Data(repeating: 0x78, count: 40)).write(to: fx.url("old.rar"))
        #expect(throws: ArchiveError.self) { try ArchiveTool.list(fx.url("old.rar")) }
    }

    @Test(arguments: Format.allCases) func unpackFailuresReportTheToolsMessage(_ format: Format) throws {
        // Compressed data can't be built without the rar tool; garbage must still fail cleanly.
        let fx = try Fixture()
        var rar = TestRar(format)
        rar.members.append(.init(name: "c.txt", content: Data(repeating: 0xA5, count: 64), method: 3, unpackedSize: 200))
        let url = try rarURL(fx, rar)
        #expect(try ArchiveTool.list(url).entries.map(\.size) == [200])
        #expect(throws: ArchiveError.self) { try extract(url, in: fx) }
    }

    // MARK: Encryption and volumes

    @Test(arguments: Format.allCases) func encryptedHeadersAreRefusedAsPasswordProtected(_ format: Format) throws {
        let fx = try Fixture()
        var rar = sample(format)
        rar.hasEncryptedHeaders = true
        let url = try rarURL(fx, rar)
        #expect(throws: ArchiveError.encrypted) { try ArchiveTool.list(url) }
        #expect(throws: ArchiveError.encrypted) { try ArchiveTool.extractionListing(url) }
    }

    @Test(arguments: Format.allCases) func encryptedMembersAreListedAndRefused(_ format: Format) throws {
        let fx = try Fixture()
        var rar = TestRar(format)
        rar.file("plain.txt", "readable")
        rar.members.append(.init(name: "secret.txt", content: Data("ciphertext".utf8), encrypted: true))
        let url = try rarURL(fx, rar)
        #expect(RarHeaders.traits(of: url).hasEncryptedMembers)

        let listing = try ArchiveTool.list(url)
        #expect(listing.entries.map(\.rawPath) == ["plain.txt", "secret.txt"] && listing.entries.allSatisfy(\.isEncrypted))
        #expect(ArchiveIndex(entries: listing.entries).encryptedCount == 2)
        let extraction = try ArchiveTool.extractionListing(url)
        #expect(ExtractionPlanner.plan(entries: extraction.listing.entries, roots: [""]).hasEncrypted)
    }

    @Test(arguments: Format.allCases) func multiVolumePartsAreRefusedWithAClearMessage(_ format: Format) throws {
        let fx = try Fixture()
        var flagged = TestRar(format)
        flagged.isVolume = true
        flagged.file("whole.txt")
        var continues = TestRar(format)
        continues.members.append(.init(name: "split.bin", content: Data("start".utf8), splitAfter: true, unpackedSize: 10))
        var continued = TestRar(format)
        continued.members.append(.init(name: "split.bin", content: Data("tail!".utf8), splitBefore: true))
        for (i, rar) in [flagged, continues, continued].enumerated() {
            let url = try rarURL(fx, rar, name: "part\(i).rar")
            for attempt in [{ _ = try ArchiveTool.list(url) }, { _ = try ArchiveTool.extractionListing(url) }] {
                #expect { try attempt() } throws: { ($0 as? ArchiveError)?.errorDescription?.contains("multi-volume") == true }
            }
        }
    }

    // MARK: Links and references (RAR5)

    @Test func rar5HardLinksAreReadAsHardLinks() throws {
        let fx = try Fixture()
        var rar = TestRar(.rar5)
        rar.file("good.txt", "fine")
        rar.members.append(.init(name: "same", redirect: (.hardLink, "good.txt")))
        rar.members.append(.init(name: "bad", redirect: (.hardLink, "../../etc/passwd")))
        let url = try rarURL(fx, rar)
        let entries = try ArchiveTool.list(url).entries
        #expect(entries.map(\.rawPath) == ["good.txt", "same", "bad"])
        #expect(entries.map(\.kind) == [.file, .hardlink, .hardlink])

        let (staging, plan) = try extract(url, in: fx)
        #expect(plan.rejected.map(\.reason) == [.linkOutside])
        #expect(subpaths(staging) == ["good.txt", "same"])
        #expect(try String(contentsOf: staging.appendingPathComponent("same"), encoding: .utf8) == "fine")
        #expect(fx.names("out-job") == ["content"])
    }

    @Test func aRar5FileNamedLikeAHardLinkStaysAFile() throws {
        let fx = try Fixture()
        var rar = TestRar(.rar5)
        rar.file("real.txt", "real")
        rar.members.append(.init(name: "h.txt", redirect: (.hardLink, "real.txt")))
        rar.members.append(.init(name: "bad", redirect: (.hardLink, "../../etc/passwd")))
        // Unrelated words, a real link's target, the phrase twice, and inside a folder.
        let plain = ["Shortcut link to report.txt", "x link to real.txt", "a link to b link to c", "sub/a link to b"]
        for name in plain { rar.file(name, name) }
        let url = try rarURL(fx, rar)
        let entries = try ArchiveTool.list(url).entries
        #expect(entries.filter { $0.kind == .hardlink }.map(\.rawPath) == ["h.txt", "bad"])
        #expect(entries.filter { $0.kind == .file }.map(\.rawPath) == ["real.txt"] + plain)
        #expect(entries.filter { plain.contains($0.rawPath) }.allSatisfy { $0.linkTarget == nil && $0.size != nil })

        // The rejected link makes the planner name every file one by one, so each name must match a member.
        let (staging, plan) = try extract(url, in: fx)
        #expect(plan.rejected.map(\.entry.rawPath) == ["bad"])
        #expect(subpaths(staging) == (["real.txt", "h.txt", "sub"] + plain).sorted())
        for name in plain {
            #expect(try String(contentsOf: staging.appendingPathComponent(name), encoding: .utf8) == name)
        }

        let (folder, folderPlan) = try extract(url, roots: ["sub"], in: fx, "folder")
        #expect(folderPlan.rejected.isEmpty)
        #expect(subpaths(folder) == ["sub", "sub/a link to b"])
    }

    @Test func aRegularRowNamedLikeAHardLinkStaysAFile() throws {
        let row: Substring = "-rw-r--r--  0 0 0 4 Jan  1  2020 notes link to self.txt"
        let plain = try #require(BsdtarListing.parseLine(row))
        #expect(plain.kind == .file && plain.rawPath == "notes link to self.txt")
        let link = try #require(BsdtarListing.parseLine(row, unmarkedLinksExcept: ["other link to self.txt"]))
        #expect(link.kind == .hardlink && link.rawPath == "notes" && link.linkTarget == "self.txt")
        let named = try #require(BsdtarListing.parseLine(row, unmarkedLinksExcept: ["notes link to self.txt"]))
        #expect(named.kind == .file && named.rawPath == "notes link to self.txt" && named.linkTarget == nil)
    }

    @Test(arguments: [TestRar.Redirect.fileCopy, .junction]) func rar5ReferencesAreRefused(_ type: TestRar.Redirect) throws {
        let fx = try Fixture()
        var rar = TestRar(.rar5)
        rar.file("good.txt", "fine")
        rar.members.append(.init(name: "copy.txt", unpackedSize: 4, redirect: (type, "good.txt")))
        let url = try rarURL(fx, rar)
        #expect { try ArchiveTool.extractionListing(url) } throws: { ($0 as? ArchiveError)?.errorDescription?.contains("references") == true }
    }

    // MARK: Read-only

    @Test func rarIsNeverOfferedForCreation() {
        #expect(!ArchiveFormat.rar.canCreate)
        #expect(ArchiveCreateFormat(rawValue: ArchiveFormat.rar.rawValue) == nil)
        #expect(ArchiveOutputFormat(rawValue: ArchiveFormat.rar.rawValue) == nil)
        #expect(!ArchiveCreateFormat.allCases.map(\.fileExtension).contains("rar"))
    }

    @Test func aRarOpensLikeOtherArchives() throws {
        let fx = try Fixture()
        try TestRar(.rar5).write(to: fx.url("a.RAR"))
        #expect(ArchiveFormat.detect(fx.url("a.RAR")) == .rar)
        #expect(ArchiveItemRef(url: fx.url("a.RAR/top/x.txt"))?.innerPath == "top/x.txt")
        #expect(ArchiveFormat.rar.typeName == "RAR File")
    }

    // MARK: The header walk on hostile bytes

    private let rar4Start = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
    private let rar5Start = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])

    private func traits(_ bytes: Data, _ fx: Fixture) throws -> RarHeaders.Traits {
        let url = fx.url("hostile.rar")
        try bytes.write(to: url)
        return RarHeaders.traits(of: url)
    }

    @Test func hostileRar5SizesCantOverflow() throws {
        let fx = try Fixture()
        // A declared data size of 2^64 − 1 runs past the end of the file.
        var body = TestRar.vint(2) + TestRar.vint(0x02) + TestRar.vint(.max)
        var sized = TestRar.vint(UInt64(body.count)) + body
        #expect(try traits(rar5Start + Data(count: 4) + sized, fx).isTruncated)

        // An extra area larger than its header, or a header over the format's ceiling, ends the walk.
        body = TestRar.vint(2) + TestRar.vint(0x01) + TestRar.vint(.max)
        sized = TestRar.vint(UInt64(body.count)) + body
        #expect(try traits(rar5Start + Data(count: 4) + sized, fx) == RarHeaders.Traits())
        let tooLarge = Data(count: 4) + TestRar.vint(2 << 20 + 1) + Data(repeating: 0xFF, count: 64)
        #expect(try traits(rar5Start + tooLarge, fx) == RarHeaders.Traits())

        // A size that never stops continuing isn't a vint.
        #expect(try traits(rar5Start + Data(count: 4) + Data(repeating: 0x80, count: 12), fx) == RarHeaders.Traits())
    }

    @Test func hostileRar5NameLengthsAreIgnored() throws {
        let fx = try Fixture()
        var fields = TestRar.vint(0) + TestRar.vint(0) + TestRar.vint(0) + TestRar.vint(0) + TestRar.vint(1)
        fields += TestRar.vint(.max) + Data("x link to y".utf8)
        #expect(try traits(rar5Start + TestRar.rar5Header(type: 2, body: fields), fx) == RarHeaders.Traits())
        // Past the end of the fields, into the extra area.
        let extra = Data([0x03, 0x70, 0x00, 0x00])
        fields = TestRar.vint(0) + TestRar.vint(0) + TestRar.vint(0) + TestRar.vint(0) + TestRar.vint(1)
        fields += TestRar.vint(13) + Data("x link to y".utf8)
        #expect(try traits(rar5Start + TestRar.rar5Header(type: 2, body: fields, extra: extra), fx) == RarHeaders.Traits())
    }

    @Test func namesLikeHardLinksAreHeldWithinABound() throws {
        let fx = try Fixture()
        var rar = TestRar(.rar5)
        let long = String(repeating: "n", count: 600 * 1024)
        rar.members.append(.init(name: "h", redirect: (.hardLink, "r")))
        for suffix in ["1", "2"] { rar.file(long + " link to " + suffix) }
        let found = RarHeaders.traits(of: try rarURL(fx, rar))
        #expect(found.hasHardLinks && found.regularNamesLikeHardLinks == [long + " link to 1"])
    }

    @Test func hostileRar4SizesCantOverflow() throws {
        let fx = try Fixture()
        var body = Data(repeating: 0xFF, count: 8)            // packed and unpacked sizes
        body += Data(repeating: 0, count: 17) + Data(repeating: 0xFF, count: 4)   // through the high packed size
        let block = TestRar.rar4Block(type: 0x74, flags: 0x8100, body: body)
        #expect(try traits(rar4Start + block, fx).isTruncated)
        #expect(try traits(rar4Start + Data([0, 0, 0x74, 0, 0, 3, 0]), fx) == RarHeaders.Traits())
        #expect(try traits(rar4Start + Data([0, 0, 0x74, 0, 0x80, 8, 0, 0]), fx) == RarHeaders.Traits())
    }

    @Test func randomBytesAfterTheSignaturesNeverTrap() throws {
        let fx = try Fixture()
        var generator = SeededBytes(seed: 0x5EED)
        for round in 0..<300 {
            let noise = generator.bytes(count: 1 + round % 200)
            _ = try traits((round % 2 == 0 ? rar4Start : rar5Start) + noise, fx)
        }
    }

    @Test func aFileThatIsntThereHasNoTraits() {
        #expect(RarHeaders.traits(of: URL(fileURLWithPath: "/nonexistent/x.rar")) == RarHeaders.Traits())
    }
}

/// A small deterministic generator (xorshift64*), so a failing round can be reproduced.
private struct SeededBytes {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func bytes(count: Int) -> Data {
        var out = Data()
        for _ in 0..<count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            out.append(UInt8(truncatingIfNeeded: (state &* 0x9E37_79B9_7F4A_7C15) >> 56))
        }
        return out
    }
}
