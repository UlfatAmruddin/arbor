import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import ArborCore

/// FE-152: data ImageIO doesn't show, and other apps getting in during the swap. Generated files in disposable folders only.
@Suite struct EmbeddedMetadataSafetyTests {
    private struct Entry {
        let tag, type, count: Int
        let value: Data
        static func text(_ tag: Int, _ text: String) -> Entry { Entry(tag: tag, type: 2, count: text.utf8.count + 1, value: Data(text.utf8) + [0]) }
    }

    private func le16(_ value: Int) -> Data { Data([UInt8(value & 255), UInt8(value >> 8 & 255)]) }
    private func le32(_ value: Int) -> Data { le16(value & 0xFFFF) + le16(value >> 16) }

    private func directory(_ entries: [Entry], at offset: Int) -> Data {
        var body = le16(entries.count), extra = Data()
        let extraStart = offset + 2 + entries.count * 12 + 4
        for entry in entries.sorted(by: { $0.tag < $1.tag }) {
            body += le16(entry.tag) + le16(entry.type) + le32(entry.count)
            if entry.value.count <= 4 {
                body += entry.value + Data(count: 4 - entry.value.count)
            } else {
                body += le32(extraStart + extra.count)
                extra += entry.value
            }
        }
        return body + le32(0) + extra
    }

    private func tiff(main: [Entry], exif: [Entry]) -> Data {
        func pointer(_ offset: Int) -> Entry { Entry(tag: 0x8769, type: 4, count: 1, value: le32(offset)) }
        let exifOffset = 8 + directory(main + [pointer(0)], at: 8).count
        return Data("II".utf8) + [0x2A, 0] + le32(8) + directory(main + [pointer(exifOffset)], at: 8) + directory(exif, at: exifOffset)
    }

    private func exifPayload(make: String = "FooCam", main: [Entry] = [], exif: [Entry] = []) -> Data {
        Data("Exif\0\0".utf8) + tiff(main: [.text(0x10F, make)] + main, exif: [.text(0x9003, "2011:02:03 04:05:06")] + exif)
    }

    private func note(_ bytes: Data) -> Entry { Entry(tag: 0x927C, type: 7, count: bytes.count, value: bytes) }
    private let noteBytes = Data("MANUFACTURER-NOTE-0123456789".utf8)
    private let extendedXMP = Data("http://ns.adobe.com/xmp/extension/\0".utf8) + Data(repeating: 0x41, count: 40)
    private let thermal = Data("FLIR\0\u{1}\u{1}".utf8) + Data("THERMAL".utf8)

    private func segment(_ marker: UInt8, _ payload: Data) -> Data {
        Data([0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)]) + payload
    }

    private func plainJPEG() -> Data {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return withoutAPP1(output as Data)
    }

    /// ImageIO adds its own Exif segment, which would be a second one beside the test's.
    private func withoutAPP1(_ jpeg: Data) -> Data {
        var kept = jpeg.prefix(2), index = 2
        while jpeg[index + 1] != 0xDA {
            let end = index + 2 + (Int(jpeg[index + 2]) << 8 | Int(jpeg[index + 3]))
            if jpeg[index + 1] != 0xE1 { kept += jpeg[index..<end] }
            index = end
        }
        return kept + jpeg[index...]
    }

    /// A generated JPEG with the given APP1 segments and no others.
    private func jpeg(in fixture: Fixture, app1 payloads: [Data]) throws -> URL {
        let plain = plainJPEG()
        let url = fixture.url("a.jpg")
        try (plain.prefix(2) + payloads.reduce(Data()) { $0 + segment(0xE1, $1) } + plain.dropFirst(2)).write(to: url)
        return url
    }

    private func dispose(into fixture: Fixture) -> EmbeddedMetadataEditor.Disposer {
        { staged, _ in
            let target = fixture.trash.appendingPathComponent(UUID().uuidString + "-" + staged.lastPathComponent)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
    }

    private func expectRefused(_ url: URL, in fixture: Fixture) throws {
        let before = try Data(contentsOf: url)
        let snapshot = try #require(EmbeddedSnapshot.read(url)).unblocked()
        #expect(throws: EmbeddedFailure.verificationFailed) {
            try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: dispose(into: fixture))
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(fixture.names(".fixture-trash").isEmpty)
    }

    // MARK: Data ImageIO doesn't show

    @Test(arguments: ["FooCam", "NIKON CORPORATION", "SONY", "FUJIFILM", "Apple", "Canon"])
    func makerNoteMakesTheFileReadOnlyAndASaveIsStillRefused(make: String) throws {
        let fixture = try Fixture()
        let url = try jpeg(in: fixture, app1: [exifPayload(make: make, exif: [note(noteBytes)])])
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == .manufacturerData)
        #expect(snapshot.editable.isEmpty)
        try expectRefused(url, in: fixture)
    }

    @Test func extendedXMPAndOtherAPP1DataAreKeptOrTheSaveIsRefused() throws {
        for payload in [extendedXMP, thermal] {
            let fixture = try Fixture()
            let url = try jpeg(in: fixture, app1: [exifPayload(), payload])
            #expect(try #require(EmbeddedSnapshot.read(url)).blocked == .manufacturerData)
            try expectRefused(url, in: fixture)
        }
    }

    @Test func exifTagsImageIODropsRefuseTheSave() throws {
        let fixture = try Fixture()
        let windowsTitle = Entry(tag: 0x9C9B, type: 1, count: 8, value: Data("T\0i\0t\0\0\0".utf8))
        let url = try jpeg(in: fixture, app1: [exifPayload(main: [windowsTitle])])
        #expect(try #require(EmbeddedSnapshot.read(url)).blocked == nil)
        try expectRefused(url, in: fixture)
    }

    @Test func plainExifStaysEditable() throws {
        let fixture = try Fixture()
        let colorSpace = Entry(tag: 0xA001, type: 3, count: 1, value: le16(1))
        let url = try jpeg(in: fixture, app1: [exifPayload(exif: [colorSpace])])
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        try EmbeddedMetadataEditor.save([.title: "New", .dateTaken: ""], over: snapshot, dispose: dispose(into: fixture))
        let after = try #require(EmbeddedSnapshot.read(url))
        #expect(after.values[.title] == "New")
        #expect(after.values[.dateTaken] == nil)
    }

    @Test func aSecondExifSegmentMustSurvive() {
        let start = Data([0xFF, 0xD8]), scan = Data([0xFF, 0xDA, 0x00, 0x02, 9])
        let first = segment(0xE1, exifPayload()), second = segment(0xE1, exifPayload(make: "Other"))
        #expect(JPEGStructure.contentSurvives(from: start + first + second + scan, in: start + first + second + scan))
        #expect(!JPEGStructure.contentSurvives(from: start + first + second + scan, in: start + first + scan))
    }

    @Test func exifWalkerReadsBothByteOrdersAndComparesNotes() throws {
        let block = Data(exifPayload(exif: [note(noteBytes)]).dropFirst(6))
        let little = try #require(ExifStructure.read(block))
        #expect(little.makerNote == noteBytes)
        #expect(little.tags.contains(.init(directory: .exif, id: 0x9003)))
        let bigHeader = Data("MM".utf8) + [0, 0x2A, 0, 0, 0, 8, 0, 1, 0x87, 0x69, 0, 4, 0, 0, 0, 1, 0, 0, 0, 26, 0, 0, 0, 0]
        let big = bigHeader + [0, 1, 0x92, 0x7C, 0, 7, 0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 0, 0]
        #expect(try #require(ExifStructure.read(big)).makerNote == Data([1, 2, 3]))

        var without = little
        without.makerNote = Data()
        #expect(!ExifStructure.survives(little, in: without, removable: []))
        #expect(ExifStructure.survives(little, in: little, removable: []))
    }

    @Test func exifWalkerRefusesHostileBlocksWithoutTrapping() {
        let header = Data("II".utf8) + [0x2A, 0]
        #expect(ExifStructure.read(Data()) == nil)
        #expect(ExifStructure.read(Data("XX".utf8) + [0x2A, 0, 8, 0, 0, 0]) == nil)
        #expect(ExifStructure.read(header + [0xFF, 0xFF, 0xFF, 0xFF]) == nil)
        // Directory claims more entries than the block holds.
        #expect(ExifStructure.read(header + le32(8) + [0xFF, 0xFF]) == nil)
        // Maker note running past the end of the block.
        let longNote = Entry(tag: 0x927C, type: 7, count: 0x7FFF_FFFF, value: le32(0x7FFF_FFF0))
        #expect(ExifStructure.read(tiff(main: [], exif: [longNote])) == nil)
        // Directories that point at themselves end at the entry budget instead of looping.
        let looping = Entry(tag: 0x8769, type: 4, count: 1, value: le32(8))
        #expect(ExifStructure.read(header + le32(8) + directory(Array(repeating: looping, count: 200), at: 8)) == nil)
    }

    // MARK: IPTC ImageIO has no key for

    private func dataset(_ record: UInt8, _ number: UInt8, _ value: Data) -> Data {
        Data([0x1C, record, number, UInt8(value.count >> 8), UInt8(value.count & 255)]) + value
    }

    private func dataset(_ record: UInt8, _ number: UInt8, _ text: String) -> Data { dataset(record, number, Data(text.utf8)) }

    private func resource(_ id: Int, _ body: Data, padded: Bool = true) -> Data {
        var block = Data("8BIM".utf8) + [UInt8(id >> 8), UInt8(id & 255), 0, 0]
        block += [0, UInt8(body.count >> 16 & 255), UInt8(body.count >> 8 & 255), UInt8(body.count & 255)] + body
        return padded && body.count % 2 == 1 ? block + [0] : block
    }

    private func photoshop(_ resources: Data...) -> Data { Data("Photoshop 3.0\0".utf8) + resources.reduce(Data(), +) }

    /// A generated JPEG with the given APP13 segments and no APP1.
    private func jpeg(in fixture: Fixture, app13 payloads: [Data]) throws -> URL {
        let plain = plainJPEG()
        let url = fixture.url("a.jpg")
        try (plain.prefix(2) + payloads.reduce(Data()) { $0 + segment(0xED, $1) } + plain.dropFirst(2)).write(to: url)
        return url
    }

    private func iptc(in url: URL) throws -> Set<IPTCStructure.Entry> {
        let parsed = try #require(JPEGStructure.parse(try Data(contentsOf: url)))
        return try #require(IPTCStructure.read(parsed.photoshop))
    }

    private let ordinary = [(UInt8(2), UInt8(5), "old title"), (2, 80, "A. Byline"), (2, 25, "one"), (2, 25, "two"), (2, 116, "(c) someone")]

    private func ordinaryRecords() -> Data { ordinary.reduce(Data()) { $0 + dataset($1.0, $1.1, $1.2) } }

    /// A value ImageIO keeps as it is for each dataset on its list.
    private func plausible(_ set: IPTCStructure.DataSet) -> String {
        switch set.number {
        case 10: return "1"
        case 55, 62, 70: return "20110203"
        case 60, 63: return "040506+0000"
        default: return "caf\u{E9} \(set.number)"
        }
    }

    @Test func datasetsImageIODropsMakeTheFileReadOnlyAndASaveIsStillRefused() throws {
        for (record, number) in [(UInt8(2), UInt8(232)), (2, 200), (2, 202), (1, 5)] {
            let fixture = try Fixture()
            let records = ordinaryRecords() + dataset(record, number, "held only in IPTC")
            let url = try jpeg(in: fixture, app13: [photoshop(resource(0x0404, records))])
            let snapshot = try #require(EmbeddedSnapshot.read(url))
            #expect(snapshot.blocked == .manufacturerData)
            #expect(snapshot.editable.isEmpty)
            try expectRefused(url, in: fixture)
        }
    }

    @Test func malformedIPTCIsReadOnlyAndASaveIsStillRefused() throws {
        let records = ordinaryRecords()
        let oddRecords = records + dataset(2, 105, "no")
        #expect(oddRecords.count % 2 == 1)
        let cases = [
            photoshop(resource(0x0404, records + Data([0x1C, 2, 105, 0, 200]))),            // Dataset running past its resource.
            photoshop(resource(0x0404, records + Data([0x42, 2, 105, 0, 1, 0x41]))),        // Junk where a dataset should start.
            photoshop(resource(0x0404, records + Data([0x1C, 2, 105, 0x80, 2, 0, 1, 0x41]))), // Extended dataset.
            photoshop(resource(0x0404, oddRecords, padded: false)),                          // Padding byte missing.
            photoshop(resource(0x0404, dataset(2, 80, "abc"))),                              // Too short for ImageIO to read.
            photoshop(resource(0x0404, records), resource(0x0404, dataset(2, 105, "second"))),
            photoshop(resource(0x0404, records)) + Data(repeating: 0x42, count: 20),         // Junk after the last resource.
            photoshop(resource(0x0404, oddRecords, padded: false),                           // Another resource damaged by an earlier save.
                      Data("BIM".utf8) + [0x27, 0x10, 0, 0, 0, 0, 0, 8] + Data("printing".utf8)),
        ]
        for payload in cases {
            let fixture = try Fixture()
            let url = try jpeg(in: fixture, app13: [payload])
            #expect(try #require(EmbeddedSnapshot.read(url)).blocked == .manufacturerData)
            try expectRefused(url, in: fixture)
        }
    }

    @Test func iptcOutsideTheFirstPhotoshopSegmentIsReadOnlyAndRefused() throws {
        let records = ordinaryRecords()
        let other = photoshop(resource(0x2710, Data("printing".utf8)))
        let segments = [[photoshop(resource(0x0404, records)), photoshop(resource(0x0404, dataset(2, 105, "second segment")))],
                        [other, photoshop(resource(0x0404, records))]]
        for payloads in segments {
            let fixture = try Fixture()
            let url = try jpeg(in: fixture, app13: payloads)
            #expect(try #require(EmbeddedSnapshot.read(url)).blocked == .manufacturerData)
            try expectRefused(url, in: fixture)
        }
    }

    @Test(arguments: [Data([0x63, 0x61, 0x66, 0xE9]), Data("caf\u{E9}".utf8)])
    func textThatWouldBeTranscodedIsReadOnlyAndRefused(value: Data) throws {
        let fixture = try Fixture()
        let url = try jpeg(in: fixture, app13: [photoshop(resource(0x0404, ordinaryRecords() + dataset(2, 105, value)))])
        #expect(try #require(EmbeddedSnapshot.read(url)).blocked == .manufacturerData)
        try expectRefused(url, in: fixture)
    }

    @Test func everyDatasetImageIOCarriesStaysEditableAndIsKept() throws {
        let fixture = try Fixture()
        var records = dataset(1, 90, Data([0x1B, 0x25, 0x47])) + dataset(2, 0, Data([0, 2]))
        for set in IPTCStructure.carried.sorted(by: { $0.number < $1.number }) {
            records += dataset(UInt8(set.record), UInt8(set.number), plausible(set))
        }
        let other = resource(0x2710, Data("printing".utf8))
        let url = try jpeg(in: fixture, app13: [photoshop(other, resource(0x0404, records))])
        let original = try iptc(in: url)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        #expect(snapshot.editable.contains(.title))
        try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: dispose(into: fixture))
        #expect(try #require(EmbeddedSnapshot.read(url)).values[.title] == "New")
        let written = try iptc(in: url)
        #expect(original.subtracting(written).map(\.set) == [IPTCStructure.objectName])
    }

    @Test func ordinaryIPTCStaysEditableForEveryField() throws {
        let fixture = try Fixture()
        let records = ordinaryRecords() + dataset(2, 120, "old caption") + dataset(2, 55, "20110203") + dataset(2, 60, "040506+0000")
        let url = try jpeg(in: fixture, app13: [photoshop(resource(0x0404, records), resource(0x07D0, Data("path".utf8)))])
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        try EmbeddedMetadataEditor.save([.title: "New", .description: "New caption", .rating: "3", .dateTaken: "2020:01:02 03:04:05"],
                                        over: snapshot, dispose: dispose(into: fixture))
        let after = try #require(EmbeddedSnapshot.read(url))
        #expect(after.values[.title] == "New")
        #expect(after.values[.description] == "New caption")
        #expect(after.values[.rating] == "3")
        #expect(after.values[.dateTaken] == "2020:01:02 03:04:05")
        #expect(try iptc(in: url).contains(.init(set: .init(record: 2, number: 80), value: Data("A. Byline".utf8))))
    }

    @Test func repeatedSavesWearOnlyImageIOsOwnDigest() throws {
        let fixture = try Fixture()
        let digest = resource(0x0425, Data(repeating: 0xA5, count: 16))
        let url = try jpeg(in: fixture, app13: [photoshop(resource(0x0404, ordinaryRecords()), digest)])
        for title in ["First", "Secon", "Thi", "Forth", "Fifth", "Sixth"] {
            let snapshot = try #require(EmbeddedSnapshot.read(url))
            #expect(snapshot.blocked == nil)
            try EmbeddedMetadataEditor.save([.title: title], over: snapshot, dispose: dispose(into: fixture))
            #expect(try #require(EmbeddedSnapshot.read(url)).values[.title] == title)
            #expect(try iptc(in: url).contains(.init(set: .init(record: 2, number: 80), value: Data("A. Byline".utf8))))
        }
    }

    @Test func aPhotoshopSegmentWithoutIPTCStaysEditable() throws {
        let fixture = try Fixture()
        let url = try jpeg(in: fixture, app13: [photoshop(resource(0x0404, Data()), resource(0x2710, Data("printing".utf8)))])
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: dispose(into: fixture))
        #expect(try #require(EmbeddedSnapshot.read(url)).values[.title] == "New")
    }

    @Test func iptcWalkerRefusesHostileSegmentsWithoutTrapping() {
        let signature = Data("Photoshop 3.0\0".utf8)
        #expect(IPTCStructure.read([]) == [])
        #expect(IPTCStructure.read([signature]) == [])
        #expect(IPTCStructure.read([Data()]) == nil)
        #expect(IPTCStructure.read([signature + Data("8BIM".utf8)]) == nil)
        // A name running past the segment, and a size that would overflow a careless sum.
        #expect(IPTCStructure.read([signature + Data("8BIM".utf8) + [4, 4, 0xFF, 0, 0, 0, 0, 0]]) == nil)
        #expect(IPTCStructure.read([signature + Data("8BIM".utf8) + [4, 4, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]]) == nil)
        // Truncated at every length: never a trap, and never read as more than the bytes hold.
        let whole = photoshop(resource(0x0404, ordinaryRecords()))
        for length in 0..<whole.count { _ = IPTCStructure.read([Data(whole.prefix(length))]) }
        // One dataset past the entry budget.
        let flood = (0...4096).reduce(Data()) { $0 + dataset(2, 25, Data([UInt8($1 & 255), UInt8($1 >> 8)])) }
        #expect(IPTCStructure.read([photoshop(resource(0x0404, flood))]) == nil)
    }

    @Test func iptcComparisonIsByValue() throws {
        let set = IPTCStructure.DataSet(record: 2, number: 25)
        let one = IPTCStructure.Entry(set: set, value: Data("one".utf8)), two = IPTCStructure.Entry(set: set, value: Data("two".utf8))
        #expect(IPTCStructure.survives([one], in: [one, two], changeable: []))
        #expect(!IPTCStructure.survives([one], in: [two], changeable: []))
        #expect(IPTCStructure.survives([one], in: [two], changeable: [set]))
        // The character set and record version are ImageIO's to write.
        let version = IPTCStructure.Entry(set: .init(record: 2, number: 0), value: Data([0, 4]))
        #expect(IPTCStructure.survives([version], in: [], changeable: []))
        #expect(IPTCStructure.rewriteKeeps([version, one]))
    }

    // MARK: Another app getting in during the swap

    private func editable(in fixture: Fixture) throws -> (url: URL, original: Data, snapshot: EmbeddedSnapshot) {
        let url = try jpeg(in: fixture, app1: [exifPayload()])
        return (url, try Data(contentsOf: url), try #require(EmbeddedSnapshot.read(url)))
    }

    private func onlyTrashed(_ fixture: Fixture) throws -> Data {
        let names = fixture.names(".fixture-trash")
        #expect(names.count == 1)
        return try Data(contentsOf: fixture.trash.appendingPathComponent(try #require(names.first)))
    }

    @Test func fileRemovedDuringTheSwapSendsTheOriginalToTheTrash() throws {
        let fixture = try Fixture()
        let (url, original, snapshot) = try editable(in: fixture)
        #expect(throws: EmbeddedFailure.interrupted(keptAt: nil)) {
            try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: dispose(into: fixture),
                                            afterSwap: { try? FileManager.default.removeItem(at: url) })
        }
        #expect(try onlyTrashed(fixture) == original)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileReplacedDuringTheSwapIsLeftAloneAndTheOriginalIsTrashed() throws {
        let fixture = try Fixture()
        let (url, original, snapshot) = try editable(in: fixture)
        let theirs = Data("written by another app".utf8)
        #expect(throws: EmbeddedFailure.interrupted(keptAt: nil)) {
            try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: dispose(into: fixture),
                                            afterSwap: { try? theirs.write(to: url, options: .atomic) })
        }
        #expect(try Data(contentsOf: url) == theirs)
        #expect(try onlyTrashed(fixture) == original)
    }

    @Test func whenTheTrashAlsoFailsTheOriginalStaysWhereTheErrorSays() throws {
        let fixture = try Fixture()
        let (url, original, snapshot) = try editable(in: fixture)
        var reported: String?
        do {
            try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: { _, _ in throw CocoaError(.fileWriteUnknown) },
                                            afterSwap: { try? FileManager.default.removeItem(at: url) })
        } catch EmbeddedFailure.interrupted(let path) {
            reported = path
        }
        let path = try #require(reported)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    }

    @Test func trashFailingAfterTheFileWasRemovedDoesNotClaimItWasNotReplaced() throws {
        let fixture = try Fixture()
        let (url, original, snapshot) = try editable(in: fixture)
        let failing: EmbeddedMetadataEditor.Disposer = { _, _ in
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
        var reported: String?
        do {
            try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: failing)
        } catch EmbeddedFailure.interrupted(let path) {
            reported = path
        }
        let path = try #require(reported)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    }

    @Test func trashFailingAfterAnotherAppReplacedTheFileLeavesTheirFile() throws {
        let fixture = try Fixture()
        let (url, original, snapshot) = try editable(in: fixture)
        let theirs = Data("written by another app".utf8)
        let failing: EmbeddedMetadataEditor.Disposer = { _, _ in
            try? theirs.write(to: url, options: .atomic)
            throw CocoaError(.fileWriteUnknown)
        }
        var reported: String?
        do {
            try EmbeddedMetadataEditor.save([.title: "New"], over: snapshot, dispose: failing)
        } catch EmbeddedFailure.interrupted(let path) {
            reported = path
        }
        let path = try #require(reported)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(try Data(contentsOf: url) == theirs)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    }
}

extension EmbeddedSnapshot {
    /// Tests only: the same file as if nothing had blocked it, to prove a save is refused on its own.
    fileprivate func unblocked() -> EmbeddedSnapshot {
        EmbeddedSnapshot(url: url, stamp: stamp, typeIdentifier: typeIdentifier, values: values, editable: support.fields, blocked: nil, support: support)
    }
}
