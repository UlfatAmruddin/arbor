import Foundation

/// Decides when copy and move jobs start (FE-127). With both options off (default) all start at once, like Windows.
/// - `queueSameDrive`: a job waits while a running job uses one of its drives; jobs on other drives still start.
/// - `concurrencyLimit`: at most this many run (0 = no limit); a job waiting for its drive doesn't block others.
/// - Waiting jobs can be reordered. "Defer" waits until nothing else runs or waits; "Start now" ignores the rules.
public struct TransferScheduler: Sendable, Equatable {
    public enum State: String, Sendable { case waiting, running }

    public struct Entry: Sendable, Equatable {
        public let id: UUID
        /// Volume identities the job reads or writes.
        public let drives: Set<String>
        public var state: State
        public var deferred: Bool
    }

    /// The limits a person can choose, in menu order.
    public static let concurrencyLimitChoices = [0, 1, 2, 3, 4]

    public static func concurrencyLimitTitle(_ limit: Int) -> String {
        switch limit {
        case 0: return L10n.tr("No limit")
        case 1: return L10n.tr("1 operation at a time")
        default: return L10n.format("%d operations at a time", limit)
        }
    }

    public var queueSameDrive: Bool
    public var concurrencyLimit: Int
    public private(set) var entries: [Entry] = []

    public init(queueSameDrive: Bool = false, concurrencyLimit: Int = 0) {
        self.queueSameDrive = queueSameDrive
        self.concurrencyLimit = max(0, concurrencyLimit)
    }

    public var running: [UUID] { entries.filter { $0.state == .running }.map(\.id) }
    /// Waiting jobs in the order they will be considered (deferred ones last).
    public var waiting: [UUID] { orderedWaiting.map(\.id) }

    public func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    public func isWaiting(_ id: UUID) -> Bool { entry(id)?.state == .waiting }

    /// 1-based place among waiting jobs, nil when running or unknown.
    public func position(of id: UUID) -> Int? {
        waiting.firstIndex(of: id).map { $0 + 1 }
    }

    /// Why a waiting job hasn't started, in plain words.
    public func reason(for id: UUID) -> String? {
        guard let e = entry(id), e.state == .waiting else { return nil }
        if e.deferred { return "Deferred until other operations finish" }
        if queueSameDrive, entries.contains(where: { $0.state == .running && !$0.drives.isDisjoint(with: e.drives) }) {
            return "Waiting for another operation on the same drive"
        }
        if concurrencyLimit > 0, running.count >= concurrencyLimit {
            return concurrencyLimit == 1 ? "Waiting: one operation at a time" : "Waiting: \(concurrencyLimit) operations at a time"
        }
        return "Waiting to start"
    }

    /// Adds a job; returns the jobs that may start now (possibly including it).
    public mutating func add(_ id: UUID, drives: Set<String>) -> [UUID] {
        entries.append(Entry(id: id, drives: drives, state: .waiting, deferred: false))
        return startable()
    }

    /// A job ended (or was cancelled while waiting); returns the jobs that may start now.
    public mutating func remove(_ id: UUID) -> [UUID] {
        entries.removeAll { $0.id == id }
        return startable()
    }

    /// Settings changed; returns the jobs that may start now. Running jobs are never stopped.
    public mutating func reconfigure(queueSameDrive: Bool, concurrencyLimit: Int) -> [UUID] {
        self.queueSameDrive = queueSameDrive
        self.concurrencyLimit = max(0, concurrencyLimit)
        return startable()
    }

    /// Starts a waiting job regardless of the rules.
    public mutating func startNow(_ id: UUID) -> [UUID] {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].state == .waiting else { return [] }
        entries[i].state = .running
        entries[i].deferred = false
        return [id]
    }

    public mutating func setDeferred(_ id: UUID, _ deferred: Bool) -> [UUID] {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].state == .waiting else { return [] }
        entries[i].deferred = deferred
        if deferred {
            // Deferring moves it behind everything else that waits.
            let e = entries.remove(at: i)
            entries.append(e)
        }
        return startable()
    }

    /// Moves a waiting job one place earlier (-1) or later (+1) among waiting jobs.
    public mutating func move(_ id: UUID, by offset: Int) -> [UUID] {
        let order = orderedWaiting
        guard let from = order.firstIndex(where: { $0.id == id }) else { return [] }
        let to = from + offset
        guard order.indices.contains(to), order[to].deferred == order[from].deferred else { return [] }
        guard let a = entries.firstIndex(where: { $0.id == id }),
              let b = entries.firstIndex(where: { $0.id == order[to].id }) else { return [] }
        entries.swapAt(a, b)
        return startable()
    }

    public func canMove(_ id: UUID, by offset: Int) -> Bool {
        let order = orderedWaiting
        guard let from = order.firstIndex(where: { $0.id == id }) else { return false }
        let to = from + offset
        return order.indices.contains(to) && order[to].deferred == order[from].deferred
    }

    private var orderedWaiting: [Entry] {
        let w = entries.filter { $0.state == .waiting }
        return w.filter { !$0.deferred } + w.filter(\.deferred)
    }

    /// Marks and returns the waiting jobs the rules allow to start, in queue order.
    private mutating func startable() -> [UUID] {
        var started: [UUID] = []
        var busy = Set(entries.filter { $0.state == .running }.flatMap(\.drives))
        var runningCount = entries.filter { $0.state == .running }.count
        for candidate in orderedWaiting {
            if concurrencyLimit > 0, runningCount >= concurrencyLimit { break }
            if candidate.deferred {
                // Only once nothing else is running or waiting.
                let others = entries.contains { $0.id != candidate.id && ($0.state == .running || !$0.deferred) }
                if others { continue }
            }
            if queueSameDrive, !busy.isDisjoint(with: candidate.drives) { continue }
            guard let i = entries.firstIndex(where: { $0.id == candidate.id }) else { continue }
            entries[i].state = .running
            busy.formUnion(candidate.drives)
            runningCount += 1
            started.append(candidate.id)
        }
        return started
    }
}

public extension FileOps {
    /// Volume identity (file system ID) of `url`'s nearest existing ancestor, so a missing destination resolves.
    static func driveIdentity(_ url: URL) -> String? {
        var current = url.standardizedFileURL
        for _ in 0..<64 {
            var info = statfs()
            if statfs(current.path, &info) == 0 {
                return "\(info.f_fsid.val.0):\(info.f_fsid.val.1)"
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}
