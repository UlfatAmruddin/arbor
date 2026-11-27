import Foundation

/// A named projection of real folders with a save location (FE-076); removing a folder never touches its files (FE-239).
public struct LibraryDefinition: Codable, Hashable, Sendable {
    public var name: String
    /// Normalized paths, in "Manage library" order.
    public var folders: [String]
    /// Where New and Paste write; nil means the first usable folder.
    public var saveLocation: String?
    /// "Optimize library for": the view defaults (FE-076).
    public var template: FolderTemplate

    /// Without a template, the one the name suggests.
    public init(name: String, folders: [URL], saveLocation: URL? = nil, template: FolderTemplate? = nil) {
        self.name = name
        self.folders = []
        self.saveLocation = nil
        self.template = template ?? LibraryLogic.defaultTemplate(named: name)
        folders.forEach { _ = add($0) }
        if let saveLocation { setSaveLocation(saveLocation) }
    }

    /// A missing or unknown template (older or hand-edited data) falls back to the name's.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        folders = try container.decode([String].self, forKey: .folders)
        saveLocation = try container.decodeIfPresent(String.self, forKey: .saveLocation)
        let raw = (try? container.decodeIfPresent(String.self, forKey: .template)) ?? nil
        template = raw.flatMap(FolderTemplate.init(rawValue:)) ?? LibraryLogic.defaultTemplate(named: name)
    }

    public var folderURLs: [URL] { folders.map { URL(fileURLWithPath: $0) } }

    public enum AddOutcome: Sendable {
        case added, alreadyIncluded, full
    }

    /// The first folder becomes the save location.
    @discardableResult
    public mutating func add(_ url: URL) -> AddOutcome {
        let path = Location.normalizedPath(url)
        guard !folders.contains(path) else { return .alreadyIncluded }
        guard folders.count < LibraryLogic.maxFolders else { return .full }
        folders.append(path)
        if saveLocation == nil { saveLocation = path }
        return .added
    }

    /// Never touches files. If it was the save location, the next folder takes over, as in Windows.
    public mutating func remove(_ url: URL) {
        let path = Location.normalizedPath(url)
        guard let index = folders.firstIndex(of: path) else { return }
        folders.remove(at: index)
        if saveLocation == path {
            saveLocation = folders.isEmpty ? nil : folders[min(index, folders.count - 1)]
        }
    }

    /// The folder must already be included.
    @discardableResult
    public mutating func setSaveLocation(_ url: URL) -> Bool {
        let path = Location.normalizedPath(url)
        guard folders.contains(path) else { return false }
        saveLocation = path
        return true
    }

    /// Stops at either end of the list. The order decides which folder takes over as the save location (FE-238).
    public mutating func move(_ url: URL, by offset: Int) {
        let path = Location.normalizedPath(url)
        guard let index = folders.firstIndex(of: path) else { return }
        let target = min(max(index + offset, 0), folders.count - 1)
        guard target != index else { return }
        folders.remove(at: index)
        folders.insert(path, at: target)
    }
}

/// Where New/Paste in a library go (FE-238).
public enum SaveLocationResolution: Equatable, Sendable {
    /// `isFallback`: the chosen save location isn't usable, so another folder is used.
    case folder(URL, isFallback: Bool)
    case unavailable(reason: String)

    public var url: URL? {
        if case .folder(let url, _) = self { return url }
        return nil
    }
}

public enum LibraryEditError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case reserved
    case taken(String)
    case notFound(String)
    case tooMany

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .reserved: return L10n.format("“%@” is the name of the page that lists your libraries. Choose a different name.", LibraryLogic.rootName)
        case .taken(let name): return L10n.format("There's already a library named “%@”.", LibraryLogic.quotable(name))
        case .notFound(let name): return L10n.format("The “%@” library doesn't exist. It may have been removed.", LibraryLogic.quotable(name))
        case .tooMany: return L10n.tr("There are too many libraries or folders to save. Remove some, then try again.")
        }
    }
}

public enum LibraryLogic {
    /// The parent page of every library; reserved as a library name.
    public static let rootName = "Libraries"
    /// Windows' default libraries, in navigation-pane order.
    public static let defaultNames = ["Documents", "Music", "Pictures", "Videos"]
    /// Each folder costs a watcher and a listing.
    public static let maxFolders = 64
    /// Names show in tabs, tiles and breadcrumbs.
    public static let maxNameLength = 120

    /// One folder each; Videos maps to Movies on the Mac.
    public static func defaultDefinition(named name: String, home: URL) -> LibraryDefinition? {
        let folder: String
        switch name {
        case "Documents": folder = "Documents"
        case "Music": folder = "Music"
        case "Pictures": folder = "Pictures"
        case "Videos": folder = "Movies"
        default: return nil
        }
        return LibraryDefinition(name: name, folders: [home.appendingPathComponent(folder)])
    }

    public static func defaults(home: URL) -> [LibraryDefinition] {
        defaultNames.compactMap { defaultDefinition(named: $0, home: home) }
    }

    public static func defaultTemplate(named name: String) -> FolderTemplate {
        switch name {
        case "Documents": return .documents
        case "Music": return .music
        case "Pictures": return .pictures
        case "Videos": return .videos
        default: return .generalItems
        }
    }

    /// The chosen save location if usable, else the first usable folder (a fallback), else an explanation; never a guess outside the library.
    public static func resolveSaveLocation(_ library: LibraryDefinition, isUsable: (URL) -> Bool) -> SaveLocationResolution {
        guard !library.folders.isEmpty else {
            return .unavailable(reason: L10n.format("The “%@” library doesn't include any folders. Use Manage library to include a folder, then try again.", library.name))
        }
        if let chosen = library.saveLocation, library.folders.contains(chosen), isUsable(URL(fileURLWithPath: chosen)) {
            return .folder(URL(fileURLWithPath: chosen), isFallback: false)
        }
        if let first = library.folders.first(where: { isUsable(URL(fileURLWithPath: $0)) }) {
            return .folder(URL(fileURLWithPath: first), isFallback: library.saveLocation != nil)
        }
        return .unavailable(reason: L10n.format("None of the folders in the “%@” library can be written to right now. Connect the drive, or use Manage library to choose a save location you can write to.", library.name))
    }

    /// What the status bar says after a library loads, or nil. One message, because a second would replace the first.
    public static func loadNote(unavailable: [URL], resolution: SaveLocationResolution) -> String? {
        var notes: [String] = []
        if case .folder(let url, isFallback: true) = resolution {
            notes.append(L10n.format("The save location isn't available, so “%@” is used instead.", url.lastPathComponent))
        }
        if !unavailable.isEmpty {
            notes.append(L10n.format("Some folders in this library aren't available, so it may be incomplete: %@", DisplayPath.quotedList(unavailable)))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    // MARK: Names

    /// The name as stored, or why it can't be used.
    public static func cleanedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if let problem = NameRules.validate(name) { throw LibraryEditError.invalid(problem.localizedDescription) }
        guard name.count <= maxNameLength else {
            throw LibraryEditError.invalid(L10n.format("A library name can have at most %@ characters.", "\(maxNameLength)"))
        }
        guard !name.unicodeScalars.contains(where: isUnsafeInName) else {
            throw LibraryEditError.invalid(L10n.tr("A library name can't contain invisible or text-direction characters."))
        }
        guard !sameName(name, rootName) else { throw LibraryEditError.reserved }
        return name
    }

    /// `Location.library` is case-exact, so names that differ only by case or width must not coexist.
    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// Invisible characters could disguise a name in tabs and tiles; joiners and tag characters stay because emoji and some scripts need them.
    private static func isUnsafeInName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true
        case .format:
            return ![0x200C, 0x200D].contains(scalar.value) && !(0xE0020...0xE007F).contains(scalar.value)
        default:
            return false
        }
    }

    /// A long name would crowd out the sentence quoting it.
    static func quotable(_ name: String) -> String {
        let limit = 40
        return name.count <= limit ? name : String(name.prefix(limit - 1)) + "…"
    }

    // MARK: Identity

    /// Where a library's saved view is filed; never treated as a path.
    public static func viewIdentity(named name: String) -> FolderIdentity {
        let key = Location.library(name).key
        return FolderIdentity(id: key, path: key)
    }

    /// `location` after a library was renamed, or nil if it doesn't involve that library.
    public static func location(_ location: Location, afterRenaming old: String, to new: String) -> Location? {
        switch location {
        case .library(old):
            return .library(new)
        case .search(var request) where request.originKey == Location.library(old).key:
            request.originKey = Location.library(new).key
            return .search(request)
        default:
            return nil
        }
    }
}

// MARK: - Merging folder listings

/// One included folder's listing. `folderID` (device + inode) catches the same folder via two paths; nil = unavailable.
public struct LibrarySourceListing: Sendable {
    public var folder: URL
    public var folderID: String?
    public var items: [FileItem]
    /// Why the folder couldn't be listed.
    public var problem: String?

    public init(folder: URL, folderID: String?, items: [FileItem], problem: String? = nil) {
        self.folder = folder
        self.folderID = folderID
        self.items = items
        self.problem = problem
    }
}

public struct LibraryMergeResult: Sendable {
    public var items: [FileItem]
    /// Same folder as one listed earlier.
    public var duplicateFolders: [URL]
    /// Missing, offline or no permission.
    public var unavailable: [(folder: URL, problem: String)]
}

public enum LibraryMerge {
    /// Merges each folder's top level. A folder included twice (same device + inode) counts once;
    /// same-named or hard-linked entries in different folders are all kept (spec §3.2).
    public static func merge(_ sources: [LibrarySourceListing]) -> LibraryMergeResult {
        var seenFolders = Set<String>()
        var seenEntries = Set<String>()
        var result = LibraryMergeResult(items: [], duplicateFolders: [], unavailable: [])
        for source in sources {
            guard let id = source.folderID else {
                result.unavailable.append((source.folder, source.problem ?? L10n.format("“%@” isn't available.", DisplayPath.of(source.folder))))
                continue
            }
            guard seenFolders.insert(id).inserted else {
                result.duplicateFolders.append(source.folder)
                continue
            }
            for item in source.items where seenEntries.insert(id + "/" + item.name).inserted {
                result.items.append(item)
            }
        }
        return result
    }

    /// "device:inode" of a folder, following symlinks. nil if it doesn't exist or isn't a folder.
    public static func folderIdentity(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// The folder that items of `folder` show under in a merged listing. Touches the disk.
    public static func listedFolder(_ folder: URL) -> URL { folder.resolvingSymlinksInPath() }

    /// One level per folder, never recursive. `isCancelled` is checked between folders: any of them can stall when offline.
    public static func list(_ library: LibraryDefinition, includeHidden: Bool, isCancelled: () -> Bool = { false }) -> LibraryMergeResult {
        var listed = Set<String>()
        var listings: [LibrarySourceListing] = []
        for folder in library.folderURLs {
            if isCancelled() { break }
            guard let id = folderIdentity(folder) else {
                listings.append(LibrarySourceListing(folder: folder, folderID: nil, items: [],
                                                     problem: L10n.format("“%@” doesn't exist or isn't connected.", DisplayPath.of(folder))))
                continue
            }
            // Already listed under another path: not read twice; merge reports it.
            guard listed.insert(id).inserted else {
                listings.append(LibrarySourceListing(folder: folder, folderID: id, items: []))
                continue
            }
            do {
                let items = try DirectoryLister.list(listedFolder(folder), includeHidden: includeHidden)
                listings.append(LibrarySourceListing(folder: folder, folderID: id, items: items))
            } catch {
                listings.append(LibrarySourceListing(folder: folder, folderID: nil, items: [], problem: error.localizedDescription))
            }
        }
        return merge(listings)
    }

    /// "Folder" column text, e.g. "Documents (/Users/me)".
    public static func folderColumnText(for item: URL) -> String {
        let folder = item.standardizedFileURL.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().path
        let name = folder.lastPathComponent
        return folder.path == "/" ? "/" : "\(name) (\(parent))"
    }
}
