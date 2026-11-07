import Foundation
import CoreServices
import ArborCore

/// Spotlight index query scoped to one folder (or the whole Mac) (FE-143). Streams matching paths in
/// batches, stops once the initial gathering is done (freshness comes from `FileEventWatcher`), and
/// gives up after a timeout so an unresponsive index can't leave a search "running" forever.
final class SpotlightSearch: NSObject {
    struct Hit {
        let path: String
        let authors: [String]?
    }

    private let query = NSMetadataQuery()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "Arbor Spotlight"
        return q
    }()
    private var processed = 0
    private var finished = false
    private var tokens: [NSObjectProtocol] = []
    private let onHits: ([Hit]) -> Void
    private let onFinish: (_ timedOut: Bool) -> Void
    private let limit: Int
    private let timeout: TimeInterval

    /// `onHits` and `onFinish` are called on a background queue.
    init?(predicate: String, scope: URL?, limit: Int = 20_000, timeout: TimeInterval = 20,
          onHits: @escaping ([Hit]) -> Void, onFinish: @escaping (Bool) -> Void) {
        guard let p = NSPredicate(fromMetadataQueryString: predicate) else { return nil }
        self.onHits = onHits
        self.onFinish = onFinish
        self.limit = limit
        self.timeout = timeout
        super.init()
        query.predicate = p
        query.searchScopes = [scope.map { $0 as Any } ?? NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.25
        query.operationQueue = queue
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: queue) { [weak self] _ in
            self?.collect()
        })
        tokens.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue) { [weak self] _ in
            self?.collect()
            self?.finish(timedOut: false)
        })
    }

    func start() {
        queue.addOperation { [self] in
            guard !finished else { return }
            if !query.start() { finish(timedOut: false) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.queue.addOperation { self?.finish(timedOut: true) }
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            guard !finished else { return }
            finished = true
            query.stop()
            removeObservers()
        }
    }

    private func collect() {
        guard !finished else { return }
        query.disableUpdates()
        let count = min(query.resultCount, limit)
        var hits: [Hit] = []
        if count > processed {
            hits.reserveCapacity(count - processed)
            for i in processed..<count {
                guard let item = query.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                hits.append(Hit(path: path, authors: item.value(forAttribute: kMDItemAuthors as String) as? [String]))
            }
            processed = count
        }
        query.enableUpdates()
        if !hits.isEmpty { onHits(hits) }
        if query.resultCount >= limit { finish(timedOut: false) }
    }

    private func finish(timedOut: Bool) {
        guard !finished else { return }
        finished = true
        query.stop()
        removeObservers()
        onFinish(timedOut)
    }

    private func removeObservers() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
    }

    // MARK: Index state

    private static var stateCache: [String: SpotlightIndexState] = [:]
    private static let stateLock = NSLock()

    /// Whether Spotlight indexes the volume holding `url` (`mdutil -s`), cached per volume. Blocking: call off the main thread.
    static func indexState(for url: URL?) -> SpotlightIndexState {
        let volume = (try? (url ?? URL(fileURLWithPath: "/")).resourceValues(forKeys: [.volumeURLKey]).volume)?.path ?? "/"
        stateLock.lock()
        if let cached = stateCache[volume] { stateLock.unlock(); return cached }
        stateLock.unlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var state = SpotlightIndexState.unknown
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            state = SpotlightIndexState.parse(mdutilOutput: String(decoding: data, as: UTF8.self))
        }
        stateLock.lock()
        stateCache[volume] = state
        stateLock.unlock()
        return state
    }
}

/// File-system change notifications for a folder tree (FSEvents), used to keep search results fresh
/// after the initial search (FE-146). Delivers changed paths in batches on a background queue.
final class FileEventWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Arbor search events", qos: .utility)
    private let handler: (_ paths: [String], _ mustRescan: Bool) -> Void

    init?(root: URL, handler: @escaping ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var rescan = false
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || f & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                    || f & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 { rescan = true }
            }
            watcher.handler(list, rescan)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
