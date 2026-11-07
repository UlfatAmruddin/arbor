import Foundation
import UniformTypeIdentifiers

// `FolderTemplate` ("Optimize this folder for") is defined with the Properties › Customize store in
// ArborCore/Properties/FolderTemplates.swift. Folder Options persists it in its view database.
extension FolderTemplate: Codable {}

extension FolderTemplate {
    /// The Details column-set key for this template (grouping's `FolderKind`; Downloads is added by location).
    public var folderKind: FolderKind {
        switch self {
        case .generalItems: return .general
        case .documents: return .documents
        case .pictures: return .pictures
        case .music: return .music
        case .videos: return .videos
        }
    }
}

/// Presentation of a folder (spec §3.2 "View"). Every field is optional so layers can be merged:
/// a nil field means "inherit from the layer below". Persisting this never touches the folder itself
/// (no `.DS_Store`, FE-248). Columns and Group by use the Details column model (`ColumnSpec`, `ColumnID`).
public struct FolderViewSettings: Codable, Equatable, Sendable {
    public var viewMode: String?
    /// Primary sort column (`SortKey` raw value or any `ColumnID`).
    public var sortKey: String?
    public var ascending: Bool?
    public var foldersFirst: Bool?
    /// Group-by column ("" = explicitly not grouped).
    public var groupBy: String?
    public var groupAscending: Bool?
    /// Details columns in display order (shown columns only; Name first).
    public var columns: [ColumnSpec]?

    public init(viewMode: String? = nil, sortKey: String? = nil, ascending: Bool? = nil, foldersFirst: Bool? = nil,
                groupBy: String? = nil, groupAscending: Bool? = nil, columns: [ColumnSpec]? = nil) {
        self.viewMode = viewMode
        self.sortKey = sortKey
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.groupBy = groupBy
        self.groupAscending = groupAscending
        self.columns = columns
    }

    public var isEmpty: Bool { self == FolderViewSettings() }

    /// Fields set here win; the rest come from `base`.
    public func merged(over base: FolderViewSettings) -> FolderViewSettings {
        FolderViewSettings(viewMode: viewMode ?? base.viewMode, sortKey: sortKey ?? base.sortKey,
                           ascending: ascending ?? base.ascending, foldersFirst: foldersFirst ?? base.foldersFirst,
                           groupBy: groupBy ?? base.groupBy, groupAscending: groupAscending ?? base.groupAscending,
                           columns: columns ?? base.columns)
    }

    /// The sort fields as a `FileSortOrder` (any Details column can be the primary key).
    public var sortOrder: FileSortOrder {
        var order = FileSortOrder(key: .name, ascending: ascending ?? true, foldersFirst: foldersFirst ?? true)
        if let raw = sortKey, !raw.isEmpty { order.setPrimary(ColumnID(raw), ascending: ascending ?? true, keepPrevious: false) }
        return order
    }

    public mutating func setSort(_ order: FileSortOrder) {
        sortKey = order.primaryColumn.rawValue
        ascending = order.ascending
        foldersFirst = order.foldersFirst
    }
}

/// Where the settings on screen come from (FE-052: a visible source).
public enum ViewSettingsSource: Equatable, Sendable {
    case appDefault
    /// The folder type's default: built in, or set with "Apply to Folders" (`applied`).
    case template(FolderTemplate, applied: Bool)
    /// Saved for this one folder.
    case folder

    public var description: String {
        switch self {
        case .appDefault: return "Default view"
        case .template(let t, let applied):
            return applied ? "Applied to all \(t.title) folders" : "\(t.title) folder type"
        case .folder: return "Saved for this folder"
        }
    }
}

public struct ResolvedViewSettings: Equatable, Sendable {
    /// Populated except `columns`, `groupBy` and `groupAscending`, where nil means "the folder type's column set".
    public var settings: FolderViewSettings
    public var source: ViewSettingsSource
    public var template: FolderTemplate
}

/// Precedence (FE-052, spec §6.5): app default → folder template → explicit folder override.
/// The template's Details columns and default grouping come from the column-set store (grouping feature);
/// this resolver covers view mode and sort and passes through column/group overrides.
public enum ViewSettingsResolver {
    public static let appDefault = FolderViewSettings(viewMode: "details", sortKey: "name", ascending: true, foldersFirst: true)

    /// Built-in template defaults (reference §5.1; RECALL). Pictures and Videos open in Large icons.
    public static func builtIn(_ template: FolderTemplate) -> FolderViewSettings {
        switch template {
        case .generalItems, .documents, .music: return FolderViewSettings()
        case .pictures, .videos: return FolderViewSettings(viewMode: "largeIcons")
        }
    }

    public static func resolve(template: FolderTemplate, applied: FolderViewSettings?, override: FolderViewSettings?,
                               appDefault: FolderViewSettings = appDefault) -> ResolvedViewSettings {
        let builtIn = builtIn(template)
        var settings = builtIn.merged(over: appDefault)
        // A typed folder (Pictures, Music…) shows its type as the source: its column set comes from it.
        var source: ViewSettingsSource = template == .generalItems && builtIn.isEmpty ? .appDefault : .template(template, applied: false)
        if let applied, !applied.isEmpty {
            settings = applied.merged(over: settings)
            source = .template(template, applied: true)
        }
        if let override, !override.isEmpty {
            settings = override.merged(over: settings)
            source = .folder
        }
        return ResolvedViewSettings(settings: settings, source: source, template: template)
    }
}

// MARK: - Folder type discovery

/// Picks a template from the folder's location and content (Windows' "folder type discovery", reference §5.1).
/// Pure and in-memory: it only looks at names already listed, never at file contents.
public enum FolderTemplateDetector {
    public struct KnownFolders: Sendable {
        public var documents: [URL]
        public var pictures: [URL]
        public var music: [URL]
        public var videos: [URL]
        public var downloads: [URL]

        public init(documents: [URL] = [], pictures: [URL] = [], music: [URL] = [], videos: [URL] = [], downloads: [URL] = []) {
            self.documents = documents
            self.pictures = pictures
            self.music = music
            self.videos = videos
            self.downloads = downloads
        }

        /// The user's Documents, Pictures, Music, Movies and Downloads folders.
        public static var user: KnownFolders {
            let fm = FileManager.default
            func dir(_ d: FileManager.SearchPathDirectory) -> [URL] { fm.urls(for: d, in: .userDomainMask) }
            return KnownFolders(documents: dir(.documentDirectory), pictures: dir(.picturesDirectory),
                                music: dir(.musicDirectory), videos: dir(.moviesDirectory), downloads: dir(.downloadsDirectory))
        }
    }

    /// A folder's type: its template plus the Details column-set kind.
    public struct Resolution: Equatable, Sendable {
        public var template: FolderTemplate
        public var kind: FolderKind
        /// Chosen in Properties › Customize (or inherited from an ancestor's "apply to all subfolders").
        public var chosen: Bool
    }

    /// Precedence: the folder's Properties › Customize choice → Downloads (its own column set) → a known
    /// folder or one inside it → content discovery → General items.
    public static func resolve(folder: URL, items: [FileItem], chosen: FolderTemplate?, known: KnownFolders = .user) -> Resolution {
        if let chosen { return Resolution(template: chosen, kind: chosen.folderKind, chosen: true) }
        let path = Location.normalizedPath(folder)
        if known.downloads.contains(where: { Location.normalizedPath($0) == path }) {
            return Resolution(template: .generalItems, kind: .downloads, chosen: false)
        }
        let template = detect(folder: folder, items: items, known: known)
        return Resolution(template: template, kind: template.folderKind, chosen: false)
    }

    /// Share of the files that must belong to one kind (folders don't count).
    public static let threshold = 0.5

    public static func detect(folder: URL, items: [FileItem], known: KnownFolders = .user) -> FolderTemplate {
        let path = Location.normalizedPath(folder)
        let byLocation: [(FolderTemplate, [URL])] = [(.documents, known.documents), (.pictures, known.pictures),
                                                     (.music, known.music), (.videos, known.videos)]
        // The known folder itself or a folder inside it (Downloads' subfolders are ordinary folders).
        for (template, urls) in byLocation where urls.contains(where: {
            let base = Location.normalizedPath($0)
            return path == base || path.hasPrefix(base + "/")
        }) {
            return template
        }
        return detect(items: items)
    }

    public static func detect(items: [FileItem]) -> FolderTemplate {
        var counts: [FolderTemplate: Int] = [:]
        var files = 0
        for item in items where !item.isFolder && !item.isHidden {
            files += 1
            if let kind = kind(of: item.name) { counts[kind, default: 0] += 1 }
        }
        guard files > 0 else { return .generalItems }
        // Ties go to the first in this order.
        var best = FolderTemplate.generalItems
        var bestCount = 0
        for template in [FolderTemplate.pictures, .videos, .music, .documents] where (counts[template] ?? 0) > bestCount {
            best = template
            bestCount = counts[template] ?? 0
        }
        return Double(bestCount) / Double(files) >= threshold ? best : .generalItems
    }

    static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp",
                                                 "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "svg", "psd", "ico", "avif"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts", "flv"]
    static let musicExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "oga", "wma", "alac", "opus", "m4b", "mid", "midi"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "rtfd", "md",
                                                  "pages", "numbers", "key", "odt", "ods", "odp", "csv", "epub", "tex", "xps"]

    /// The template a single file's name suggests, if any.
    public static func kind(of name: String) -> FolderTemplate? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if pictureExtensions.contains(ext) { return .pictures }
        if videoExtensions.contains(ext) { return .videos }
        if musicExtensions.contains(ext) { return .music }
        if documentExtensions.contains(ext) { return .documents }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) { return .pictures }
        if type.conforms(to: .movie) { return .videos }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { return .documents }
        return nil
    }
}

// MARK: - Stable folder identity

/// Identifies a folder for saved views (FE-041, spec §3.2): the volume UUID plus the folder's file
/// number, so a rename or move inside the volume keeps its view. Volumes without a UUID (some network
/// shares) fall back to the path.
public struct FolderIdentity: Hashable, Codable, Sendable {
    /// "vol:<UUID>:ino:<number>", or nil when only the path is known.
    public let id: String?
    public let path: String

    public init(id: String?, path: String) {
        self.id = id
        self.path = path
    }

    public static func pathOnly(_ url: URL) -> FolderIdentity { FolderIdentity(id: nil, path: Location.normalizedPath(url)) }

    /// Reads the identity with one `stat` and a cached volume UUID. Call off the main thread for slow volumes.
    public static func of(_ url: URL) -> FolderIdentity {
        let path = Location.normalizedPath(url)
        var info = stat()
        guard stat(path, &info) == 0 else { return FolderIdentity(id: nil, path: path) }
        guard let uuid = VolumeUUIDCache.uuid(device: info.st_dev, url: url) else { return FolderIdentity(id: nil, path: path) }
        return FolderIdentity(id: "vol:\(uuid):ino:\(info.st_ino)", path: path)
    }
}

/// Volume UUIDs by device number (one lookup per mounted volume).
enum VolumeUUIDCache {
    private static let lock = NSLock()
    private static var cache: [Int32: String?] = [:]

    static func uuid(device: Int32, url: URL) -> String? {
        lock.lock()
        if let hit = cache[device] { lock.unlock(); return hit }
        lock.unlock()
        let value = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        lock.lock()
        cache[device] = .some(value)
        lock.unlock()
        return value
    }

    /// Volumes were mounted or unmounted: device numbers may be reused.
    static func reset() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

public enum FolderIdentityCache {
    /// Call when volumes mount or unmount.
    public static func volumesChanged() { VolumeUUIDCache.reset() }
}
