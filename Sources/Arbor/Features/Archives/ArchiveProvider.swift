import AppKit
import ArborCore

/// Listings of recently browsed archives, shared by every window and tab (a small LRU, spec §15.3).
/// A listing is keyed by path plus size, modification date and inode, so a replaced archive is re-read.
final class ArchiveCatalog: @unchecked Sendable {
    static let shared = ArchiveCatalog()

    struct Listing {
        let archive: URL
        let entries: [ArchiveEntry]
        let index: ArchiveIndex
        let warning: String?
        let stamp: String
    }

    private let lock = NSLock()
    private var cache: [(key: String, listing: Listing)] = []
    private let capacity = 4

    static func stamp(of url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)-\(info.st_ino)"
    }

    /// A cached listing that is still current (no disk access beyond one stat).
    func cached(_ archive: URL) -> Listing? {
        let path = archive.standardizedFileURL.path
        guard let stamp = Self.stamp(of: archive) else { return nil }
        return lock.withLock {
            guard let i = cache.firstIndex(where: { $0.key == path }), cache[i].listing.stamp == stamp else { return nil }
            let hit = cache.remove(at: i)
            cache.insert(hit, at: 0)
            return hit.listing
        }
    }

    /// Any cached listing, current or not, without touching the disk (for item lookups on the main thread).
    func peek(_ archive: URL) -> Listing? {
        let path = archive.standardizedFileURL.path
        return lock.withLock { cache.first { $0.key == path }?.listing }
    }

    /// Lists the archive (blocking; call off the main thread).
    func load(_ archive: URL, process: ToolProcess) throws -> Listing {
        if let hit = cached(archive) { return hit }
        guard let stamp = Self.stamp(of: archive) else {
            throw ArchiveError.unreadable("“\(archive.lastPathComponent)” is no longer available.")
        }
        let listing = try ArchiveTool.list(archive, process: process)
        let result = Listing(archive: archive.standardizedFileURL, entries: listing.entries,
                             index: ArchiveIndex(entries: listing.entries), warning: listing.warning, stamp: stamp)
        lock.withLock {
            cache.removeAll { $0.key == result.archive.path }
            cache.insert((result.archive.path, result), at: 0)
            if cache.count > capacity { cache.removeLast(cache.count - capacity) }
        }
        return result
    }

    /// The member a listing row stands for.
    func entry(for item: FileItem) -> (ref: ArchiveItemRef, node: ArchiveIndex.Node?)? {
        guard let ref = Self.ref(for: item.url) else { return nil }
        return (ref, peek(ref.archive)?.index.node(at: ref.innerPath))
    }

    /// Maps a row URL to its archive: first through cached listings (no disk access), then by walking up.
    static func ref(for url: URL) -> ArchiveItemRef? {
        let path = url.standardizedFileURL.path
        let known = shared.lock.withLock { shared.cache.map(\.key) }
        for archive in known where path.hasPrefix(archive + "/") {
            return ArchiveItemRef(archive: URL(fileURLWithPath: archive), innerPath: String(path.dropFirst(archive.count + 1)))
        }
        return ArchiveItemRef(url: url)
    }
}

/// `.archive(file, innerPath)` locations: an archive browsed like a folder (FE-163, FE-166, FE-167).
/// Read-only: New, Rename, Delete, Cut and Paste are unavailable here.
final class ArchiveProvider: LocationProvider {
    func handles(_ location: Location) -> Bool {
        if case .archive = location { return true }
        return false
    }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard case .archive(let file, let inner) = location else { return nil }
        let handle = LoadHandle()
        let process = ToolProcess()
        handle.onCancel = { process.cancel() }
        let includeHidden = context.showHidden
        weak let host = context.host
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<LocationContent, Error>
            var note: String?
            var noteIsError = true
            do {
                let listing = try ArchiveCatalog.shared.load(file, process: process)
                if listing.index.encryptedCount > 0 {
                    note = "Some items in “\(file.lastPathComponent)” are password-protected and can't be opened or extracted."
                } else if listing.index.unsafeCount > 0 {
                    note = "\(StatusText.items(listing.index.unsafeCount)) in this archive \(listing.index.unsafeCount == 1 ? "has a name" : "have names") that point outside it. They aren't shown and won't be extracted."
                } else if let warning = listing.warning {
                    note = "This archive may be damaged: \(warning)"
                } else if inner.isEmpty {
                    note = "Arbor shows “\(file.lastPathComponent)” read-only: copy or drag items out, or use Extract all."
                    noteIsError = false
                }
                guard let items = listing.index.items(in: inner, archive: listing.archive, includeHidden: includeHidden) else {
                    throw ArchiveError.unreadable("“\(inner)” isn't a folder in “\(file.lastPathComponent)”.")
                }
                result = .success(.items(items))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                completion(result)
                if let note { host?.showStatusMessage(note, isError: noteIsError) }
            }
        }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        guard case .archive(let file, _) = location else { return nil }
        // Re-list when the archive is replaced or rewritten (its folder changes).
        let watcher = DirectoryWatcher()
        let stamp = ArchiveCatalog.stamp(of: file)
        watcher.watch(file.deletingLastPathComponent()) {
            if ArchiveCatalog.stamp(of: file) != stamp { onChange() }
        }
        return watcher
    }

    func title(for location: Location) -> String { location.displayName }

    func icon(for location: Location, size: CGFloat) -> NSImage {
        guard case .archive(let file, let inner) = location else { return IconProvider.shared.icon(for: location, size: size) }
        if inner.isEmpty { return IconProvider.shared.fileIcon(file, size: size) }
        return IconProvider.shared.folderIcon(size: size)
    }

    func targetFolder(for location: Location) -> URL? { nil }
    func allowsItemEditing(in location: Location) -> Bool { false }
    func emptyText(for location: Location) -> String { "This folder is empty." }
}

extension Location {
    var archiveFile: URL? {
        if case .archive(let file, _) = self { return file }
        return nil
    }

    var archiveInnerPath: String? {
        if case .archive(_, let inner) = self { return inner }
        return nil
    }
}
