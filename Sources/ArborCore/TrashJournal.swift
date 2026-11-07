import Foundation

/// What Arbor remembers about an item it moved to the Trash (FE-077): where it came from and when.
/// macOS gives third-party apps no public API for Finder's "Put Back" data, so only items trashed
/// through `SystemTrash.trash` have a record; everything else shows "Unknown" (spec §12.4).
public struct TrashRecord: Codable, Equatable, Sendable {
    /// Where the item is now (inside a Trash folder).
    public var trashedPath: String
    /// Full path the item had before it was trashed.
    public var originalPath: String
    public var dateDeleted: Date
    /// File identity (inode and device) at trashing time, so a different item that later lands at
    /// the same Trash path is never given this record.
    public var fileID: UInt64?
    public var device: Int64?

    public init(trashedPath: String, originalPath: String, dateDeleted: Date, fileID: UInt64? = nil, device: Int64? = nil) {
        self.trashedPath = trashedPath
        self.originalPath = originalPath
        self.dateDeleted = dateDeleted
        self.fileID = fileID
        self.device = device
    }

    public var originalURL: URL { URL(fileURLWithPath: originalPath) }
    /// The folder the item came from ("Original Location" column).
    public var originalFolder: String { (originalPath as NSString).deletingLastPathComponent }
    public var originalName: String { (originalPath as NSString).lastPathComponent }
}

/// Persistent map from trashed path to `TrashRecord`. Thread-safe; writes are coalesced and flushed
/// at exit. Bounded to `maxRecords` (oldest dropped) and pruned whenever a Trash folder is listed.
public final class TrashJournal: @unchecked Sendable {
    public static let shared = TrashJournal(fileURL: defaultURL)

    /// Headless runs keep the journal next to the test Trash, never in the user's Library.
    public static var defaultURL: URL {
        if let dir = SystemTrash.testDirectory {
            return dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".arbor-journal.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Arbor/TrashJournal.json")
    }

    public static let maxRecords = 20_000

    public let fileURL: URL
    private let saveDelay: TimeInterval
    private let lock = NSLock()
    private var records: [String: TrashRecord]?
    private var saveScheduled = false
    private let queue = DispatchQueue(label: "arbor.trash-journal", qos: .utility)

    /// `saveDelay` 0 writes synchronously (tests); otherwise writes are coalesced.
    public init(fileURL: URL, saveDelay: TimeInterval = 0.4) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
    }

    // MARK: Writing

    public func record(original: URL, trashed: URL, date: Date = Date()) {
        var info = stat()
        let hasID = lstat(trashed.path, &info) == 0
        let entry = TrashRecord(trashedPath: Self.key(trashed), originalPath: Self.key(original), dateDeleted: date,
                                fileID: hasID ? UInt64(info.st_ino) : nil, device: hasID ? Int64(info.st_dev) : nil)
        mutate { records in
            records[entry.trashedPath] = entry
            if records.count > Self.maxRecords {
                let oldest = records.values.sorted { $0.dateDeleted < $1.dateDeleted }.prefix(records.count - Self.maxRecords)
                oldest.forEach { records[$0.trashedPath] = nil }
            }
        }
    }

    public func remove(_ trashed: [URL]) {
        guard !trashed.isEmpty else { return }
        mutate { records in trashed.forEach { records[Self.key($0)] = nil } }
    }

    /// Drops records for items that are no longer in `folder` (emptied, put back, or deleted elsewhere).
    /// `existing` holds the paths currently inside the folder. Records for other folders are kept.
    public func prune(folder: URL, existing: Set<String>) {
        let prefix = Self.key(folder) + "/"
        let present = Set(existing.map { Self.key(URL(fileURLWithPath: $0)) })
        mutate { records in
            for key in records.keys where key.hasPrefix(prefix) && !present.contains(key) {
                // Only direct children are listed; deeper paths can't be records.
                records[key] = nil
            }
        }
    }

    // MARK: Reading

    /// The record for an item currently in the Trash, if Arbor trashed it. The item's identity must
    /// still match, so a different file at the same path never inherits a record.
    public func lookup(_ trashed: URL) -> TrashRecord? {
        let key = Self.key(trashed)
        lock.lock()
        loadIfNeeded()
        let record = records?[key]
        lock.unlock()
        guard let record else { return nil }
        var info = stat()
        guard lstat(trashed.path, &info) == 0 else { return nil }
        if let id = record.fileID, id != UInt64(info.st_ino) { return nil }
        if let dev = record.device, dev != Int64(info.st_dev) { return nil }
        return record
    }

    public var allRecords: [TrashRecord] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return records.map { Array($0.values) } ?? []
    }

    /// Writes pending changes now (also runs at process exit).
    public func flush() {
        lock.lock()
        let snapshot = saveScheduled ? records : nil
        saveScheduled = false
        lock.unlock()
        if let snapshot { write(snapshot) }
    }

    // MARK: Storage

    static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func mutate(_ change: (inout [String: TrashRecord]) -> Void) {
        lock.lock()
        loadIfNeeded()
        var current = records ?? [:]
        change(&current)
        records = current
        let alreadyScheduled = saveScheduled
        saveScheduled = true
        lock.unlock()
        if saveDelay <= 0 {
            flush()
        } else if !alreadyScheduled {
            Self.registerExitFlush()
            queue.asyncAfter(deadline: .now() + saveDelay) { [weak self] in self?.flush() }
        }
    }

    /// Call with `lock` held.
    private func loadIfNeeded() {
        guard records == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.journal.decode([TrashRecord].self, from: data) else {
            records = [:]
            return
        }
        records = Dictionary(list.map { ($0.trashedPath, $0) }, uniquingKeysWith: { a, b in a.dateDeleted > b.dateDeleted ? a : b })
    }

    private func write(_ records: [String: TrashRecord]) {
        let list = records.values.sorted { $0.trashedPath < $1.trashedPath }
        guard let data = try? JSONEncoder.journal.encode(list) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let exitFlushOnce: Void = {
        atexit { TrashJournal.shared.flush() }
    }()

    private static func registerExitFlush() { _ = exitFlushOnce }
}

private extension JSONEncoder {
    static var journal: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var journal: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
