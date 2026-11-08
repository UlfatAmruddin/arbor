import Foundation

/// A named projection of real folders with a save location (FE-076); removing a folder never touches its files (FE-239).
public struct LibraryDefinition: Codable, Hashable, Sendable {
    public var name: String
    /// Normalized paths, in "Manage library" order.
    public var folders: [String]
    /// Where New and Paste write; nil means the first usable folder.
    public var saveLocation: String?

    public init(name: String, folders: [URL], saveLocation: URL? = nil) {
        self.name = name
        self.folders = []
        self.saveLocation = nil
        folders.forEach { _ = add($0) }
        if let saveLocation { setSaveLocation(saveLocation) }
    }

    public var folderURLs: [URL] { folders.map { URL(fileURLWithPath: $0) } }

    /// False if already included. The first folder becomes the save location.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        let path = Location.normalizedPath(url)
        guard !folders.contains(path) else { return false }
        folders.append(path)
        if saveLocation == nil { saveLocation = path }
        return true
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

public enum LibraryLogic {
    /// The parent page of every library; reserved as a library name.
    public static let rootName = "Libraries"
    /// Windows' default libraries, in navigation-pane order.
    public static let defaultNames = ["Documents", "Music", "Pictures", "Videos"]

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

    /// The chosen save location if usable, else the first usable folder (a fallback), else an explanation; never a guess outside the library.
    public static func resolveSaveLocation(_ library: LibraryDefinition, isUsable: (URL) -> Bool) -> SaveLocationResolution {
        guard !library.folders.isEmpty else {
            return .unavailable(reason: "The “\(library.name)” library doesn't include any folders. Use Manage library to include a folder, then try again.")
        }
        if let chosen = library.saveLocation, library.folders.contains(chosen), isUsable(URL(fileURLWithPath: chosen)) {
            return .folder(URL(fileURLWithPath: chosen), isFallback: false)
        }
        if let first = library.folders.first(where: { isUsable(URL(fileURLWithPath: $0)) }) {
            return .folder(URL(fileURLWithPath: first), isFallback: library.saveLocation != nil)
        }
        return .unavailable(reason: "None of the folders in the “\(library.name)” library can be written to right now. Connect the drive, or use Manage library to choose a save location you can write to.")
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != rootName && !trimmed.contains("/")
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
                result.unavailable.append((source.folder, source.problem ?? "“\(DisplayPath.of(source.folder))” isn't available."))
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

    /// One level per folder, never recursive.
    public static func list(_ library: LibraryDefinition, includeHidden: Bool) -> LibraryMergeResult {
        var listed = Set<String>()
        let listings = library.folderURLs.map { folder -> LibrarySourceListing in
            guard let id = folderIdentity(folder) else {
                return LibrarySourceListing(folder: folder, folderID: nil, items: [],
                                            problem: "“\(DisplayPath.of(folder))” doesn't exist or isn't connected.")
            }
            // Already listed under another path: not read twice; merge reports it.
            guard listed.insert(id).inserted else { return LibrarySourceListing(folder: folder, folderID: id, items: []) }
            do {
                let items = try DirectoryLister.list(folder.resolvingSymlinksInPath(), includeHidden: includeHidden)
                return LibrarySourceListing(folder: folder, folderID: id, items: items)
            } catch {
                return LibrarySourceListing(folder: folder, folderID: nil, items: [], problem: error.localizedDescription)
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
