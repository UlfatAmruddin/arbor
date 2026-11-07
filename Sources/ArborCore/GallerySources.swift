import Foundation

/// One folder in the Gallery collection. `included` is the check mark in "Collection ▾":
/// unchecking hides the folder's photos without removing the folder from the collection.
public struct GallerySource: Codable, Hashable, Sendable {
    public var path: String
    public var included: Bool

    public init(_ url: URL, included: Bool = true) {
        path = Location.normalizedPath(url)
        self.included = included
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// The Gallery collection's folder list (FE-075). Removing a folder only changes this list; it never
/// touches files (FE-239).
public struct GalleryCollection: Codable, Hashable, Sendable {
    public var sources: [GallerySource]

    public init(sources: [GallerySource]) { self.sources = sources }

    /// Default collection: the Pictures folder (Gallery's default is the Pictures library).
    public static func defaults(home: URL) -> GalleryCollection {
        GalleryCollection(sources: [GallerySource(home.appendingPathComponent("Pictures"))])
    }

    /// Adds a folder; returns false if it is already in the collection or can't be a source.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        let source = GallerySource(url)
        guard !GalleryScanRules.isExcluded(path: source.path),
              !sources.contains(where: { $0.path == source.path }) else { return false }
        sources.append(source)
        return true
    }

    /// Removes a folder from the collection. Files are not affected.
    public mutating func remove(_ url: URL) {
        let path = Location.normalizedPath(url)
        sources.removeAll { $0.path == path }
    }

    public mutating func setIncluded(_ url: URL, _ included: Bool) {
        let path = Location.normalizedPath(url)
        for i in sources.indices where sources[i].path == path { sources[i].included = included }
    }

    /// Folders to scan: included sources without those nested inside another included source
    /// (their photos are found once, by the outer scan).
    public var scanRoots: [URL] {
        let included = sources.filter(\.included).map(\.path)
        return included.filter { path in
            !included.contains { other in other != path && GalleryScanRules.isInside(path, other) }
        }.map { URL(fileURLWithPath: $0) }
    }
}

/// What Gallery scans and what it leaves alone.
public enum GalleryScanRules {
    /// Photo-library packages are never scanned: their originals belong to Photos, and changing them
    /// behind its back can damage the library.
    public static let libraryPackageExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "migratedaplibrary", "migratedphotoslibrary",
        "fcpbundle", "imovielibrary", "tvlibrary", "musiclibrary",
    ]

    /// True for a path inside (or naming) a photo-library or media-library package. Hidden files and
    /// other packages are skipped by the scan itself.
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

    /// The included source that contains `path`, for "which folder is this photo from".
    public static func source(of path: String, in collection: GalleryCollection) -> GallerySource? {
        collection.sources.filter { isInside(path, $0.path) }.max { $0.path.count < $1.path.count }
    }

    /// Whether an item at `path` is shown: it must be inside an included source and not inside an
    /// excluded one that is nested deeper (unchecking a subfolder hides it even if its parent is checked).
    public static func isVisible(path: String, in collection: GalleryCollection) -> Bool {
        source(of: path, in: collection)?.included ?? false
    }

    /// File extensions treated as photos or videos when Spotlight has no type information.
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

/// A bounded set of Gallery items merged from incremental scan batches (spec §15.3).
/// Keyed by path; when more than `limit` items exist, only the newest are kept.
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

    /// Keeps only items whose key passes `keep` (used to drop deleted files after a full rescan).
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
