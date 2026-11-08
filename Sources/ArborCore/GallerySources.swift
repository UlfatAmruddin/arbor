import Foundation

/// One Gallery folder; unchecking `included` hides its photos but keeps it in the collection.
public struct GallerySource: Codable, Hashable, Sendable {
    public var path: String
    public var included: Bool

    public init(_ url: URL, included: Bool = true) {
        path = Location.normalizedPath(url)
        self.included = included
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// The Gallery's folder list (FE-075). Editing it never touches files (FE-239).
public struct GalleryCollection: Codable, Hashable, Sendable {
    public var sources: [GallerySource]

    public init(sources: [GallerySource]) { self.sources = sources }

    /// The Pictures folder, matching Gallery's default Pictures library.
    public static func defaults(home: URL) -> GalleryCollection {
        GalleryCollection(sources: [GallerySource(home.appendingPathComponent("Pictures"))])
    }

    /// False if already present or excluded.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        let source = GallerySource(url)
        guard !GalleryScanRules.isExcluded(path: source.path),
              !sources.contains(where: { $0.path == source.path }) else { return false }
        sources.append(source)
        return true
    }

    /// Files are not affected.
    public mutating func remove(_ url: URL) {
        let path = Location.normalizedPath(url)
        sources.removeAll { $0.path == path }
    }

    public mutating func setIncluded(_ url: URL, _ included: Bool) {
        let path = Location.normalizedPath(url)
        for i in sources.indices where sources[i].path == path { sources[i].included = included }
    }

    /// Included sources minus those nested in another included one (the outer scan finds them).
    public var scanRoots: [URL] {
        let included = sources.filter(\.included).map(\.path)
        return included.filter { path in
            !included.contains { other in other != path && GalleryScanRules.isInside(path, other) }
        }.map { URL(fileURLWithPath: $0) }
    }
}

/// What Gallery scans and what it leaves alone.
public enum GalleryScanRules {
    /// Never scanned: their originals belong to Photos, and touching them can damage the library.
    public static let libraryPackageExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "migratedaplibrary", "migratedphotoslibrary",
        "fcpbundle", "imovielibrary", "tvlibrary", "musiclibrary",
    ]

    /// Inside (or naming) a photo/media library package; the scan skips hidden files and other packages itself.
    public static func isExcluded(path: String) -> Bool {
        for component in path.split(separator: "/") {
            if let dot = component.lastIndex(of: "."),
               libraryPackageExtensions.contains(component[component.index(after: dot)...].lowercased()) { return true }
        }
        return false
    }

    /// `path` is inside `folder` (not equal).
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let base = folder == "/" ? "/" : folder + "/"
        return path.hasPrefix(base) && path != folder
    }

    /// The innermost source containing `path`.
    public static func source(of path: String, in collection: GalleryCollection) -> GallerySource? {
        collection.sources.filter { isInside(path, $0.path) }.max { $0.path.count < $1.path.count }
    }

    /// Shown if its innermost source is included (an unchecked subfolder hides even under a checked parent).
    public static func isVisible(path: String, in collection: GalleryCollection) -> Bool {
        source(of: path, in: collection)?.included ?? false
    }

    /// Fallback when Spotlight has no type information.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "avif",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw", "jxl",
    ]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts", "m2ts", "webm", "wmv"]

    public static func kind(forExtension ext: String) -> GalleryMediaKind? {
        let e = ext.lowercased()
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        return nil
    }

    /// Spotlight content type tree → kind (images before movies; "public.movie" covers video).
    public static func kind(forContentTypeTree tree: [String]) -> GalleryMediaKind? {
        if tree.contains("public.image") { return .image }
        if tree.contains("public.movie") || tree.contains("public.video") { return .video }
        return nil
    }
}

/// Gallery items merged from scan batches (spec §15.3), keyed by path; only the newest `limit` are kept.
public struct GalleryItemSet: Sendable {
    public let limit: Int
    public private(set) var byKey: [String: GalleryItem] = [:]
    public private(set) var droppedForLimit = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public var count: Int { byKey.count }

    public mutating func insert(_ items: [GalleryItem]) {
        for item in items { byKey[item.key] = item }
        trim()
    }

    public mutating func remove(keys: [String]) {
        keys.forEach { byKey[$0] = nil }
    }

    /// Drops items whose key fails `keep` (deleted files after a full rescan).
    public mutating func retain(_ keep: (String) -> Bool) {
        byKey = byKey.filter { keep($0.key) }
    }

    private mutating func trim() {
        guard byKey.count > limit else { return }
        let newest = byKey.values.sorted { $0.date > $1.date }
        droppedForLimit += byKey.count - limit
        byKey = Dictionary(uniqueKeysWithValues: newest.prefix(limit).map { ($0.key, $0) })
    }

    public var all: [GalleryItem] { Array(byKey.values) }
}
