import AppKit
import ArborCore

/// Shared LRU of archive listings (spec §15.3), keyed by path, size, mtime and inode so a
/// replaced archive is re-read.
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

    /// Any cached listing, current or not, without disk access (main-thread lookups).
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

    /// Entries held by all cached listings (memory reporting, spec §15.3).
    var entryCount: Int { lock.withLock { cache.reduce(0) { $0 + $1.listing.entries.count } } }

    /// Keeps the `count` most recent listings (memory pressure).
    func trim(keeping count: Int) {
        lock.withLock { if cache.count > count { cache.removeLast(cache.count - count) } }
    }

    /// The member a listing row stands for.
    func entry(for item: FileItem) -> (ref: ArchiveItemRef, node: ArchiveIndex.Node?)? {
        guard let ref = Self.ref(for: item.url) else { return nil }
        return (ref, peek(ref.archive)?.index.node(at: ref.innerPath))
    }

    /// Maps a row URL to its archive: cached listings first, then by walking up.
    static func ref(for url: URL) -> ArchiveItemRef? {
        let path = url.standardizedFileURL.path
        let known = shared.lock.withLock { shared.cache.map(\.key) }
        for archive in known where path.hasPrefix(archive + "/") {
            return ArchiveItemRef(archive: URL(fileURLWithPath: archive), innerPath: String(path.dropFirst(archive.count + 1)))
        }
        return ArchiveItemRef(url: url)
    }
}

/// An archive browsed like a read-only folder (FE-163, FE-166, FE-167).
final class ArchiveProvider: LocationProvider {
    func handles(_ location: Location) -> Bool {
        if case .archive = location { return true }
        return false
    }

    /// Items kept out because their names point outside the archive or are too long.
    static func hiddenItemsNote(_ index: ArchiveIndex) -> String? {
        if index.unsafeCount > 0 {
            let items = StatusText.items(index.unsafeCount)
            return index.unsafeCount == 1
                ? L10n.format("%@ in this archive has a name that points outside it. It isn't shown and won't be extracted.", items)
                : L10n.format("%@ in this archive have names that point outside it. They aren't shown and won't be extracted.", items)
        }
        if index.tooLongCount > 0 {
            let items = StatusText.items(index.tooLongCount)
            return index.tooLongCount == 1
                ? L10n.format("%@ in this archive has a name too long to use. It isn't shown and won't be extracted.", items)
                : L10n.format("%@ in this archive have names too long to use. They aren't shown and won't be extracted.", items)
        }
        return nil
    }

    /// Listing rows that couldn't be read; shown after any damage warning, which explains them better.
    static func unreadableItemsNote(_ index: ArchiveIndex) -> String? {
        guard index.unreadableCount > 0 else { return nil }
        let items = StatusText.items(index.unreadableCount)
        return index.unreadableCount == 1
            ? L10n.format("%@ in this archive couldn't be read. It isn't shown and won't be extracted.", items)
            : L10n.format("%@ in this archive couldn't be read. They aren't shown and won't be extracted.", items)
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
                    note = L10n.format("Some items in “%@” are password-protected and can't be opened or extracted.", "\(file.lastPathComponent)")
                } else if let unsafe = Self.hiddenItemsNote(listing.index) {
                    note = unsafe
                } else if let warning = listing.warning {
                    note = L10n.format("This archive may be damaged: %@", "\(warning)")
                } else if let unreadable = Self.unreadableItemsNote(listing.index) {
                    note = unreadable
                } else if inner.isEmpty {
                    note = L10n.format("Arbor shows “%@” read-only: copy or drag items out, or use Extract all.", "\(file.lastPathComponent)")
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

    func limitation(of action: LocationAction, in location: Location) -> String? {
        action == .copy ? nil : L10n.tr("Archives are read-only here. Use Extract all, then change the extracted items.")
    }

    func emptyText(for location: Location) -> String { L10n.tr("This folder is empty.") }
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
