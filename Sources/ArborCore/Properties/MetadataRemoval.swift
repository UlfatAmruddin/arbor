import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "Remove Properties" as a clean image copy (FE-152): pixels copied without re-encoding, metadata
/// reduced to orientation. The original is never modified.
public enum MetadataRemoval {
    public static let supportedTypes: [UTType] = [.jpeg, .png, .heic, .tiff]

    public static func canRemove(from url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unsupported, unreadable, destinationExists, writeFailed

        public var errorDescription: String? {
            switch self {
            case .unsupported: return L10n.tr("Properties can only be removed from JPEG, PNG, HEIC and TIFF images.")
            case .unreadable: return L10n.tr("The image couldn't be read.")
            case .destinationExists: return L10n.tr("A file with the copy's name already exists.")
            case .writeFailed: return L10n.tr("The copy couldn't be written.")
            }
        }
    }

    /// Defaults to "Photo - Copy.jpg" beside the original.
    @discardableResult
    public static func createCleanCopy(of url: URL, to destination: URL? = nil) throws -> URL {
        guard canRemove(from: url) else { throw Failure.unsupported }
        let folder = url.deletingLastPathComponent()
        let target = destination ?? folder.appendingPathComponent(
            NameRules.duplicateName(for: url.lastPathComponent, treatAsFolder: false) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            })
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.destinationExists }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                         NSNumber(value: orientation))
        }
        // Temp name first so a failure never leaves a half-written copy.
        let temp = folder.appendingPathComponent(".arbor-clean-\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { throw Failure.writeFailed }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        var ok = CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error)
        if !ok {
            // Lossless copy failed (some PNGs): re-add the image without properties.
            guard let retry = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                try? FileManager.default.removeItem(at: temp)
                throw Failure.writeFailed
            }
            let keep: [CFString: Any] = orientation != 1 ? [kCGImagePropertyOrientation: orientation] : [:]
            CGImageDestinationAddImage(retry, image, keep as CFDictionary)
            ok = CGImageDestinationFinalize(retry)
        }
        guard ok else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.writeFailed
        }
        do {
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.writeFailed
        }
        return target
    }
}
