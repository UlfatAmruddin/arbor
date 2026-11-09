import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import ArborCore

/// FE-152: generated images only, in disposable folders; "Trash" is a folder inside the fixture.
@Suite struct EmbeddedMetadataTests {
    private static let rich: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "old description", kCGImagePropertyTIFFMake: "Acme"] as CFDictionary,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2011:02:03 04:05:06", kCGImagePropertyExifUserComment: "keep me"] as CFDictionary,
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: "old title", kCGImagePropertyIPTCStarRating: 2,
                                         kCGImagePropertyIPTCKeywords: ["one", "two"]] as CFDictionary,
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N"] as CFDictionary,
        kCGImagePropertyOrientation: 6,
    ]

    private func picture(_ width: Int = 64, _ height: Int = 48, shade: CGFloat = 0.3) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: shade, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: shade, alpha: 1))
        context.fill(CGRect(x: 4, y: 4, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    @discardableResult
    private func image(_ name: String, in folder: URL, _ type: UTType = .jpeg, properties: [CFString: Any] = rich, frames: Int = 1) -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil)!
        CGImageDestinationAddImage(destination, picture(), properties as CFDictionary)
        for extra in 1..<max(frames, 1) { CGImageDestinationAddImage(destination, picture(32, 24, shade: CGFloat(extra) * 0.2), nil) }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func dispose(into fixture: Fixture) -> EmbeddedMetadataEditor.Disposer {
        { staged, _ in
            let target = fixture.trash.appendingPathComponent(UUID().uuidString + "-" + staged.lastPathComponent)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
    }

    private func decoded(_ url: URL) -> Data {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!.dataProvider!.data! as Data
    }

    private func properties(_ url: URL) -> [String: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [String: Any] ?? [:]
    }

    private func group(_ url: URL, _ name: CFString) -> [String: Any] { properties(url)[name as String] as? [String: Any] ?? [:] }

    // MARK: The audit, kept honest

    @Test func auditMatchesWhatEachTypeStores() {
        #expect(EmbeddedSupport.forType(UTType.jpeg.identifier)?.fields == Set(EmbeddedField.allCases))
        #expect(EmbeddedSupport.forType(UTType.jpeg.identifier)?.canRemoveDate == true)
        #expect(EmbeddedSupport.forType(UTType.heic.identifier)?.fields == [.title, .rating])
        #expect(EmbeddedSupport.forType(UTType.tiff.identifier)?.fields == [.title, .rating, .dateTaken])
        for type in [UTType.png, .gif, .bmp, .webP, .pdf, UTType("public.jpeg-2000")!, UTType("public.avif")!] {
            #expect(EmbeddedSupport.forType(type.identifier) == nil)
        }
    }

    @Test(arguments: [(UTType.jpeg, "a.jpg"), (.heic, "a.heic"), (.tiff, "a.tiff")])
    func everyOfferedFieldRoundTrips(type: UTType, name: String) throws {
        let fixture = try Fixture()
        let url = image(name, in: fixture.root, type)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        var edits: [EmbeddedField: String] = [:]
        if snapshot.editable.contains(.title) { edits[.title] = "New title – 写真 🌳" }
        if snapshot.editable.contains(.description) { edits[.description] = "New description\nsecond line" }
        if snapshot.editable.contains(.rating) { edits[.rating] = "4" }
        if snapshot.editable.contains(.dateTaken) { edits[.dateTaken] = "2022:02:02 02:02:02" }
        let pixels = decoded(url)
        try EmbeddedMetadataEditor.save(edits, over: snapshot, dispose: dispose(into: fixture))
        #expect(decoded(url) == pixels)
        let after = try #require(EmbeddedSnapshot.read(url))
        for (field, value) in edits { #expect(after.values[field] == value) }
        let tags = try #require(properties(url)[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect((tags[kCGImagePropertyGPSLatitudeRef as String] as? String) == "N")
        #expect((properties(url)[kCGImagePropertyOrientation as String] as? Int) == 6)
        #expect((group(url, kCGImagePropertyExifDictionary)[kCGImagePropertyExifUserComment as String] as? String) == "keep me")
    }

    @Test(arguments: [(UTType.jpeg, "a.jpg"), (.heic, "a.heic"), (.tiff, "a.tiff")])
    func titleAndRatingClear(type: UTType, name: String) throws {
        let fixture = try Fixture()
        let url = image(name, in: fixture.root, type)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        try EmbeddedMetadataEditor.save([.title: "", .rating: ""], over: snapshot, dispose: dispose(into: fixture))
        let after = try #require(EmbeddedSnapshot.read(url))
        #expect(after.values[.title] == nil)
        #expect(after.values[.rating] == nil)
    }

    @Test func jpegDescriptionAndDateClear() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        try EmbeddedMetadataEditor.save([.description: "", .dateTaken: ""], over: snapshot, dispose: dispose(into: fixture))
        let after = try #require(EmbeddedSnapshot.read(url))
        #expect(after.values[.description] == nil)
        #expect(after.values[.dateTaken] == nil)
    }

    @Test func secondEditKeepsTheFirst() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        try EmbeddedMetadataEditor.save([.title: "First"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        try EmbeddedMetadataEditor.save([.rating: "5"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        let after = try #require(EmbeddedSnapshot.read(url))
        #expect(after.values[.title] == "First")
        #expect(after.values[.rating] == "5")
        #expect(after.values[.description] == "old description")
    }

    @Test func typesWithoutALosslessPathAreNotOffered() throws {
        let fixture = try Fixture()
        #expect(EmbeddedSnapshot.read(image("a.png", in: fixture.root, .png)) == nil)
        #expect(EmbeddedSnapshot.read(image("a.bmp", in: fixture.root, .bmp, properties: [:])) == nil)
        #expect(EmbeddedSnapshot.read(image("a.gif", in: fixture.root, .gif, properties: [:])) == nil)
        // The content decides, not the name.
        let renamed = fixture.root.appendingPathComponent("really-a-png.jpg")
        try FileManager.default.moveItem(at: image("b.png", in: fixture.root, .png), to: renamed)
        #expect(EmbeddedSnapshot.read(renamed) == nil)
        let notImage = try fixture.file("note.jpg", "not a picture")
        #expect(EmbeddedSnapshot.read(notImage) == nil)
    }

    // MARK: Refusals

    @Test func refusesAFileChangedSinceItWasRead() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        let before = try Data(contentsOf: url)
        #expect(throws: EmbeddedFailure.changedSinceRead) {
            try EmbeddedMetadataEditor.save([.title: "Nope"], over: snapshot, dispose: dispose(into: fixture))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func refusesASwappedFile() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        let other = image("b.jpg", in: fixture.root)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        #expect(throws: EmbeddedFailure.changedSinceRead) {
            try EmbeddedMetadataEditor.save([.title: "Nope"], over: snapshot, dispose: dispose(into: fixture))
        }
    }

    @Test func aFailedTrashLeavesTheOriginalInPlace() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        let before = try Data(contentsOf: url)
        let failing: EmbeddedMetadataEditor.Disposer = { _, _ in throw CocoaError(.fileWriteUnknown) }
        #expect(throws: EmbeddedFailure.trashFailed) { try EmbeddedMetadataEditor.save([.title: "Nope"], over: snapshot, dispose: failing) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func refusesHardLinksAndLockedFilesAsBlocked() throws {
        let fixture = try Fixture()
        let linked = image("a.jpg", in: fixture.root)
        try FileManager.default.linkItem(at: linked, to: fixture.root.appendingPathComponent("b.jpg"))
        let hard = try #require(EmbeddedSnapshot.read(linked))
        #expect(hard.blocked == .hardLinked)
        #expect(hard.editable.isEmpty)

        let locked = image("c.jpg", in: fixture.root)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        #expect(try #require(EmbeddedSnapshot.read(locked)).blocked == .locked)
    }

    @Test func oversizedFilesAreBlocked() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(EmbeddedLimits.maxFileBytes) + 1)
        try handle.close()
        #expect(try #require(EmbeddedSnapshot.read(url)).blocked == .tooLarge)
    }

    // MARK: Hostile values

    @Test func hostileTextIsCleanedAndNotOffered() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root, properties: [kCGImagePropertyIPTCDictionary:
            [kCGImagePropertyIPTCObjectName: "safe\u{202E}gpj.exe"] as CFDictionary])
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.values[.title] == "safegpj.exe")
        #expect(!snapshot.editable.contains(.title))
        #expect(snapshot.editable.contains(.description))
    }

    @Test func overlongValuesAreShownTruncatedAndNotOffered() throws {
        let fixture = try Fixture()
        let long = String(repeating: "x", count: EmbeddedLimits.maxTitleLength + 50)
        let url = image("a.jpg", in: fixture.root, properties: [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: long] as CFDictionary])
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.values[.title]?.count == EmbeddedLimits.maxTitleLength)
        #expect(!snapshot.editable.contains(.title))
    }

    @Test func titlesInSeveralLanguagesStayReadOnly() throws {
        let fixture = try Fixture()
        let plain = image("plain.jpg", in: fixture.root)
        let source = CGImageSourceCreateWithURL(plain as CFURL, nil)!
        let url = fixture.root.appendingPathComponent("lang.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "dc:title" as CFString, ["x-default": "Default", "de": "Titel"] as CFDictionary))
        var error: Unmanaged<CFError>?
        #expect(CGImageDestinationCopyImageSource(destination, source, [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary, &error))
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.values[.title] == "Default")
        #expect(!snapshot.editable.contains(.title))
    }

    @Test func oddRatingsAndDatesStayReadOnly() throws {
        let fixture = try Fixture()
        let rating = image("r.jpg", in: fixture.root, properties: [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCStarRating: 900] as CFDictionary])
        let ratingSnapshot = try #require(EmbeddedSnapshot.read(rating))
        #expect(!ratingSnapshot.editable.contains(.rating))
        // ImageIO won't write an invalid date, so the file is patched like a crafted one would be.
        let date = image("d.jpg", in: fixture.root)
        var bytes = try Data(contentsOf: date)
        let valid = try #require(bytes.range(of: Data("2011:02:03 04:05:06".utf8)))
        bytes.replaceSubrange(valid, with: Data("2011:13:45 04:05:06".utf8))
        try bytes.write(to: date)
        let dateSnapshot = try #require(EmbeddedSnapshot.read(date))
        #expect(dateSnapshot.values[.dateTaken] == "2011:13:45 04:05:06")
        #expect(!dateSnapshot.editable.contains(.dateTaken))
    }

    @Test func multiFrameFilesKeepEveryFrame() throws {
        let fixture = try Fixture()
        for (type, name) in [(UTType.tiff, "m.tiff"), (.heic, "m.heic")] {
            let url = image(name, in: fixture.root, type, frames: 3)
            try EmbeddedMetadataEditor.save([.rating: "1"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetCount(source) == 3)
            #expect((try #require(EmbeddedSnapshot.read(url))).values[.rating] == "1")
        }
    }

    // MARK: File identity and attributes

    @Test func fileAttributesAreKept() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try FinderMetadata.setComment("keep", on: url)
        try FinderMetadata.setTags(["Blue"], on: url)
        let created = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)

        try EmbeddedMetadataEditor.save([.title: "T"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect((attributes[.creationDate] as? Date)?.timeIntervalSince1970 == created.timeIntervalSince1970)
        #expect(FinderMetadata.comment(of: url) == "keep")
        #expect(FinderMetadata.tags(of: url) == ["Blue"])
    }

    @Test func noStagingFilesAreLeftBeside() throws {
        let fixture = try Fixture()
        let folder = fixture.root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = image("a.jpg", in: folder)
        try EmbeddedMetadataEditor.save([.title: "T"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.jpg"])
    }

    // MARK: Undo

    @Test func undoRestoresTheOriginalBytesAndRedoTheEdit() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let original = try Data(contentsOf: url)
        let step = try EmbeddedMetadataEditor.save([.title: "Edited"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        let edited = try Data(contentsOf: url)
        #expect(edited != original)
        #expect(try Data(contentsOf: step.kept) == original)

        let opposite = try EmbeddedMetadataEditor.revert(step)
        #expect(try Data(contentsOf: url) == original)
        #expect(EmbeddedSnapshot.read(url)?.values[.title] == "old title")
        _ = try EmbeddedMetadataEditor.revert(opposite)
        #expect(try Data(contentsOf: url) == edited)
    }

    @Test func undoRefusesIfTheFileChangedSince() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let step = try EmbeddedMetadataEditor.save([.title: "Edited"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let changed = try Data(contentsOf: url)
        #expect(throws: EmbeddedFailure.changedSinceSaved) { try EmbeddedMetadataEditor.revert(step) }
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test func undoRefusesIfThePreviousVersionIsGone() throws {
        let fixture = try Fixture()
        let url = image("a.jpg", in: fixture.root)
        let step = try EmbeddedMetadataEditor.save([.title: "Edited"], over: try #require(EmbeddedSnapshot.read(url)), dispose: dispose(into: fixture))
        try FileManager.default.removeItem(at: step.kept)
        let current = try Data(contentsOf: url)
        #expect(throws: EmbeddedFailure.changedSinceSaved) { try EmbeddedMetadataEditor.revert(step) }
        #expect(try Data(contentsOf: url) == current)
    }

    // MARK: Pure logic

    @Test func dateConversions() {
        #expect(EmbeddedDate.display(fromExif: "2024:03:07 14:30:05") == "2024-03-07 14:30:05")
        #expect(EmbeddedDate.exif(fromDisplay: "2024-03-07 14:30:05") == "2024:03:07 14:30:05")
        #expect(EmbeddedDate.exif(fromDisplay: "2024-03-07 14:30") == "2024:03:07 14:30:00")
        #expect(EmbeddedDate.exif(fromDisplay: "2024-03-07") == "2024:03:07 00:00:00")
        for bad in ["", "yesterday", "2024-13-01", "2024-02-30", "24-03-07", "2024-03-07 25:00:00", "2024-03-07 12:60", "2024-03-07 1:2:3:4"] {
            #expect(EmbeddedDate.exif(fromDisplay: bad) == nil)
        }
        for bad in ["2024:02:30 00:00:00", "0000:01:01 00:00:00", "٢٠٢٤:03:07 14:30:05", "2024-03-07 14:30:05", "2024:03:07 14:30:05 extra"] {
            #expect(!EmbeddedDate.isValidExif(bad))
        }
    }

    @Test func textCleaning() {
        #expect(EmbeddedText.clean("plain", limit: 10).isExact)
        #expect(EmbeddedText.clean("two\nlines\tok", limit: 20).isExact)
        #expect(EmbeddedText.clean("a\u{0}b", limit: 10) == ("ab", false))
        #expect(EmbeddedText.clean("a\u{2066}b", limit: 10) == ("ab", false))
        #expect(EmbeddedText.clean("abcdef", limit: 3) == ("abc", false))
    }

    private func snapshot(editable: Set<EmbeddedField> = Set(EmbeddedField.allCases), values: [EmbeddedField: String] = [:],
                          canRemoveDate: Bool = true, in fixture: Fixture) throws -> EmbeddedSnapshot {
        let url = image("s.jpg", in: fixture.root, properties: [:])
        let read = try #require(EmbeddedSnapshot.read(url))
        return read.withValues(values, editable: editable, canRemoveDate: canRemoveDate)
    }

    @Test func editsLeaveOutUnchangedFieldsAndValidate() throws {
        let fixture = try Fixture()
        let base = try snapshot(values: [.title: "Same", .rating: "3", .dateTaken: "2024:01:02 03:04:05"], in: fixture)
        let typed: [EmbeddedField: String] = [.title: "Same", .rating: "3", .dateTaken: "2024-01-02 03:04:05", .description: "New"]
        #expect(try EmbeddedEdits.make(from: typed, snapshot: base) == [.description: "New"])
        #expect(try EmbeddedEdits.make(from: [.rating: "0", .title: ""], snapshot: base) == [.rating: "", .title: ""])
        #expect(throws: EmbeddedFailure.self) { try EmbeddedEdits.make(from: [.rating: "6"], snapshot: base) }
        #expect(throws: EmbeddedFailure.self) { try EmbeddedEdits.make(from: [.dateTaken: "soon"], snapshot: base) }
        #expect(throws: EmbeddedFailure.self) { try EmbeddedEdits.make(from: [.title: "a\u{7}b"], snapshot: base) }
        #expect(throws: EmbeddedFailure.self) {
            try EmbeddedEdits.make(from: [.title: String(repeating: "x", count: EmbeddedLimits.maxTitleLength + 1)], snapshot: base)
        }
        let readOnlyTitle = try snapshot(editable: [.rating], values: [.title: "Same"], in: fixture)
        #expect(try EmbeddedEdits.make(from: [.title: "Changed"], snapshot: readOnlyTitle).isEmpty)
    }

    @Test func removingADateNeedsAContainerThatCan() throws {
        let fixture = try Fixture()
        let keeps = try snapshot(values: [.dateTaken: "2024:01:02 03:04:05"], canRemoveDate: false, in: fixture)
        #expect(throws: EmbeddedFailure.cannotRemoveDate) { try EmbeddedEdits.make(from: [.dateTaken: "  "], snapshot: keeps) }
    }

    @Test func jpegWalkerRejectsMalformedFilesWithoutTrapping() {
        #expect(JPEGStructure.parse(Data()) == nil)
        #expect(JPEGStructure.parse(Data([0xFF, 0xD8])) == nil)
        #expect(JPEGStructure.parse(Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(JPEGStructure.parse(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])) == nil)
        #expect(JPEGStructure.parse(Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0x00])) == nil)
        #expect(JPEGStructure.parse(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01])) == nil)
        #expect(JPEGStructure.parse(Data([0xFF, 0xD8, 0xAB, 0xCD, 0x00, 0x04])) == nil)
    }

    @Test func jpegWalkerSeesLostSegmentsAndData() {
        let table = Data([0xFF, 0xDB, 0x00, 0x04, 1, 2])
        let scan = Data([0xFF, 0xDA, 0x00, 0x02, 9, 9, 0xFF, 0xD9, 0xCA, 0xFE])
        let comment = Data([0xFF, 0xFE, 0x00, 0x05]) + Data("hi!".utf8)
        let signature = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        func xmp(_ body: [UInt8]) -> Data { Data([0xFF, 0xE1, 0x00, UInt8(signature.count + body.count + 2)]) + signature + body }
        let rewritable = xmp([7, 7])
        let soi = Data([0xFF, 0xD8])
        let original = soi + rewritable + comment + table + scan
        let reordered = soi + table + comment + xmp([8, 8, 8]) + scan
        #expect(JPEGStructure.contentSurvives(from: original, in: reordered))
        #expect(!JPEGStructure.contentSurvives(from: original, in: soi + rewritable + table + scan))
        #expect(!JPEGStructure.contentSurvives(from: original, in: soi + rewritable + comment + table + scan.dropLast()))
    }
}

extension EmbeddedSnapshot {
    /// Tests only: the same file with chosen values and editable fields.
    fileprivate func withValues(_ newValues: [EmbeddedField: String], editable newEditable: Set<EmbeddedField>, canRemoveDate: Bool) -> EmbeddedSnapshot {
        EmbeddedSnapshot(url: url, stamp: stamp, typeIdentifier: typeIdentifier, values: newValues, editable: newEditable, blocked: nil,
                         support: EmbeddedSupport(fields: Set(EmbeddedField.allCases), canRemoveDate: canRemoveDate))
    }
}
