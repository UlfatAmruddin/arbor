import Foundation

/// Timings and caps for listing one kind of volume, together so they can't drift apart.
public struct PathCompletionLane: Equatable, Sendable {
    public let debounce: TimeInterval
    /// Shorter than `queueTimeout`, or a partial result would always arrive late and never be shown.
    public let scanTimeLimit: TimeInterval
    public let queueTimeout: TimeInterval
    public let entryCap: Int
    /// A thread blocked in the kernel can't be interrupted, so hung work is limited by count.
    public let inFlightCap: Int

    public static let local = PathCompletionLane(debounce: 0.12, scanTimeLimit: 1.2, queueTimeout: 1.5, entryCap: 20_000, inFlightCap: 3)
    public static let network = PathCompletionLane(debounce: 0.35, scanTimeLimit: 3, queueTimeout: 4, entryCap: 5_000, inFlightCap: 2)
}

/// One lane's folder listings, off the main thread, joined per key and capped; call `start` and `cancel` on `callbackQueue` only.
public final class PathListingQueue: @unchecked Sendable {
    public typealias Lister = @Sendable (URL, PathCompletionLane, ScanCancellation) -> BoundedListing

    public struct Job: Sendable {
        fileprivate let token: UUID
        fileprivate let scan: ScanCancellation
    }

    public let lane: PathCompletionLane
    private let queue: SlowWorkQueue<BoundedListing>
    private let lister: Lister
    /// The token each running scan observes: a request that joins it must cancel that one, not a new one.
    private var scans: [String: ScanCancellation] = [:]

    public init(lane: PathCompletionLane, label: String, callbackQueue: DispatchQueue = .main,
                lister: @escaping Lister = PathListingQueue.liveLister) {
        self.lane = lane
        self.lister = lister
        queue = SlowWorkQueue(label: label, callbackQueue: callbackQueue)
    }

    public static let liveLister: Lister = { folder, lane, cancellation in
        DirectoryLister.boundedEntries(of: folder, limit: lane.entryCap, timeLimit: lane.scanTimeLimit, cancellation: cancellation)
    }

    /// nil when the lane is full; after a timeout `late` gets the result instead of `finished`.
    public func start(key: String, folder: URL, finished: @escaping (BoundedListing) -> Void,
                      late: @escaping (BoundedListing) -> Void) -> Job? {
        let joining = queue.isRunning(key: key)
        guard joining || queue.inFlightCount < lane.inFlightCap else { return nil }
        let scan = (joining ? scans[key] : nil) ?? ScanCancellation()
        scans = scans.filter { queue.isRunning(key: $0.key) }
        scans[key] = scan
        let token = queue.run(key: key, timeout: lane.queueTimeout, work: { [lister, lane] in lister(folder, lane, scan) }, late: late) { outcome in
            if case .finished(let listing) = outcome { finished(listing) }
        }
        return Job(token: token, scan: scan)
    }

    public func cancel(_ job: Job) {
        queue.cancel(job.token)
        job.scan.cancel()
    }

    func isRunning(key: String) -> Bool { queue.isRunning(key: key) }
}
