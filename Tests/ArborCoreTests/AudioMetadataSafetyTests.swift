import Foundation
import Darwin
import Testing
@testable import ArborCore

/// FE-152: hostile bytes, a verifier that doesn't trust the writer, and streaming. Generated files in disposable folders only.
@Suite struct AudioMetadataSafetyTests {
    private typealias F = AudioFixtures

    @discardableResult
    private func withReader<T>(_ bytes: Data, in fixture: Fixture, _ body: (EmbeddedFileReader) throws -> T) throws -> T {
        let url = fixture.url("input-\(UUID().uuidString)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        return try body(try #require(EmbeddedFileReader(descriptor: descriptor)))
    }

    private func write(_ bytes: Data, _ name: String, in fixture: Fixture) throws -> URL {
        let url = fixture.url(name)
        try bytes.write(to: url)
        return url
    }

    private static let formats: [(any TagRegionFormat, Data)] = [(ID3Format(), F.mp3()), (FLACFormat(), F.flac()), (M4AFormat(), F.m4aIndexFirst())]

    // MARK: Hostile input

    @Test func truncatedAtEveryLengthNeverTrapsAndNeverOffersAChopFromTheMetadata() throws {
        let fixture = try Fixture()
        for (format, whole) in Self.formats {
            for length in 0..<whole.count {
                let layout = try withReader(whole.prefix(length), in: fixture) { format.layout(of: $0) }
                if let layout, layout.blocked == nil { #expect(Int64(length) >= layout.region.upperBound) }
            }
        }
    }

    @Test func everyByteFlipInTheMetadataIsHandled() throws {
        let fixture = try Fixture()
        for (format, whole) in Self.formats {
            let limit = min(whole.count, 900)
            for index in stride(from: 0, to: limit, by: 3) {
                for pattern in [UInt8(0xFF), 0x00, 0x80] {
                    var bytes = whole
                    bytes[index] = pattern
                    _ = try withReader(bytes, in: fixture) { format.layout(of: $0) }
                }
            }
        }
    }

    @Test func hostileID3SizesAreReadOnly() throws {
        let fixture = try Fixture()
        let format = ID3Format()
        let frameOverrun = F.tag([Data("TIT2".utf8) + [0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 65]], padding: 0) + F.mpegAudio
        let v24NotSynchsafe = F.tag([Data("TIT2".utf8) + [0, 0, 0x81, 0, 0, 0, 0, 65]], version: 4, padding: 0) + F.mpegAudio
        let badFrameID = F.tag([Data("ti!2".utf8) + [0, 0, 0, 1, 0, 0, 65]], padding: 0) + F.mpegAudio
        let junkAfterFrames = F.tag([F.latin1("TIT2", "T"), Data([1, 2, 3])], padding: 0) + F.mpegAudio
        for bytes in [frameOverrun, v24NotSynchsafe, badFrameID, junkAfterFrames] {
            let layout = try withReader(bytes, in: fixture) { format.layout(of: $0) }
            #expect(layout?.blocked != nil)
        }
        let flood = F.tag(Array(repeating: F.frame("XQZ1", Data()), count: 8193), padding: 0) + F.mpegAudio
        #expect(try withReader(flood, in: fixture) { format.layout(of: $0) }?.blocked != nil)
    }

    @Test func onlyMPEGAudioAfterASoundTagMakesAFileAnMP3() throws {
        let fixture = try Fixture()
        let tag = F.tag([F.latin1("TIT2", "T")])
        let footer = Data("3DI".utf8) + [4, 0, 0x10, 0, 0, 0, 0]
        let notMP3: [Data] = [
            Data("ID3 tags are described in this note, which is plain text and not audio at all.".utf8),
            Data("ID3".utf8) + [3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F] + F.mpegAudio,
            Data("ID3".utf8) + [3, 0, 0, 0xFF, 0, 0, 0] + F.mpegAudio,
            Data("ID3".utf8) + [0xFF, 0, 0, 0, 0, 0, 0] + F.mpegAudio,
            Data("ID3".utf8) + [3, 0xFF, 0, 0, 0, 0, 0] + F.mpegAudio,
            Data("ID3".utf8) + [2, 0, 0, 0, 0, 0, 0] + Data(repeating: 0x55, count: 40),
            tag + Data(repeating: 0x55, count: 40),
            tag + F.flac(),
            tag + tag + F.flac(),
            tag + Data([0xFF, 0xF1, 0x50, 0x80]) + Data(count: 40),
            F.tag([F.latin1("TIT2", "T", version: 4)], version: 4, flags: 0x10) + footer + F.flac(),
        ]
        for (index, bytes) in notMP3.enumerated() {
            #expect(EmbeddedSnapshot.read(try write(bytes, "\(index).mp3", in: fixture)) == nil, "\(index)")
        }
        let withFooter = F.tag([F.latin1("TIT2", "T", version: 4)], version: 4, flags: 0x10) + footer + F.mpegAudio
        let snapshot = try #require(EmbeddedSnapshot.read(try write(withFooter, "footer.mp3", in: fixture)))
        #expect(snapshot.blocked?.localizedDescription.contains("footer") == true)
    }

    @Test func hostileFlacSizesAreReadOnly() throws {
        let fixture = try Fixture()
        let format = FLACFormat()
        let overrun = Data("fLaC".utf8) + F.streamInfo + Data([0x84, 0xFF, 0xFF, 0xFF]) + F.flacFrames
        let wrongFirst = Data("fLaC".utf8) + F.block(4, F.comments([]), last: true) + F.flacFrames
        let shortInfo = Data("fLaC".utf8) + F.block(0, Data(count: 10), last: true) + F.flacFrames
        let vendorTooLong = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.le32(0x7FFF_FFFF) + Data("v".utf8), last: true) + F.flacFrames
        let countTooHigh = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.le32(0) + F.le32(0xFFFF_FFFF), last: true) + F.flacFrames
        let commentTooLong = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.le32(0) + F.le32(1) + F.le32(0xFFFF_FFF0), last: true) + F.flacFrames
        let extraInBlock = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.comments([]) + [9], last: true) + F.flacFrames
        let noEquals = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.comments(["no equals sign"]), last: true) + F.flacFrames
        let badKey = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.comments(["K\u{7F}=v"]), last: true) + F.flacFrames
        let forbidden = Data("fLaC".utf8) + F.streamInfo + F.block(127, Data(), last: true) + F.flacFrames
        let noFrames = Data("fLaC".utf8) + F.streamInfo + F.block(4, F.comments([]), last: true) + Data(repeating: 0x20, count: 8)
        for bytes in [overrun, wrongFirst, shortInfo, vendorTooLong, countTooHigh, commentTooLong, extraInBlock, noEquals, badKey, forbidden, noFrames] {
            let layout = try withReader(bytes, in: fixture) { format.layout(of: $0) }
            #expect(layout?.blocked != nil)
        }
    }

    @Test func hostileAtomSizesAreReadOnly() throws {
        let fixture = try Fixture()
        let format = M4AFormat()
        let tiny = F.ftyp + Data([0, 0, 0, 4]) + F.type("moov")
        let overrun = F.ftyp + F.be32(0x7FFF_FFFF) + F.type("moov") + Data(count: 8)
        let wideOverrun = F.ftyp + F.be32(1) + F.type("moov") + Data(repeating: 0xFF, count: 8) + Data(count: 8)
        let nestedOverrun = F.ftyp + F.atom("moov", F.be32(0x7FFF_FFFF) + F.type("trak") + Data(count: 8))
        let trailingBytes = F.m4aIndexLast() + Data([1, 2, 3])
        for bytes in [tiny, overrun, wideOverrun, nestedOverrun, trailingBytes] {
            let layout = try withReader(bytes, in: fixture) { format.layout(of: $0) }
            #expect(layout == nil || layout?.blocked != nil)
        }
        // A flood of empty children ends at the atom budget instead of being walked.
        let flood = F.ftyp + F.atom("moov", (0..<5000).reduce(into: Data()) { list, _ in list += F.atom("junk", Data()) })
        #expect(try withReader(flood, in: fixture) { format.layout(of: $0) }?.blocked != nil)
    }

    @Test func undecodableTextIsShownBlankAndNotOffered() throws {
        let fixture = try Fixture()
        let badUTF16 = F.frame("TIT2", Data([1, 0xFF, 0xFE, 0x00, 0xD8]))
        let noBOM = F.frame("TPE1", Data([1, 0x41, 0x00]))
        let badEncoding = F.frame("TALB", Data([9, 0x41]))
        let badUTF8 = F.frame("TIT2", Data([3, 0xC3, 0x28]), version: 4)
        let snapshot = try #require(EmbeddedSnapshot.read(try write(F.mp3([badUTF16, noBOM, badEncoding]), "a.mp3", in: fixture)))
        #expect(snapshot.values[.title] == "")
        #expect(snapshot.editable.isDisjoint(with: [.title, .artist, .album]))
        let v24 = try #require(EmbeddedSnapshot.read(try write(F.mp3([badUTF8], version: 4), "b.mp3", in: fixture)))
        #expect(!v24.editable.contains(.title))
    }

    @Test func controlCharactersAreCleanedAndNotOffered() throws {
        let fixture = try Fixture()
        let url = try write(F.flac(["TITLE=safe\u{202E}gpj.exe", "ALBUM=a\u{7}b"]), "a.flac", in: fixture)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.values[.title] == "safegpj.exe")
        #expect(!snapshot.editable.contains(.title))
        #expect(!snapshot.editable.contains(.album))
    }

    @Test func oversizedFilesAreBlockedBeforeAnythingIsRead() throws {
        let fixture = try Fixture()
        let url = try write(F.flac(), "a.flac", in: fixture)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(EmbeddedLimits.maxStreamedFileBytes) + 1)
        try handle.close()
        #expect(try #require(EmbeddedSnapshot.read(url)).blocked == .tooLarge)
    }

    // MARK: The verifier

    private func expectRefused(_ format: any TagRegionFormat, edits: [EmbeddedField: String], from original: Data, to written: Data, in fixture: Fixture) throws {
        let staged = try write(written, "staged-\(UUID().uuidString)", in: fixture)
        try withReader(original, in: fixture) { reader in
            #expect(throws: EmbeddedFailure.soundUnverified) {
                try TagRegionVerifier.verify(format, edits: edits, original: reader, written: staged)
            }
        }
    }

    private func expectAccepted(_ format: any TagRegionFormat, edits: [EmbeddedField: String], from original: Data, to written: Data, in fixture: Fixture) throws {
        let staged = try write(written, "staged-\(UUID().uuidString)", in: fixture)
        try withReader(original, in: fixture) { try TagRegionVerifier.verify(format, edits: edits, original: $0, written: staged) }
    }

    @Test func verifierRefusesChangedAudioOrFrames() throws {
        let fixture = try Fixture()
        let format = ID3Format()
        let original = F.mp3()
        let edited = F.mp3(F.richFrames.map { $0 == F.latin1("TIT2", "Old title") ? F.latin1("TIT2", "New title") : $0 })
        try expectAccepted(format, edits: [.title: "New title"], from: original, to: edited, in: fixture)

        var audio = edited
        audio[audio.count - F.id3v1.count - 10] ^= 1
        try expectRefused(format, edits: [.title: "New title"], from: original, to: audio, in: fixture)

        var trailer = edited
        trailer[trailer.count - 1] ^= 1
        try expectRefused(format, edits: [.title: "New title"], from: original, to: trailer, in: fixture)

        let lostPicture = F.mp3(F.richFrames.filter { $0 != F.picture && $0 != F.latin1("TIT2", "Old title") } + [F.latin1("TIT2", "New title")])
        try expectRefused(format, edits: [.title: "New title"], from: original, to: lostPicture, in: fixture)

        let changedOtherField = F.mp3(F.richFrames.map {
            if $0 == F.latin1("TIT2", "Old title") { return F.latin1("TIT2", "New title") }
            return $0 == F.latin1("TPE1", "Old artist") ? F.latin1("TPE1", "Other") : $0
        })
        try expectRefused(format, edits: [.title: "New title"], from: original, to: changedOtherField, in: fixture)

        try expectRefused(format, edits: [.title: "Something else"], from: original, to: edited, in: fixture)
    }

    @Test func verifierRefusesOtherOrderAndUnchangedValues() throws {
        let fixture = try Fixture()
        let format = FLACFormat()
        let original = F.flac()
        let moved = F.flac(Array(F.plainComments.reversed()))
        try expectRefused(format, edits: [.title: "Old title"], from: original, to: moved, in: fixture)
        try expectRefused(format, edits: [.title: "New"], from: original, to: original, in: fixture)
        let otherVendor = F.flac(F.plainComments.map { $0 == "TITLE=Old title" ? "TITLE=New" : $0 }, vendor: "someone else")
        try expectRefused(format, edits: [.title: "New"], from: original, to: otherVendor, in: fixture)
        try expectAccepted(format, edits: [.title: "New"], from: original, to: F.flac(F.plainComments.map { $0 == "TITLE=Old title" ? "TITLE=New" : $0 }), in: fixture)
    }

    @Test func verifierRefusesLookalikeValues() throws {
        let fixture = try Fixture()
        let format = FLACFormat()
        // The same text to Swift's equality, but not the bytes requested.
        try expectRefused(format, edits: [.title: "caf\u{E9}"], from: F.flac(["TITLE=x"]), to: F.flac(["TITLE=cafe\u{301}"]), in: fixture)
    }

    @Test func verifierRefusesAudioThatMoved() throws {
        let fixture = try Fixture()
        let format = M4AFormat()
        let items = F.richItems
        let original = F.m4aIndexFirst(items: items, topFree: 512)
        let longer = items.map { $0 == F.textItem("\u{A9}nam", "Old title") ? F.textItem("\u{A9}nam", "Old title but longer") : $0 }
        // Same free space as before, so the mdat lands later and every chunk offset would be wrong.
        let moved = F.m4aIndexFirst(items: longer, topFree: 512)
        try expectRefused(format, edits: [.title: "Old title but longer"], from: original, to: moved, in: fixture)
        let absorbed = F.m4aIndexFirst(items: longer, topFree: 512 - ("Old title but longer".utf8.count - "Old title".utf8.count))
        try expectAccepted(format, edits: [.title: "Old title but longer"], from: original, to: absorbed, in: fixture)
    }

    @Test func aWriterThatDamagesTheFileNeverReachesTheOriginal() throws {
        struct Damaging: TagRegionFormat {
            let inner = ID3Format()
            var typeIdentifier: String { inner.typeIdentifier }
            func layout(of file: EmbeddedFileReader) -> TagLayout? { inner.layout(of: file) }
            func regionPieces(for edits: [EmbeddedField: String], in layout: TagLayout, of file: EmbeddedFileReader) throws -> [TagPiece] {
                try inner.regionPieces(for: [:], in: layout, of: file)
            }
        }
        let fixture = try Fixture()
        let url = try write(F.mp3(), "a.mp3", in: fixture)
        let staged = fixture.url("staged")
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        let held = try EmbeddedHeldFile(snapshot, limit: EmbeddedLimits.maxStreamedFileBytes)
        try Damaging().produce([.title: "New"], from: held, type: ID3Format.identifier, to: staged)
        #expect(throws: EmbeddedFailure.soundUnverified) {
            try Damaging().verify([.title: "New"], original: held, written: staged, type: ID3Format.identifier)
        }
    }

    // MARK: Streaming

    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// How far the process's memory rose during one save. Other suites run alongside, so callers take the quietest of several.
    private func memoryRise(saving title: String, over url: URL, in fixture: Fixture) throws -> Int64 {
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        let baseline = footprint()
        let stop = Counter()
        let peak = PeakMeter()
        let sampler = Thread {
            while stop.count == 0 {
                peak.observe(self.footprint())
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        sampler.start()
        defer { stop.increment() }
        try EmbeddedMetadataEditor.save([.title: title], over: snapshot, dispose: { staged, _ in
            // A previous version this size would fill the fixture's disk over several tries.
            let target = fixture.trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: staged, to: target)
            try FileManager.default.removeItem(at: target)
            try Data().write(to: target)
            return target
        })
        return peak.value - baseline
    }

    @Test func aLargeFileIsStreamedWithinAMemoryBound() throws {
        let fixture = try Fixture()
        let url = fixture.url("large.mp3")
        let head = F.tag(F.richFrames) + F.mpegAudio
        try head.write(to: url)
        let payload: UInt64 = 128 << 20
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(head.count) + payload)
        try handle.close()

        var quietest = Int64.max
        for attempt in 0..<5 where quietest >= 64 << 20 {
            quietest = min(quietest, try memoryRise(saving: "Large \(attempt)", over: url, in: fixture))
        }
        #expect(quietest < 64 << 20)
        #expect(try #require(EmbeddedSnapshot.read(url)).values[.title]?.hasPrefix("Large") == true)
        #expect(try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value == Int64(head.count) + Int64(payload))
    }

    @Test func largeReadsAreRefusedRatherThanAllocated() throws {
        let fixture = try Fixture()
        try withReader(Data(count: 16), in: fixture) { reader in
            #expect(reader.bytes(at: 0, count: 17) == nil)
            #expect(reader.bytes(at: 15, count: 2) == nil)
            #expect(reader.bytes(at: -1, count: 1) == nil)
            #expect(reader.bytes(at: Int64.max, count: 1) == nil)
            #expect(reader.bytes(at: 0, count: EmbeddedFileReader.maxRead + 1) == nil)
            #expect(reader.bytes(at: 0, count: 16)?.count == 16)
        }
    }
}

private final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    func observe(_ sample: Int64) { lock.withLock { peak = max(peak, sample) } }
    var value: Int64 { lock.withLock { peak } }
}
