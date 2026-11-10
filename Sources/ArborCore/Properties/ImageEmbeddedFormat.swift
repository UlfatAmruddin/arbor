import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Images, through ImageIO's lossless copy; what each type stores is audited in docs/features/properties.md.
struct ImageEmbeddedFormat: EmbeddedFormat {
    let typeIdentifiers: Set<String> = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier]
    let maxFileBytes = EmbeddedLimits.maxFileBytes

    func inspect(_ url: URL, info: stat) -> EmbeddedInspection? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, typeIdentifiers.contains(type), let support = EmbeddedSupport.forType(type),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetPrimaryImageIndex(source) == 0,
              let fields = EmbeddedReader.values(in: source) else { return nil }
        var budget: EmbeddedFailure?
        do { try EmbeddedReader.checkPixelBudget(source) } catch { budget = error as? EmbeddedFailure ?? .unsupportedFile }
        var content: EmbeddedFailure?
        if type == UTType.jpeg.identifier, let head = Self.fileHead(url), JPEGStructure.holdsDataARewriteLoses(head: head) { content = .manufacturerData }
        return EmbeddedInspection(typeIdentifier: type, support: support, fields: fields, budgetBlock: budget, contentBlock: content)
    }

    /// Enough for the Exif segment and its neighbours; anything later is still caught when a save is verified.
    private static func fileHead(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        return try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).read(upToCount: 256 << 10)
    }

    func produce(_ edits: [EmbeddedField: String], from held: EmbeddedHeldFile, type: String, to staged: URL) throws {
        let bytes = try held.wholeBytes()
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == type else { throw EmbeddedFailure.changedSinceRead }
        try EmbeddedReader.checkPixelBudget(source)
        guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, type as CFString, CGImageSourceGetCount(source), nil) else {
            throw EmbeddedFailure.writeFailed
        }
        let metadata = CGImageMetadataCreateMutable()
        guard edits.allSatisfy({ Self.set($0.key, to: $0.value, in: metadata) }) else { throw EmbeddedFailure.writeFailed }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else { throw EmbeddedFailure.writeFailed }
    }

    func verify(_ edits: [EmbeddedField: String], original held: EmbeddedHeldFile, written: URL, type: String) throws {
        try EmbeddedMetadataVerifier.verify(original: try held.wholeBytes(), written: written, edits: edits, type: type)
    }

    /// Through ImageIO's own mapping, so the XMP, IPTC and Exif copies agree; an empty title or rating 0 clears it.
    private static func set(_ field: EmbeddedField, to value: String, in metadata: CGMutableImageMetadata) -> Bool {
        func put(_ dictionary: CFString, _ key: CFString, _ item: CFTypeRef) -> Bool {
            CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, item)
        }
        switch field {
        case .title: return put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName, value as CFString)
        case .description: return put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, value as CFString)
        case .rating: return put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCStarRating, NSNumber(value: Int(value) ?? 0))
        case .dateTaken:
            return put(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, value.isEmpty ? kCFNull : value as CFString)
        default: return false
        }
    }
}
