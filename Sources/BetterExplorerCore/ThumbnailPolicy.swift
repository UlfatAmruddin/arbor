import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Shared-cache key (FE-149, spec §15.3): another modification date, size or pixel size is another entry.
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

    public func resized(_ pixels: Int) -> ThumbnailKey {
        ThumbnailKey(path: path, modified: modified, size: size, pixels: pixels)
    }
}

public enum ThumbnailPolicy {
    /// A larger cached size can stand in for a smaller one.
    public static func pixelSize(points: CGFloat, scale: CGFloat) -> Int { Int((points * scale).rounded(.up)) }

    /// Thumbnails for images, PDFs and movies at Medium icons and up, like Explorer (windows11-reference §7);
    /// other files keep their icon. Decided by extension only (no disk access).
    public static func wantsThumbnail(_ item: FileItem, iconPoints: CGFloat, iconsOnly: Bool) -> Bool {
        guard !iconsOnly, iconPoints >= 32, !item.isFolder, !item.isPackage else { return false }
        let ext = item.url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .image) || type.conforms(to: .pdf) { return true }
        return type.conforms(to: .movie) || (type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio))
    }

    /// What the Details pane's preview area shows.
    public enum PanePreview: Equatable, Sendable {
        /// Type or custom icon: folders, packages, and text (its thumbnail looks blank).
        case icon
        /// Picture, video frame or PDF/office page from the system thumbnail generator.
        case thumbnail
        /// A rendered document page, bordered so a white page shows on the white pane.
        case page
    }

    /// Like Explorer's Details pane: a thumbnail where a handler exists, else the type icon. Plain text, code,
    /// CSV, JSON, Markdown and logs show the icon (their thumbnail is a near-blank page).
    public static func panePreview(_ item: FileItem, iconsOnly: Bool) -> PanePreview {
        guard !iconsOnly, !item.isFolder, !item.isPackage else { return .icon }
        if wantsThumbnail(item, iconPoints: 128, iconsOnly: false) {
            let type = UTType(filenameExtension: item.url.pathExtension)
            return type?.conforms(to: .pdf) == true ? .page : .thumbnail
        }
        let ext = item.url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.conforms(to: .text) else { return .icon }
        return type.conforms(to: .compositeContent) ? .page : .icon
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

/// Middle-truncates a name to fit, keeping start and extension (DEC-013); binary search over `fits`.
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
