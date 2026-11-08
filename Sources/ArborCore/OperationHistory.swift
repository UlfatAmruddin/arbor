import Foundation

/// One finished copy/move job in Operation history (FE-126). Built from the same per-item results as
/// the job journal, so history and crash review agree. Keeps at most `itemLimit` items; the rest are counted.
public struct OperationRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded, merged, skipped, failed
        /// Cross-volume move: copied, but the original couldn't be removed.
        case sourceRemains
        /// A folder that arrived incomplete.
        case partial
        case cancelled
        /// Crash journal: never started or stopped before writing.
        case notDone
        /// Crash journal: being written when the app stopped.
        case uncertain

        /// Offered by "Retry failed items".
        public var isRetryable: Bool {
            switch self {
            case .failed, .partial, .cancelled, .notDone, .uncertain: return true
            case .succeeded, .merged, .skipped, .sourceRemains: return false
            }
        }

        public var label: String {
            switch self {
            case .succeeded: return L10n.tr("Done")
            case .merged: return L10n.tr("Merged")
            case .skipped: return L10n.tr("Skipped")
            case .failed: return L10n.tr("Failed")
            case .sourceRemains: return L10n.tr("Copied; original kept")
            case .partial: return L10n.tr("Partly done")
            case .cancelled: return L10n.tr("Cancelled")
            case .notDone: return L10n.tr("Not done")
            case .uncertain: return L10n.tr("Uncertain")
            }
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var source: String
        public var outcome: Outcome
        /// The committed name can differ (Keep Both).
        public var destination: String?
        /// Reason for failures and skips.
        public var message: String?
        /// For a nested item, the matching folder at the destination, not the job's destination.
        public var retryFolder: String
        /// Inside a top-level folder, not requested directly.
        public var nested: Bool

        public init(source: String, outcome: Outcome, destination: String? = nil, message: String? = nil,
                    retryFolder: String, nested: Bool = false) {
            self.source = source
            self.outcome = outcome
            self.destination = destination
            self.message = message
            self.retryFolder = retryFolder
            self.nested = nested
        }
    }

    /// FE-130: never implied by a completed copy.
    public struct Verification: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable { case verified, failed, cancelled }
        public var state: State
        public var filesChecked: Int
        public var bytesChecked: Int64
        public var failures: [VerificationResult.Failure]

        public init(_ result: VerificationResult) {
            state = result.cancelled ? .cancelled : (result.failures.isEmpty ? .verified : .failed)
            filesChecked = result.filesChecked
            bytesChecked = result.bytesChecked
            failures = Array(result.failures.prefix(OperationHistoryStore.itemLimit))
        }
    }

    public var id: UUID
    public var kind: TransferKind
    public var sources: [String]
    public var destination: String
    public var started: Date
    public var finished: Date
    public var wasCancelled: Bool
    /// Recovered from a crash journal.
    public var wasInterrupted: Bool
    public var items: [Item]
    /// Items beyond the per-job limit.
    public var omittedItems: Int
    public var verification: Verification?

    public init(id: UUID = UUID(), kind: TransferKind, sources: [String], destination: String, started: Date, finished: Date,
                wasCancelled: Bool = false, wasInterrupted: Bool = false, items: [Item], omittedItems: Int = 0,
                verification: Verification? = nil) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.started = started
        self.finished = finished
        self.wasCancelled = wasCancelled
        self.wasInterrupted = wasInterrupted
        self.items = items
        self.omittedItems = omittedItems
        self.verification = verification
    }

    // MARK: Counts

    public struct Counts: Equatable, Sendable {
        public var done = 0, skipped = 0, failed = 0, cancelled = 0
    }

    /// Top-level outcomes, plus nested skips (a merged folder would hide them; other nested problems already mark it partial).
    public var counts: Counts {
        var c = Counts()
        for item in items {
            if item.nested {
                if item.outcome == .skipped { c.skipped += 1 }
                continue
            }
            switch item.outcome {
            case .succeeded, .merged, .sourceRemains: c.done += 1
            case .skipped: c.skipped += 1
            case .failed, .partial, .uncertain: c.failed += 1
            case .cancelled, .notDone: c.cancelled += 1
            }
        }
        return c
    }

    /// "2 done · 1 skipped · 1 failed".
    public var countsText: String {
        let c = counts
        var parts = [L10n.format("%@ done", "\(c.done)")]
        if c.skipped > 0 { parts.append(L10n.format("%@ skipped", "\(c.skipped)")) }
        if c.failed > 0 { parts.append(L10n.format("%@ failed", "\(c.failed)")) }
        if c.cancelled > 0 { parts.append(L10n.format("%@ not done", "\(c.cancelled)")) }
        if omittedItems > 0 { parts.append(L10n.format("%@ more not listed", "\(omittedItems)")) }
        return parts.joined(separator: " · ")
    }

    public var hasProblems: Bool { counts.failed > 0 || verification?.state == .failed }

    /// Existing retryable sources grouped by target folder; retry is a normal job, so conflicts are asked (FE-128).
    /// A partial folder with known failures retries just those; a missing folder is retried whole.
    public func retryPlan(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [(folder: String, sources: [String])] {
        let candidates = items.filter { $0.outcome.isRetryable && exists($0.source) }
        let nested = candidates.filter(\.nested)
        func inside(_ child: Item, _ parent: Item) -> Bool { child.source.hasPrefix(parent.source + "/") }
        let wholeItems = candidates.filter { item in
            !item.nested && !(item.outcome == .partial && nested.contains { inside($0, item) })
        }
        var groups: [(folder: String, sources: [String])] = []
        for item in candidates {
            if !item.nested, !wholeItems.contains(item) { continue }
            if item.nested, wholeItems.contains(where: { inside(item, $0) }) { continue }
            if let i = groups.firstIndex(where: { $0.folder == item.retryFolder }) {
                if !groups[i].sources.contains(item.source) { groups[i].sources.append(item.source) }
            } else {
                groups.append((item.retryFolder, [item.source]))
            }
        }
        return groups
    }

    // MARK: Building

    public init(report: TransferReport, id: UUID = UUID(), started: Date, finished: Date = Date(),
                itemLimit: Int = OperationHistoryStore.itemLimit) {
        let destination = report.destination.path
        var items: [Item] = []
        var tops: [(source: String, destination: String)] = []
        for result in report.results {
            let item = Self.item(result, retryFolder: destination, nested: false)
            items.append(item)
            tops.append((result.source.path, item.destination ?? (destination as NSString).appendingPathComponent(result.source.lastPathComponent)))
        }
        for detail in report.details {
            // Top-level item's committed location plus the path inside it.
            let parent = detail.source.deletingLastPathComponent().path
            var folder = destination
            if let top = tops.first(where: { parent == $0.source || parent.hasPrefix($0.source + "/") }) {
                folder = top.destination + String(parent.dropFirst(top.source.count))
            }
            items.append(Self.item(detail, retryFolder: folder, nested: true))
        }
        let omitted = max(0, items.count - itemLimit)
        self.init(id: id, kind: report.kind, sources: report.results.map(\.source.path), destination: destination,
                  started: started, finished: finished, wasCancelled: report.wasCancelled,
                  items: Array(items.prefix(itemLimit)), omittedItems: omitted)
    }

    private static func item(_ result: ItemResult, retryFolder: String, nested: Bool) -> Item {
        let source = result.source.path
        switch result.outcome {
        case .succeeded(let url): return Item(source: source, outcome: .succeeded, destination: url.path, retryFolder: retryFolder, nested: nested)
        case .merged(let url): return Item(source: source, outcome: .merged, destination: url.path, retryFolder: retryFolder, nested: nested)
        case .skipped(let why): return Item(source: source, outcome: .skipped, message: why, retryFolder: retryFolder, nested: nested)
        case .failed(let why): return Item(source: source, outcome: .failed, message: why, retryFolder: retryFolder, nested: nested)
        case .copiedButSourceRemains(let url, let why):
            return Item(source: source, outcome: .sourceRemains, destination: url.path, message: why, retryFolder: retryFolder, nested: nested)
        case .partial(let url, let why):
            return Item(source: source, outcome: .partial, destination: url.path, message: why, retryFolder: retryFolder, nested: nested)
        case .cancelled: return Item(source: source, outcome: .cancelled, message: L10n.tr("The job was cancelled before this item."), retryFolder: retryFolder, nested: nested)
        }
    }

    public init(interrupted job: InterruptedJob, finished: Date = Date()) {
        let destination = job.header.destination
        let items = job.items.map { item -> Item in
            let outcome: Outcome
            switch item.state {
            case .committed?: outcome = .succeeded
            case .sourceRemains?: outcome = .sourceRemains
            case .skipped?: outcome = .skipped
            case .failed?: outcome = .failed
            case .started?: outcome = .uncertain
            case .partial?: outcome = .partial
            case .cancelled?, nil: outcome = .notDone
            }
            let message = item.note ?? (outcome == .uncertain ? "Arbor stopped while this item was being written; the destination may hold a partial copy." : nil)
            return Item(source: item.source.path, outcome: outcome, destination: item.destination?.path, message: message,
                        retryFolder: destination)
        }
        self.init(id: job.header.id, kind: job.kind, sources: job.header.sources, destination: destination,
                  started: job.header.started, finished: finished, wasCancelled: true, wasInterrupted: true,
                  items: Array(items.prefix(OperationHistoryStore.itemLimit)),
                  omittedItems: max(0, items.count - OperationHistoryStore.itemLimit))
    }
}

/// Persistent Operation history, newest first, bounded by `limit` and `itemLimit`; one JSON file written atomically.
/// Not thread-safe: use from one serial queue.
public final class OperationHistoryStore {
    public static let defaultLimit = 50
    public static let itemLimit = 200

    public let fileURL: URL
    public let limit: Int
    public private(set) var records: [OperationRecord]

    public init(fileURL: URL, limit: Int = OperationHistoryStore.defaultLimit) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        records = Self.read(fileURL)
        if records.count > self.limit { records = Array(records.prefix(self.limit)) }
    }

    /// Replaces a record with the same id (e.g. after verification).
    public func add(_ record: OperationRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records.sort { $0.finished > $1.finished }
        if records.count > limit { records.removeLast(records.count - limit) }
        save()
    }

    public func update(_ id: UUID, _ change: (inout OperationRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    public func clear() {
        records = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(File(records: records)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
        chmod(fileURL.path, 0o600)
    }

    private struct File: Codable {
        var version = 1
        var records: [OperationRecord]
    }

    private static func read(_ url: URL) -> [OperationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode(File.self, from: data))?.records ?? []
    }
}

extension TransferKind: Codable {}
