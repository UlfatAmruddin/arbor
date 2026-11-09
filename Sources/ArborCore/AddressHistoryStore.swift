import Foundation

/// The address history across launches (FE-006) and the only writer of its file. Use on the main thread.
public final class AddressHistoryStore {
    public static let storedLimit = 100
    /// Rows in the ▾ list.
    public static let listLimit = 12

    private var recent = RecentLocations(limit: storedLimit)
    /// What the last check could not find. Hidden, not forgotten, so an unplugged drive's places come back with it.
    private var hidden = Set<String>()
    private var mayWrite = true
    private var isLoaded = false
    private var loadStarted = false
    private var isChecking = false
    private var pendingSave: DispatchWorkItem?
    /// Bumped by `clear`, so a read or check already running can't bring back what it saw.
    private var generation = 0

    private let fileURL: URL?
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let checkQueue: DispatchQueue
    private let saveDelay: TimeInterval
    private let isMissing: (String) -> Bool

    /// A nil `fileURL` keeps the list in memory only (headless runs without a state folder).
    /// `checkQueue` is separate from `queue`, because a check stuck on a disk must not hold up Clear history.
    public init(fileURL: URL?, queue: DispatchQueue, callbackQueue: DispatchQueue = .main,
                checkQueue: DispatchQueue = .global(qos: .utility), saveDelay: TimeInterval = 1,
                isMissing: @escaping (String) -> Bool = AddressHistoryStore.folderIsMissing) {
        self.fileURL = fileURL
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.checkQueue = checkQueue
        self.saveDelay = saveDelay
        self.isMissing = isMissing
    }

    public var list: [Location] { Array(shown.prefix(Self.listLimit).map(\.location)) }

    /// Folders only, newest first.
    public var folderPaths: [String] { shown.compactMap(\.folderPath) }

    private var shown: [RecentLocations.Entry] { recent.records.filter { !hidden.contains($0.key) } }

    /// Reads once, in order with writes on the same queue.
    public func loadIfNeeded() {
        guard !loadStarted else { return }
        loadStarted = true
        guard let fileURL else {
            isLoaded = true
            return
        }
        let token = generation
        queue.async { [callbackQueue] in
            let load = AddressHistoryFile.load(at: fileURL, limit: Self.storedLimit)
            callbackQueue.async { [weak self] in self?.finishLoad(load, token: token) }
        }
    }

    private func finishLoad(_ load: AddressHistoryLoad, token: Int) {
        isLoaded = true
        if token == generation {
            mayWrite = !load.isNewerVersion
            recent.adoptOlder(load.entries)
        }
        if !recent.records.isEmpty { scheduleSave() }
    }

    public func record(_ location: Location) {
        guard let key = recent.record(location) else { return }
        hidden.remove(key)
        scheduleSave()
    }

    /// Clear history always removes the file, even one a newer Arbor wrote.
    public func clear() {
        generation += 1
        pendingSave?.cancel()
        pendingSave = nil
        recent.clear()
        hidden.removeAll()
        mayWrite = true
        guard let fileURL else { return }
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Writes what is pending and waits for queued file work (at exit).
    public func flush() {
        if let pendingSave {
            pendingSave.cancel()
            self.pendingSave = nil
            save()
        }
        queue.sync {}
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.save()
            self?.checkFolders()
        }
        pendingSave = item
        callbackQueue.asyncAfter(deadline: .now() + saveDelay, execute: item)
    }

    /// A failed write only costs history, and the next visit tries again.
    private func save() {
        guard let fileURL, mayWrite, let data = AddressHistoryFile.encoded(recent.records) else { return }
        queue.async { try? FolderViewStore.write(data, to: fileURL) }
    }

    /// Off the main thread and never while loading. One at a time, so a stuck disk holds up at most one thread.
    public func checkFolders() {
        guard isLoaded, !isChecking else { return }
        let folders = recent.records.compactMap { entry in entry.folderPath.map { (entry.key, $0) } }
        isChecking = true
        let token = generation
        checkQueue.async { [callbackQueue, isMissing] in
            let missing = Set(folders.filter { isMissing($0.1) }.map(\.0))
            callbackQueue.async { [weak self] in
                guard let self else { return }
                self.isChecking = false
                if token == self.generation { self.hidden = missing }
            }
        }
    }

    /// Mount table first: a folder on a share, mounted or not, is never asked about.
    public static func folderIsMissing(_ path: String) -> Bool {
        guard MountPoints.shared.volumeClass(containing: path) == .local else { return false }
        var info = stat()
        return lstat(path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }
}
