import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// EXIF/TIFF orientation values (1–8) as elements of the square's symmetry group: an optional
/// horizontal mirror followed by a clockwise rotation.
public enum ExifOrientation {
    private static let table: [Int: (mirrored: Bool, quarterTurns: Int)] = [
        1: (false, 0), 6: (false, 1), 3: (false, 2), 8: (false, 3),
        2: (true, 0), 7: (true, 1), 4: (true, 2), 5: (true, 3),
    ]

    /// The orientation after turning the displayed image a quarter turn.
    public static func rotated(_ orientation: Int, clockwise: Bool) -> Int {
        let current = table[orientation] ?? (false, 0)
        let turns = (current.quarterTurns + (clockwise ? 1 : 3)) % 4
        return table.first { $0.value.mirrored == current.mirrored && $0.value.quarterTurns == turns }!.key
    }
}

public enum ImageRotationError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case unreadable
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .unsupported(let kind): return "\(kind) images can't be rotated here."
        case .unreadable: return "The image couldn't be read."
        case .writeFailed: return "The rotated image couldn't be saved."
        }
    }
}

/// Rotate left / Rotate right for image files (FE-097).
///
/// JPEG, HEIC and TIFF are rotated **losslessly** by changing only the orientation tag (pixels and
/// all other metadata are copied untouched). PNG, BMP and single-frame GIF are lossless formats
/// whose orientation tag most apps ignore, so their pixels are rotated and re-encoded without loss,
/// keeping color profile, resolution and other properties. Anything else is refused.
/// The file is replaced atomically, so a failure leaves the original as it was.
public enum ImageRotator {
    public enum Method: Equatable, Sendable { case orientationTag, pixels }

    static let tagTypes: Set<String> = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, UTType.tiff.identifier]
    static let pixelTypes: Set<String> = [UTType.png.identifier, UTType.bmp.identifier, UTType.gif.identifier]
    static let extensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "tif", "tiff", "png", "bmp", "gif"]

    /// Cheap check by file extension, for showing the commands.
    public static func canRotate(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Image files that make sense as a desktop picture.
    public static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    @discardableResult
    public static func rotate(_ url: URL, clockwise: Bool) throws -> Method {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0 else {
            throw ImageRotationError.unreadable
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".arbor-rotate-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type as CFString, 1, nil) else {
            throw ImageRotationError.unsupported(url.pathExtension.uppercased())
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let current = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let method: Method
        if tagTypes.contains(type) {
            let options: [CFString: Any] = [
                kCGImageDestinationOrientation: ExifOrientation.rotated(current, clockwise: clockwise),
                kCGImageDestinationMergeMetadata: true,
            ]
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
                throw ImageRotationError.writeFailed
            }
            method = .orientationTag
        } else if pixelTypes.contains(type) {
            guard CGImageSourceGetCount(source) == 1 else { throw ImageRotationError.unsupported("Animated") }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageRotationError.unreadable }
            // Apply any existing orientation, then the quarter turn, so the result needs no tag.
            let target = ExifOrientation.rotated(current, clockwise: clockwise)
            guard let rotated = oriented(image, orientation: target) else { throw ImageRotationError.writeFailed }
            var out = props
            out[kCGImagePropertyOrientation] = 1
            out[kCGImagePropertyPixelWidth] = nil
            out[kCGImagePropertyPixelHeight] = nil
            if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                out[kCGImagePropertyTIFFDictionary] = tiff
            }
            CGImageDestinationAddImage(destination, rotated, out as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageRotationError.writeFailed }
            method = .pixels
        } else {
            throw ImageRotationError.unsupported(url.pathExtension.uppercased())
        }
        // CGImageDestinationCopyImageSource writes the file itself; it must not be finalized again.
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
        } catch {
            throw ImageRotationError.writeFailed
        }
        return method
    }

    /// The orientation currently stored in the file (1 when absent).
    public static func orientation(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 1 }
        return (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Draws `image` as displayed under an EXIF orientation.
    static func oriented(_ image: CGImage, orientation: Int) -> CGImage? {
        let w = image.width, h = image.height
        let swaps = [5, 6, 7, 8].contains(orientation)
        let outW = swaps ? h : w, outH = swaps ? w : h
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = .noneSkipLast
        default: alpha = .premultipliedLast
        }
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: alpha.rawValue) else { return nil }
        let W = CGFloat(outW), H = CGFloat(outH)
        // Transforms map the stored image (w × h) into the displayed frame (bottom-left origin).
        var t = CGAffineTransform.identity
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: W, ty: H)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: H)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: W, ty: 0)
        default: break
        }
        ctx.concatenate(t)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Explorer: dragging a folder and something inside it (possible in search results) must not copy
/// the inner item twice (FE-111). Keeps the first occurrence, in order.
public enum DragSources {
    public static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return unique.filter { url in
            !unique.contains { other in other != url && FileOps.isSameOrInside(url, other) }
        }
    }
}

/// Spring-loading timing (FE-108): a drag that stays over the same target for `delay` seconds
/// activates it once. Leaving the target, or the drag going quiet (left the view), cancels.
public struct SpringLoadTracker: Sendable {
    public let delay: TimeInterval
    /// Updates older than this mean the pointer left without an exit notice.
    public let staleAfter: TimeInterval
    public private(set) var target: String?
    private var since: TimeInterval = 0
    private var lastSeen: TimeInterval = 0
    private var fired = false

    public init(delay: TimeInterval = 0.7, staleAfter: TimeInterval = 0.4) {
        self.delay = delay
        self.staleAfter = staleAfter
    }

    /// The drag is over `target` (nil = over nothing that springs). Returns true if this is a new
    /// target, so the caller schedules a check after `delay`.
    @discardableResult
    public mutating func hover(_ target: String?, now: TimeInterval) -> Bool {
        lastSeen = now
        guard target != self.target else { return false }
        self.target = target
        since = now
        fired = false
        return target != nil
    }

    public mutating func cancel() {
        target = nil
        fired = false
    }

    /// The target to activate now, at most once per hover.
    public mutating func due(now: TimeInterval) -> String? {
        guard let target, !fired, now - since >= delay - 0.001, now - lastSeen <= staleAfter else { return nil }
        fired = true
        return target
    }
}
