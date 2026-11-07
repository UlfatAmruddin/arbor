import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Identity of one thumbnail in the shared cache (FE-149, spec §15.3): the same path with a different
/// modification date or size is a different image, and each requested pixel size is its own entry.
public struct ThumbnailKey: Hashable, Sendable {
    public let path: String
    public let modified: TimeInterval
    public let size: Int64
    public let pixels: Int

    public init(item: FileItem, pixels: Int) {
        self.init(path: item.url.standardizedFileURL.path, modified: item.modified?.timeIntervalSinceReferenceDate ?? 0,
                  size: item.size ?? -1, pixels: pixels)
    }

    public init(path: String, modified: TimeInterval, size: Int64, pixels: Int) {
        self.path = path
        self.modified = modified
        self.size = size
        self.pixels = pixels
    }

    /// The same file version at another pixel size.
    public func resized(_ pixels: Int) -> ThumbnailKey {
        ThumbnailKey(path: path, modified: modified, size: size, pixels: pixels)
    }
}

public enum ThumbnailPolicy {
    /// Pixel sizes the views request; a larger cached size can stand in for a smaller one.
    public static func pixelSize(points: CGFloat, scale: CGFloat) -> Int { Int((points * scale).rounded(.up)) }

    /// Explorer shows thumbnails instead of icons for pictures, videos and documents with a thumbnail
    /// handler, at Medium icons and larger (windows11-reference §7). Arbor generates them for images,
    /// PDFs and movies; everything else keeps its icon. Decided by extension only (no disk access).
    public static func wantsThumbnail(_ item: FileItem, iconPoints: CGFloat, iconsOnly: Bool) -> Bool {
        guard !iconsOnly, iconPoints >= 32, !item.isFolder, !item.isPackage else { return false }
        let ext = item.url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .image) || type.conforms(to: .pdf) { return true }
        return type.conforms(to: .movie) || (type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio))
    }

    /// Image types whose pixel dimensions the Content layout shows.
    public static func hasDimensions(_ item: FileItem) -> Bool {
        guard !item.isFolder, let type = UTType(filenameExtension: item.url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Decoded bitmap cost (FE-243): pixels × 4 bytes, not the compressed file size.
    public static func decodedCost(width: Int, height: Int, bytesPerRow: Int? = nil) -> Int {
        (bytesPerRow ?? width * 4) * height
    }
}

/// Shortens a name in the middle so it fits, keeping the start and the extension visible (DEC-013).
/// `fits` measures a candidate; the search is logarithmic in the name length.
public enum MiddleTruncation {
    public static func fit(_ name: String, ellipsis: String = "…", fits: (String) -> Bool) -> String {
        if fits(name) { return name }
        let chars = Array(name)
        guard chars.count > 1 else { return name }
        // Keep `keep` characters in total, split between head and tail; the tail keeps the extension.
        var extCount = 0
        if let dot = chars.lastIndex(of: "."), dot > 0, chars.count - dot <= 12 { extCount = chars.count - dot }
        func candidate(_ keep: Int) -> String {
            let tail = keep < 2 ? keep : min(keep - 1, max(keep / 2, extCount))
            let head = keep - tail
            return String(chars[..<head]) + ellipsis + String(chars[(chars.count - tail)...])
        }
        var low = 0, high = chars.count - 1
        var best = ellipsis + String(chars.last!)
        while low <= high {
            let mid = (low + high) / 2
            let text = candidate(mid)
            if fits(text) {
                best = text
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}
