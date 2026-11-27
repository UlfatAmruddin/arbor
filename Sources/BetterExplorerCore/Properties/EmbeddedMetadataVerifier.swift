import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Proves a rewritten image still holds everything the original did (FE-152). Any doubt refuses the change.
enum EmbeddedMetadataVerifier {
    static func verify(original: Data, written: URL, edits: [EmbeddedField: String], type: String) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let bytes = readWritten(written),
              let before = CGImageSourceCreateWithData(original as CFData, options),
              let after = CGImageSourceCreateWithData(bytes as CFData, options),
              CGImageSourceGetType(after) as String? == type,
              CGImageSourceGetCount(after) == CGImageSourceGetCount(before),
              (try? EmbeddedReader.checkPixelBudget(after)) != nil,
              framesMatch(before, after),
              fieldsMatch(before, after, edits: edits),
              propertiesSurvive(before, after, edited: Set(edits.keys)),
              tagsSurvive(before, after, edited: Set(edits.keys)),
              type != UTType.jpeg.identifier || JPEGStructure.contentSurvives(from: original, in: bytes, removableTags: removableTags(Set(edits.keys)),
                                                                                changeableIPTC: changeableIPTC(Set(edits.keys))) else {
            throw EmbeddedFailure.verificationFailed
        }
    }

    /// Read back whole, bounded by the same limit as the original; a bit of growth is allowed for the new text.
    private static func readWritten(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: Int(EmbeddedLimits.maxFileBytes) + 1 << 20)
    }

    /// Same frames, decoded pixel for pixel and with the same auxiliary images (depth, mattes, gain maps).
    private static func framesMatch(_ before: CGImageSource, _ after: CGImageSource) -> Bool {
        for index in 0..<CGImageSourceGetCount(before) {
            guard let a = frameDigest(before, index), let b = frameDigest(after, index), a == b,
                  auxiliaryData(before, index) == auxiliaryData(after, index) else { return false }
        }
        return true
    }

    /// One frame at a time, so a many-frame file never holds two decoded images at once.
    private static func frameDigest(_ source: CGImageSource, _ index: Int) -> SHA256.Digest? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return autoreleasepool { () -> SHA256.Digest? in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, options),
                  let pixels = image.dataProvider?.data as Data? else { return nil }
            var hasher = SHA256()
            hasher.update(data: withUnsafeBytes(of: (image.width, image.height, image.bitsPerPixel)) { Data($0) })
            hasher.update(data: pixels)
            return hasher.finalize()
        }
    }

    private static let auxiliaryTypes: [CFString] = {
        var types = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return types
    }()

    private static func auxiliaryData(_ source: CGImageSource, _ index: Int) -> [String: Data] {
        var found: [String: Data] = [:]
        for type in auxiliaryTypes {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [CFString: Any],
                  let data = info[kCGImageAuxiliaryDataInfoData] as? Data else { continue }
            found[type as String] = data
        }
        return found
    }

    private static func fieldsMatch(_ before: CGImageSource, _ after: CGImageSource, edits: [EmbeddedField: String]) -> Bool {
        guard let old = EmbeddedReader.values(in: before), let new = EmbeddedReader.values(in: after) else { return false }
        return EmbeddedField.allCases.allSatisfy { field in
            let expected = edits[field] ?? old[field]?.text
            return (new[field]?.text ?? "") == (expected ?? "")
        }
    }

    /// Keys each edited field is allowed to change in ImageIO's property dictionaries.
    private static func changeable(_ edited: Set<EmbeddedField>) -> Set<String> {
        var keys = Set<String>()
        if edited.contains(.title) { keys.insert(kCGImagePropertyIPTCObjectName as String) }
        if edited.contains(.description) {
            keys.formUnion([kCGImagePropertyTIFFImageDescription as String, kCGImagePropertyIPTCCaptionAbstract as String])
        }
        if edited.contains(.rating) { keys.insert(kCGImagePropertyIPTCStarRating as String) }
        if edited.contains(.dateTaken) {
            keys.formUnion([kCGImagePropertyExifDateTimeOriginal as String, kCGImagePropertyIPTCDateCreated as String,
                            kCGImagePropertyIPTCTimeCreated as String])
        }
        return keys
    }

    /// Exif tags a cleared field takes with it.
    private static func removableTags(_ edited: Set<EmbeddedField>) -> Set<Int> {
        var tags = Set<Int>()
        if edited.contains(.description) { tags.insert(ExifStructure.imageDescription) }
        if edited.contains(.dateTaken) { tags.insert(ExifStructure.dateTimeOriginal) }
        return tags
    }

    /// IPTC datasets each edited field rewrites, as observed in ImageIO's output; a rating touches none.
    private static func changeableIPTC(_ edited: Set<EmbeddedField>) -> Set<IPTCStructure.DataSet> {
        var sets = Set<IPTCStructure.DataSet>()
        if edited.contains(.title) { sets.insert(IPTCStructure.objectName) }
        if edited.contains(.description) { sets.insert(IPTCStructure.caption) }
        if edited.contains(.dateTaken) { sets.formUnion([IPTCStructure.dateCreated, IPTCStructure.timeCreated]) }
        return sets
    }

    /// Everything else ImageIO saw before is still there unchanged: camera data, GPS, orientation, profile.
    private static func propertiesSurvive(_ before: CGImageSource, _ after: CGImageSource, edited: Set<EmbeddedField>) -> Bool {
        let allowed = changeable(edited)
        for index in 0..<CGImageSourceGetCount(before) {
            guard let old = CGImageSourceCopyPropertiesAtIndex(before, index, nil) as? [String: Any],
                  let new = CGImageSourceCopyPropertiesAtIndex(after, index, nil) as? [String: Any] else { return false }
            for (key, value) in old {
                if let group = value as? [String: Any] {
                    guard let replaced = new[key] as? [String: Any] else { return false }
                    for (inner, item) in group where !allowed.contains(inner) {
                        guard let other = replaced[inner], same(item, other) else { return false }
                    }
                } else {
                    guard let other = new[key], same(value, other) else { return false }
                }
            }
        }
        return true
    }

    private static func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    private static let maxTags = 4096, maxDepth = 8

    /// XMP paths each edited field may change; "iio:" marks are ImageIO's own bookkeeping.
    private static func editedPaths(_ edited: Set<EmbeddedField>) -> Set<String> {
        var paths = Set<String>()
        if edited.contains(.title) { paths.insert("dc:title") }
        if edited.contains(.description) { paths.insert("dc:description") }
        if edited.contains(.rating) { paths.insert("xmp:Rating") }
        if edited.contains(.dateTaken) { paths.formUnion(["photoshop:DateCreated", "photoshop:DateTimeOriginal", "exif:DateTimeOriginal"]) }
        return paths
    }

    /// Unknown XMP namespaces and every other tag survive with their values.
    private static func tagsSurvive(_ before: CGImageSource, _ after: CGImageSource, edited: Set<EmbeddedField>) -> Bool {
        let skip = editedPaths(edited)
        guard let old = tagMap(before), let new = tagMap(after) else { return false }
        return old.allSatisfy { key, value in skip.contains(key) || key.hasPrefix("iio:") || new[key] == value }
    }

    /// nil past the tag budget. Files with no XMP give an empty map.
    private static func tagMap(_ source: CGImageSource) -> [String: String]? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [:] }
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag], tags.count <= maxTags else { return nil }
        var map: [String: String] = [:]
        var budget = maxTags
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
                  let value = canonical(CGImageMetadataTagCopyValue(tag), depth: 0, budget: &budget) else { return nil }
            map["\(prefix):\(name)"] = value
        }
        return map
    }

    /// Stable text for a tag value; `description` would embed object addresses.
    private static func canonical(_ value: Any?, depth: Int, budget: inout Int) -> String? {
        budget -= 1
        guard budget >= 0, depth <= maxDepth, let value else { return nil }
        if CFGetTypeID(value as CFTypeRef) == CGImageMetadataTagGetTypeID() {
            return canonical(CGImageMetadataTagCopyValue(unsafeDowncast(value as CFTypeRef, to: CGImageMetadataTag.self)), depth: depth + 1, budget: &budget)
        }
        if let text = value as? String { return text }
        if let list = value as? [Any] {
            var parts: [String] = []
            for item in list {
                guard let part = canonical(item, depth: depth + 1, budget: &budget) else { return nil }
                parts.append(part)
            }
            return "[" + parts.joined(separator: "\u{1F}") + "]"
        }
        if let map = value as? [String: Any] {
            var parts: [String] = []
            for key in map.keys.sorted() {
                guard let item = map[key], let part = canonical(item, depth: depth + 1, budget: &budget) else { return nil }
                parts.append("\(key)=\(part)")
            }
            return "{" + parts.joined(separator: "\u{1F}") + "}"
        }
        return "\(value)"
    }
}

/// Walks a JPEG's segments without decoding: compressed data, tables and anything not rewritten must survive byte for byte.
enum JPEGStructure {
    static let maxSegments = 4096

    private enum Role { case exif, xmp, photoshop, rewritten, kept }

    /// By signature, not marker: Extended XMP, FLIR and the like share APP1 but ImageIO doesn't carry them over.
    private static func role(marker: UInt8, payload: Data) -> Role {
        func signed(_ text: String) -> Bool { payload.starts(with: Data(text.utf8)) }
        switch marker {
        case 0xE1 where signed(exifSignature): return .exif
        case 0xE1 where signed("http://ns.adobe.com/xap/1.0/\0"): return .xmp
        case 0xED where signed("Photoshop 3.0\0"): return .photoshop
        case 0xE0 where signed("JFIF\0"), 0xE2 where signed("MPF\0"): return .rewritten
        default: return .kept
        }
    }

    private static let exifSignature = "Exif\0\0"

    struct Parsed: Equatable {
        var segments: [Data: Int] = [:]
        /// The TIFF block of the first Exif segment.
        var exif: Data?
        var hasXMP = false
        /// Every Photoshop segment, signature included.
        var photoshop: [Data] = []
        var scan = Data()
    }

    /// nil unless `data` is a JPEG whose segments are well formed up to the first scan.
    static func parse(_ data: Data) -> Parsed? {
        var parsed = Parsed()
        return walk(data, into: &parsed) ? parsed : nil
    }

    /// True when the start of a JPEG holds data a rewrite is known to lose, so the edit needn't be offered.
    static func holdsDataARewriteLoses(head: Data) -> Bool {
        var parsed = Parsed()
        _ = walk(head, into: &parsed)
        let hasMakerNote = parsed.exif.flatMap(ExifStructure.read).map { !$0.makerNote.isEmpty } ?? false
        let iptcIsSafe = IPTCStructure.read(parsed.photoshop).map(IPTCStructure.rewriteKeeps) ?? false
        return hasMakerNote || !iptcIsSafe || parsed.segments.keys.contains { $0.first == 0xE1 }
    }

    /// False when `data` is malformed or ends before a scan; what was read until then stays in `parsed`.
    private static func walk(_ data: Data, into parsed: inout Parsed) -> Bool {
        var index = data.startIndex
        guard data.count >= 4, data[index] == 0xFF, data[index + 1] == 0xD8 else { return false }
        index += 2
        var count = 0
        while index < data.endIndex {
            guard data[index] == 0xFF else { return false }
            while index < data.endIndex, data[index] == 0xFF { index += 1 }
            guard index < data.endIndex else { return false }
            let marker = data[index]
            index += 1
            if marker == 0xDA {
                parsed.scan = data[(index - 2)...]
                return true
            }
            // Only SOI, EOI and the restart markers are standalone, and none belongs before a scan.
            guard !(0xD0...0xD9).contains(marker), marker != 0x01, marker != 0x00 else { return false }
            count += 1
            guard count <= maxSegments, index + 2 <= data.endIndex else { return false }
            let length = Int(data[index]) << 8 | Int(data[index + 1])
            guard length >= 2, index + length <= data.endIndex else { return false }
            let payload = data[(index + 2)..<(index + length)]
            // ImageIO reads one Exif and one XMP segment, so a second of either is data it would drop.
            switch role(marker: marker, payload: payload) {
            case .exif where parsed.exif == nil: parsed.exif = payload.dropFirst(exifSignature.utf8.count)
            case .xmp where !parsed.hasXMP: parsed.hasXMP = true
            case .photoshop: parsed.photoshop.append(payload)
            case .rewritten: break
            default: parsed.segments[Data([marker]) + payload, default: 0] += 1
            }
            index += length
        }
        return false
    }

    /// Everything from the first scan to the end of the file, trailing data included, stays byte for byte.
    static func contentSurvives(from original: Data, in written: Data, removableTags: Set<Int> = [],
                                changeableIPTC: Set<IPTCStructure.DataSet> = []) -> Bool {
        guard let before = parse(original), let after = parse(written) else { return false }
        return before.scan == after.scan && before.segments.allSatisfy { after.segments[$0.key] == $0.value }
            && exifSurvives(before.exif, in: after.exif, removable: removableTags)
            && iptcSurvives(before.photoshop, in: after.photoshop, changeable: changeableIPTC)
    }

    private static func iptcSurvives(_ original: [Data], in written: [Data], changeable: Set<IPTCStructure.DataSet>) -> Bool {
        guard !original.isEmpty else { return true }
        guard let before = IPTCStructure.read(original), let after = IPTCStructure.read(written) else { return false }
        return IPTCStructure.survives(before, in: after, changeable: changeable)
    }

    private static func exifSurvives(_ original: Data?, in written: Data?, removable: Set<Int>) -> Bool {
        guard let original else { return true }
        guard let written, let before = ExifStructure.read(original), let after = ExifStructure.read(written) else { return false }
        return ExifStructure.survives(before, in: after, removable: removable)
    }
}
