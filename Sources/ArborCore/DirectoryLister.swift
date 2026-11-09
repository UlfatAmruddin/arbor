import Foundation

public enum ListingError: Error, Equatable, LocalizedError {
    case notFound(path: String)
    case permissionDenied(path: String)
    case notAFolder(path: String)
    case pathTooLong(path: String)
    case other(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return L10n.format("“%@” doesn't exist or is no longer available.", "\(path)")
        case .permissionDenied(let path):
            return L10n.format("You don't have permission to see the contents of “%@”. You can grant access in System Settings → Privacy & Security.", "\(path)")
        case .notAFolder(let path):
            return L10n.format("“%@” is not a folder.", "\(path)")
        case .pathTooLong(let path):
            return L10n.format("The path to “%@” is too long for macOS to open. Move the folder nearer the top of the disk, or shorten its parent folders' names.", (path as NSString).lastPathComponent)
        case .other(_, let message):
            return message
        }
    }
}

/// A folder's names, however far the scan got.
public struct BoundedListing: Equatable, Sendable {
    public var entries: [PathCompletionEntry]
    /// False when the entry cap, the time limit or a read error stopped the scan.
    public var isComplete: Bool
    public var wasCancelled: Bool

    public init(entries: [PathCompletionEntry], isComplete: Bool, wasCancelled: Bool) {
        self.entries = entries
        self.isComplete = isComplete
        self.wasCancelled = wasCancelled
    }
}

/// One folder level only: disclosure arrows and folder sizes are never pre-scanned.
public enum DirectoryLister {
    public static func list(_ folder: URL, includeHidden: Bool, fileManager: FileManager = .default) throws -> [FileItem] {
        let path = folder.path
        guard PathLimits.fits(folder) else { throw ListingError.pathTooLong(path: path) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ListingError.notFound(path: path)
        }
        guard isDirectory.boolValue else { throw ListingError.notAFolder(path: path) }
        // Batched, not `contentsOfDirectory`, which holds every URL at once (~120 MB per 100k entries) and
        // never returns the memory (FE-228).
        var failure: NSError?
        let root = enumerationRoot(of: folder, fileManager: fileManager)
        var childPastLimit = false
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys, options: options,
                                                      errorHandler: { _, error in
                                                          // One such child must not end the listing for its siblings.
                                                          if FileOps.posixCode(of: error) == ENAMETOOLONG {
                                                              childPastLimit = true
                                                              return true
                                                          }
                                                          if failure == nil { failure = error as NSError }
                                                          return false
                                                      }) else {
            throw ListingError.other(path: path, message: L10n.format("“%@” couldn't be read.", "\(path)"))
        }
        var items: [FileItem] = []
        var done = false
        while !done {
            autoreleasepool {
                var batch: [URL] = []
                batch.reserveCapacity(4_096)
                while batch.count < 4_096 {
                    guard let url = enumerator.nextObject() as? URL else { done = true; break }
                    // Items keep the address the user went to, not the place the link points at.
                    batch.append(root == folder ? url : folder.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath))
                }
                items += makeItems(batch)
            }
        }
        if childPastLimit { items += itemsPastLimit(in: folder, listed: items, includeHidden: includeHidden) }
        if let failure, items.isEmpty { throw map(failure, path: path) }
        return items
    }

    /// The enumerator stops with an error on a link used as its root, so it walks what the link points at.
    private static func enumerationRoot(of folder: URL, fileManager: FileManager) -> URL {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: folder.path)) != nil else { return folder }
        return folder.resolvingSymlinksInPath()
    }

    /// Children a URL can't reach; a descriptor of their folder can still read their names and details.
    private static func itemsPastLimit(in folder: URL, listed: [FileItem], includeHidden: Bool) -> [FileItem] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        let known = Set(listed.map(\.name))
        return (FileOps.entryNames(of: fd) ?? []).filter { !known.contains($0) }.compactMap { name in
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            let isHidden = name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0
            guard includeHidden || !isHidden else { return nil }
            let url = folder.appendingPathComponent(name)
            let isFolder = (info.st_mode & S_IFMT) == S_IFDIR
            let isSymbolicLink = (info.st_mode & S_IFMT) == S_IFLNK
            return FileItem(url: url, name: name, isFolder: isFolder, isHidden: isHidden, isSymbolicLink: isSymbolicLink,
                            size: isFolder ? nil : Int64(info.st_size),
                            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                            typeDescription: TypeDescriptions.shared.describe(url, name: name, isFolder: isFolder, isPackage: false,
                                                                              isSymbolicLink: isSymbolicLink))
        }
    }

    /// Large folders in parallel chunks (reading values is about half the listing time); keeps order.
    static func makeItems(_ urls: [URL]) -> [FileItem] {
        guard urls.count >= 4_000 else { return urls.compactMap(FileItem.init(url:)) }
        let chunks = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let size = (urls.count + chunks - 1) / chunks
        final class Parts: @unchecked Sendable {
            var lists: [[FileItem]]
            let lock = NSLock()
            init(_ n: Int) { lists = Array(repeating: [], count: n) }
        }
        let parts = Parts(chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let range = min(urls.count, c * size)..<min(urls.count, (c + 1) * size)
            let made = urls[range].compactMap(FileItem.init(url:))
            parts.lock.withLock { parts.lists[c] = made }
        }
        return parts.lists.flatMap { $0 }
    }

    /// Names only, stopping at `limit` entries or `timeLimit` seconds; `list` has no cap or cancellation.
    public static func boundedEntries(of folder: URL, limit: Int, timeLimit: TimeInterval, cancellation: ScanCancellation,
                                      fileManager: FileManager = .default) -> BoundedListing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        return withoutDatalessMaterialization {
            var failed = false
            let enumerator = fileManager.enumerator(at: enumerationRoot(of: folder, fileManager: fileManager), includingPropertiesForKeys: keys,
                                                    options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                                                    errorHandler: { _, _ in
                                                        failed = true
                                                        return false
                                                    })
            var entries: [PathCompletionEntry] = []
            var finished = false
            var stopped = false
            while !finished, !stopped {
                autoreleasepool {
                    for _ in 0..<512 {
                        if cancellation.isCancelled || entries.count >= limit || ProcessInfo.processInfo.systemUptime >= deadline {
                            stopped = true
                            return
                        }
                        guard let url = enumerator?.nextObject() as? URL else {
                            finished = true
                            return
                        }
                        entries.append(PathCompletionEntry(url: url))
                    }
                }
            }
            guard !cancellation.isCancelled else { return BoundedListing(entries: [], isComplete: false, wasCancelled: true) }
            entries.sort(by: PathCompletionEntry.displayOrder)
            return BoundedListing(entries: entries, isComplete: finished && !failed, wasCancelled: false)
        }
    }

    /// Runs `body` so reads on this thread can't make a cloud provider download a placeholder folder.
    static func withoutDatalessMaterialization<T>(_ body: () -> T) -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous) } }
        return body()
    }

    /// For the navigation tree.
    public static func subfolders(of folder: URL, includeHidden: Bool) throws -> [FileItem] {
        try list(folder, includeHidden: includeHidden)
            .filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func map(_ error: NSError, path: String) -> ListingError {
        switch FileOps.posixCode(of: error) {
        case EACCES?, EPERM?: return .permissionDenied(path: path)
        case ENOENT?: return .notFound(path: path)
        default: return .other(path: path, message: error.localizedDescription)
        }
    }
}
