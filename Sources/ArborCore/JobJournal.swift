import Foundation

/// Append-only JSONL record of one copy/move job (FE-125, FE-128, spec §9.5): header, `{"run":true}` once started, then one event per item change.
/// Deleted on normal end, so a leftover file means a crash or quit mid-job.
/// Not fsync'd: survives an app crash but not power loss, which is safe since retry re-checks every destination.
public final class JobJournal: @unchecked Sendable {
    public struct Header: Codable, Sendable, Equatable {
        /// 2 adds the run marker (`markRunning`).
        public var version = 2
        public let id: UUID
        public let pid: Int32
        public let kind: String
        public let destination: String
        public let sources: [String]
        public let started: Date
    }

    public enum ItemState: String, Codable, Sendable {
        /// Writing began; until a final state the destination may hold a partial item.
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

    struct RunMarker: Codable {
        let run: Bool
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

    /// Job left the queue. Without this line, the job was still queued when the app stopped.
    public func markRunning() {
        lock.withLock {
            guard !closed, let data = try? Self.encoder.encode(RunMarker(run: true)) else { return }
            try? handle.write(contentsOf: data + [0x0A])
        }
    }

    public func record(_ index: Int, _ state: ItemState, destination: URL? = nil, note: String? = nil) {
        lock.withLock {
            guard !closed, let data = try? Self.encoder.encode(Event(i: index, s: state, d: destination?.path, n: note)) else { return }
            try? handle.write(contentsOf: data + [0x0A])
        }
    }

    /// Job ended and its result was reported, so the journal is removed.
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

    /// Journals left by dead processes; `isRunning` spots live Arbor pids, whose jobs aren't ours.
    public static func interrupted(in directory: URL, isRunning: (Int32) -> Bool = JobJournal.isArborRunning) -> [InterruptedJob] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        return files.compactMap { file in
            guard let job = InterruptedJob(file: file) else {
                // Unreadable: nothing to recover.
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
    /// Still queued when the app stopped: nothing of it happened.
    public let wasWaiting: Bool

    public var kind: TransferKind { TransferKind(rawValue: header.kind) ?? .copy }
    public var destination: URL { URL(fileURLWithPath: header.destination) }
    public var completed: [Item] { items.filter { $0.status == .completed } }
    public var notDone: [Item] { items.filter { $0.status == .notDone } }
    public var uncertain: [Item] { items.filter { $0.status == .uncertain } }

    /// Unfinished sources that still exist. Retry re-checks destinations, so a same-named item is never assumed finished (FE-128).
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
        var ran = false
        for line in lines.dropFirst() {
            if let marker = try? decoder.decode(JobJournal.RunMarker.self, from: Data(line.utf8)), marker.run { ran = true; continue }
            // A torn final line (crash mid-write) is ignored.
            guard let event = try? decoder.decode(JobJournal.Event.self, from: Data(line.utf8)),
                  header.sources.indices.contains(event.i) else { continue }
            var merged = event
            if merged.d == nil { merged.d = last[event.i]?.d }
            last[event.i] = merged
        }
        self.file = file
        self.header = header
        // Version 1 journals can't tell; treat them as started.
        wasWaiting = header.version >= 2 && !ran && last.isEmpty
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

    public func discard() { try? FileManager.default.removeItem(at: file) }
}
