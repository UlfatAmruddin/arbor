import Foundation

/// A library (FE-076): a named projection of real folders with a default save location.
/// Membership never owns files: removing a folder from a library only edits this list (FE-239).
public struct LibraryDefinition: Codable, Hashable, Sendable {
    public var name: String
    /// Included folders as normalized paths, in the order shown in "Manage library".
    public var folders: [String]
    /// Where New and Paste write. nil → the first usable folder (see `LibraryLogic.resolveSaveLocation`).
    public var saveLocation: String?

    public init(name: String, folders: [URL], saveLocation: URL? = nil) {
        self.name = name
        self.folders = []
        self.saveLocation = nil
        folders.forEach { _ = add($0) }
        if let saveLocation { setSaveLocation(saveLocation) }
    }

    public var folderURLs: [URL] { folders.map { URL(fileURLWithPath: $0) } }

    /// Adds a folder. Returns false if it is already included. The first folder becomes the save location.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        let path = Location.normalizedPath(url)
        guard !folders.contains(path) else { return false }
        folders.append(path)
        if saveLocation == nil { saveLocation = path }
        return true
    }

    /// Removes a folder from the library (never its files). If it was the save location, the next
    /// remaining folder becomes the save location, like Windows does.
    public mutating func remove(_ url: URL) {
        let path = Location.normalizedPath(url)
        guard let index = folders.firstIndex(of: path) else { return }
        folders.remove(at: index)
        if saveLocation == path {
            saveLocation = folders.isEmpty ? nil : folders[min(index, folders.count - 1)]
        }
    }

    /// Sets the save location; the folder must already be included.
    @discardableResult
    public mutating func setSaveLocation(_ url: URL) -> Bool {
        let path = Location.normalizedPath(url)
        guard folders.contains(path) else { return false }
        saveLocation = path
        return true
    }

    /// Moves a folder up or down in the list.
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
    /// `isFallback`: the chosen save location isn't usable, so another included folder is used.
    case folder(URL, isFallback: Bool)
    case unavailable(reason: String)

    public var url: URL? {
        if case .folder(let url, _) = self { return url }
        return nil
    }
}

public enum LibraryLogic {
    /// Name of the "Libraries" page (the parent of every library). Not usable as a library name.
    public static let rootName = "Libraries"
    /// Windows' default libraries, in navigation-pane order.
    public static let defaultNames = ["Documents", "Music", "Pictures", "Videos"]

    /// The default definition for a built-in library: one folder each (Videos → Movies on the Mac).
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

    /// Resolves the default save location. The explicit save location wins when it is usable
    /// (exists and is writable); otherwise the first usable included folder, flagged as a fallback;
    /// otherwise an explanation (no silent guess outside the library).
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

    /// Whether `name` can be used for a library.
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != rootName && !trimmed.contains("/")
    }
}

// MARK: - Merging folder listings

/// One included folder's listing. `folderID` identifies the folder on disk (device + inode), so the
/// same folder reached through two paths (a symlink, a firmlink) is recognized. nil = unavailable.
public struct LibrarySourceListing: Sendable {
    public var folder: URL
    public var folderID: String?
    public var items: [FileItem]
    /// Why the folder couldn't be listed, if it couldn't.
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
    /// Folders skipped because they are the same folder as one listed earlier.
    public var duplicateFolders: [URL]
    /// Folders that couldn't be listed (missing, offline, no permission).
    public var unavailable: [(folder: URL, problem: String)]
}

public enum LibraryMerge {
    /// Merges the top level of each included folder. Duplicates are removed by identity: a folder
    /// included twice (same device + inode) contributes once. Different files that share a name in
    /// different folders are all kept; hard-linked entries in different folders are different
    /// directory entries and are kept too (spec §3.2).
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

    /// Lists every included folder (one level each, never recursive) and merges them.
    public static func list(_ library: LibraryDefinition, includeHidden: Bool) -> LibraryMergeResult {
        var listed = Set<String>()
        let listings = library.folderURLs.map { folder -> LibrarySourceListing in
            guard let id = folderIdentity(folder) else {
                return LibrarySourceListing(folder: folder, folderID: nil, items: [],
                                            problem: "“\(DisplayPath.of(folder))” doesn't exist or isn't connected.")
            }
            // A folder already listed under another path is not read twice; merge reports it.
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

    /// Text for the "Folder" column: the folder's name and the path that holds it, e.g. "Documents (/Users/me)".
    public static func folderColumnText(for item: URL) -> String {
        let folder = item.standardizedFileURL.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().path
        let name = folder.lastPathComponent
        return folder.path == "/" ? "/" : "\(name) (\(parent))"
    }
}
