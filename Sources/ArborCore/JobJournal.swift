import Foundation

/// A small append-only record of one copy/move job (FE-125, FE-128, spec §9.5).
///
/// One JSON object per line: a header (job, sources, destination, process), then one event per
/// top-level item state change. Appending keeps writes O(1) per change even for huge jobs.
/// The file is deleted when the job ends normally, so any file left behind means the app
/// crashed or was quit mid-job. Writes are not fsync'd: they survive an app crash (the kernel
/// keeps them), not a power loss, which then shows fewer finished items than really finished.
/// That errs on the safe side because retry re-checks every destination.
public final class JobJournal: @unchecked Sendable {
    public struct Header: Codable, Sendable, Equatable {
        public var version = 1
        public let id: UUID
        public let pid: Int32
        public let kind: String
        public let destination: String
        public let sources: [String]
        public let started: Date
    }

    public enum ItemState: String, Codable, Sendable {
        /// The worker began writing at the destination: from here until a final state, the
        /// destination may hold a partial item.
        case started
        case committed
        /// Cross-volume move: the copy is complete, the original couldn't be removed.
        case sourceRemains
        case skipped
        case failed
        /// Stopped partway: some content may be at the destination.
        case partial
        case cancelled
    }

    struct Event: Codable {
        let i: Int
        let s: ItemState
        var d: String?
        var n: String?
    }

    public let url: URL
    public let header: Header
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    /// Creates `<id>.jsonl` in `directory` and writes the header.
    public init(directory: URL, kind: TransferKind, sources: [URL], destination: URL, id: UUID = UUID(),
                pid: Int32 = getpid()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        header = Header(id: id, pid: pid, kind: kind.rawValue, destination: destination.path,
                        sources: sources.map(\.path), started: Date())
        url = directory.appendingPathComponent("\(id.uuidString).jsonl")
        var data = try Self.encoder.encode(header)
        data.append(0x0A)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func record(_ index: Int, _ state: ItemState, destination: URL? = nil, note: String? = nil) {
        lock.withLock {
            guard !closed, let data = try? Self.encoder.encode(Event(i: index, s: state, d: destination?.path, n: note)) else { return }
            try? handle.write(contentsOf: data + [0x0A])
        }
    }

    /// The job ended (completed, cancelled or failed): its result was reported in the app,
    /// so the journal is removed.
    public func finish() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Closes the file but keeps it, as if the app had stopped here (tests and quit).
    public func abandon() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: - Recovery

    /// Journals left by processes that are no longer running. `isRunning` decides whether a
    /// pid still belongs to a live Arbor process (whose jobs are not ours to review).
    public static func interrupted(in directory: URL, isRunning: (Int32) -> Bool = JobJournal.isArborRunning) -> [InterruptedJob] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        return files.compactMap { file in
            guard let job = InterruptedJob(file: file) else {
                // Unreadable: nothing can be recovered from it.
                return nil
            }
            if job.header.pid != getpid(), isRunning(job.header.pid) { return nil }
            if job.header.pid == getpid() { return nil }
            return job
        }.sorted { $0.header.started < $1.header.started }
    }

    public static func isArborRunning(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return true }   // can't tell: assume it's alive and leave it
        return String(cString: buffer).lowercased().hasPrefix("arbor")
    }
}

/// What a leftover journal says about each top-level item.
public struct InterruptedJob: Sendable {
    public enum Status: String, Sendable {
        /// Finished (copied, moved, or the user skipped it).
        case completed
        /// Never started, failed, or cancelled before writing anything: safe to retry.
        case notDone
        /// Was being written when the app stopped: the destination may hold a partial item.
        case uncertain
    }

    public struct Item: Sendable, Equatable {
        public let source: URL
        public let status: Status
        public let state: JobJournal.ItemState?
        /// Where it went (completed) or was going (uncertain), if known.
        public let destination: URL?
        public let note: String?
    }

    public let file: URL
    public let header: JobJournal.Header
    public let items: [Item]

    public var kind: TransferKind { TransferKind(rawValue: header.kind) ?? .copy }
    public var destination: URL { URL(fileURLWithPath: header.destination) }
    public var completed: [Item] { items.filter { $0.status == .completed } }
    public var notDone: [Item] { items.filter { $0.status == .notDone } }
    public var uncertain: [Item] { items.filter { $0.status == .uncertain } }

    /// Sources a retry should offer: not done or uncertain, and still present. Retrying goes
    /// through the normal job, which re-checks every destination and asks about conflicts, so
    /// an existing same-named item is never assumed to be the finished copy (FE-128).
    public var retryableSources: [URL] {
        items.filter { $0.status != .completed }.map(\.source).filter(FileOps.exists)
    }

    init?(file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let first = lines.first, let header = try? decoder.decode(JobJournal.Header.self, from: Data(first.utf8)) else { return nil }
        var last: [Int: JobJournal.Event] = [:]
        for line in lines.dropFirst() {
            // A torn final line (crash mid-write) is ignored.
            guard let event = try? decoder.decode(JobJournal.Event.self, from: Data(line.utf8)),
                  header.sources.indices.contains(event.i) else { continue }
            var merged = event
            if merged.d == nil { merged.d = last[event.i]?.d }
            last[event.i] = merged
        }
        self.file = file
        self.header = header
        items = header.sources.enumerated().map { index, path in
            let event = last[index]
            let status: Status
            switch event?.s {
            case .committed?, .sourceRemains?, .skipped?: status = .completed
            case .started?, .partial?: status = .uncertain
            case .failed?, .cancelled?, nil: status = .notDone
            }
            return Item(source: URL(fileURLWithPath: path), status: status, state: event?.s,
                        destination: event?.d.map { URL(fileURLWithPath: $0) }, note: event?.n)
        }
    }

    /// Deletes the journal (after review).
    public func discard() { try? FileManager.default.removeItem(at: file) }
}
