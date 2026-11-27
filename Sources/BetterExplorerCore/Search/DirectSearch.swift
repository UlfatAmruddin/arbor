import Foundation

public struct SearchHit: Sendable {
    public let item: FileItem
    public let identity: FileIdentity
    public let reasons: Set<SearchReason>

    public init(item: FileItem, identity: FileIdentity, reasons: Set<SearchReason>) {
        self.item = item
        self.identity = identity
        self.reasons = reasons
    }
}

/// Folded into `SearchCoverage`.
public struct DirectSearchReport: Sendable {
    public var cancelled = false
    public var limitReached = false
    public var rootError: ListingError?
    public var deniedFolders: [String] = []
    public var deniedCount = 0
    public var unreadableCount = 0
    public var skippedVolumes: [String] = []
    public var contentUnchecked = 0
    public var archivesUnreadable = 0
    public var directories = 0
    public var entries = 0
    public var hits = 0

    public func apply(to coverage: inout SearchCoverage) {
        for path in deniedFolders { coverage.addDenied(path) }
        coverage.deniedCount += max(0, deniedCount - deniedFolders.count)
        coverage.unreadableCount += unreadableCount
        coverage.skippedVolumes += skippedVolumes.prefix(5)
        coverage.contentUnchecked += contentUnchecked
        coverage.archivesUnreadable += archivesUnreadable
    }
}

/// Index-free search (FE-141). Never follows links and enters each directory once (device+inode), so
/// loops and firmlinks can't hang; skips packages and other volumes unless asked.
public final class DirectSearch: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var root: URL
        public var recursive = true
        public var includeHidden = false
        /// Packages themselves are always candidates.
        public var enterPackages = false
        public var searchArchives = false
        public var concurrency = 4
        public var maxContentBytes = TextContent.defaultMaxBytes
        public var resultLimit = 10_000
        /// Deliver after this many hits or seconds, whichever comes first.
        public var batchSize = 64
        public var batchInterval: TimeInterval = 0.15

        public init(root: URL) { self.root = root }
    }

    public let evaluator: SearchEvaluator
    public let configuration: Configuration

    private let lock = NSCondition()
    private var queue: [URL] = []
    private var head = 0
    private var active = 0
    private var visited = Set<FileIdentity>()
    private var cancelled = false
    private var started = false
    private var report = DirectSearchReport()
    private var buffer: [SearchHit] = []
    private var lastFlush = Date()
    private var onHits: (([SearchHit]) -> Void)?
    private let keys: [URLResourceKey]
    private let keySet: Set<URLResourceKey>

    public init(evaluator: SearchEvaluator, configuration: Configuration) {
        self.evaluator = evaluator
        self.configuration = configuration
        var keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .isVolumeKey,
                                      .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let props = evaluator.expression.properties
        if !props.isDisjoint(with: [.kind, .type, .contents]) || evaluator.matchContents { keys.append(.typeIdentifierKey) }
        if props.contains(.type) { keys.append(.localizedTypeDescriptionKey) }
        if props.contains(.tags) { keys.append(.tagNamesKey) }
        self.keys = keys
        keySet = Set(keys)
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        report.cancelled = true
        lock.broadcast()
        lock.unlock()
    }

    /// `onHits` and `completion` run on background threads.
    public func start(onHits: @escaping ([SearchHit]) -> Void, completion: @escaping (DirectSearchReport) -> Void) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        self.onHits = onHits
        lock.unlock()

        let root = configuration.root
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            DispatchQueue.global(qos: .userInitiated).async {
                var r = DirectSearchReport()
                r.rootError = .notFound(path: root.path)
                completion(r)
            }
            return
        }
        queue = [root]
        let group = DispatchGroup()
        for _ in 0..<max(1, configuration.concurrency) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                worker()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            flush(force: true)
            lock.lock()
            let final = report
            self.onHits = nil
            lock.unlock()
            completion(final)
        }
    }

    // MARK: Workers

    private func worker() {
        let fm = FileManager()
        while true {
            lock.lock()
            while head >= queue.count, active > 0, !cancelled { lock.wait() }
            if cancelled || head >= queue.count {
                lock.broadcast()
                lock.unlock()
                return
            }
            let dir = queue[head]
            head += 1
            if head > 1024, head * 2 > queue.count {
                queue.removeFirst(head)
                head = 0
            }
            active += 1
            lock.unlock()

            let children = process(dir, fm: fm)

            lock.lock()
            queue.append(contentsOf: children)
            active -= 1
            lock.broadcast()
            lock.unlock()
        }
    }

    /// Returns subdirectories to enter.
    private func process(_ dir: URL, fm: FileManager) -> [URL] {
        guard let id = FileIdentity.of(path: dir.path) else { return [] }
        lock.lock()
        let firstVisit = visited.insert(id).inserted
        if firstVisit { report.directories += 1 }
        lock.unlock()
        guard firstVisit else { return [] }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                              options: configuration.includeHidden ? [] : [.skipsHiddenFiles])
        } catch let error as NSError {
            let mapped = DirectoryLister.map(error, path: dir.path)
            lock.lock()
            switch mapped {
            case .permissionDenied:
                report.deniedCount += 1
                if report.deniedFolders.count < 20 { report.deniedFolders.append(dir.path) }
            case .notFound: break   // removed while searching
            default: report.unreadableCount += 1
            }
            lock.unlock()
            return []
        }

        var subdirectories: [URL] = []
        var localHits: [SearchHit] = []
        var unchecked = 0
        var badArchives = 0
        let folderPath = dir.path
        for url in urls {
            if isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            let isDirectory = values.isDirectory ?? false
            let isPackage = values.isPackage ?? false
            let isSymlink = values.isSymbolicLink ?? false
            let name = values.name ?? url.lastPathComponent
            let isFolder = isDirectory && !isPackage
            let content = (!isDirectory && (evaluator.needsContents))
                ? TextContent(url: url, typeIdentifier: values.typeIdentifier, size: values.fileSize.map(Int64.init),
                              maxBytes: configuration.maxContentBytes) : nil
            let candidate = SearchCandidate(
                name: name, folderPath: folderPath, isFolder: isFolder, isPackage: isPackage, isSymbolicLink: isSymlink,
                size: isFolder ? nil : values.fileSize.map(Int64.init), modified: values.contentModificationDate,
                created: values.creationDate, typeIdentifier: values.typeIdentifier,
                typeDescription: values.localizedTypeDescription ?? (keySet.contains(.localizedTypeDescriptionKey) ? (isFolder ? L10n.tr("Folder") : L10n.tr("Document")) : nil),
                tags: keySet.contains(.tagNamesKey) ? (values.tagNames ?? []) : nil,
                authors: nil,
                contentContains: content.map { c in { c.contains($0) } })
            var match = evaluator.evaluate(candidate)
            if match.truth == .unknown, let content {
                if case .text = content.outcome {} else { unchecked += 1 }
            }
            if configuration.searchArchives, !isDirectory, ZipDirectory.hasZipName(url) {
                switch archiveMatch(url, folderPath: folderPath + "/" + name) {
                case .matched(let entryReasons):
                    if match.truth != .yes { match = .yes(entryReasons) } else { match.reasons.formUnion(entryReasons) }
                case .noMatch: break
                case .unreadable: badArchives += 1
                }
            }
            if match.truth == .yes, let item = FileItem(url: url), let identity = FileIdentity.of(path: url.path) {
                localHits.append(SearchHit(item: item, identity: identity, reasons: match.reasons))
            }
            if configuration.recursive, isDirectory, !isSymlink, !isPackage || configuration.enterPackages {
                if values.isVolume == true {
                    lock.lock()
                    if report.skippedVolumes.count < 20 { report.skippedVolumes.append(name) }
                    lock.unlock()
                } else {
                    subdirectories.append(url)
                }
            }
        }

        lock.lock()
        report.entries += urls.count
        report.contentUnchecked += unchecked
        report.archivesUnreadable += badArchives
        var stop = false
        if !localHits.isEmpty {
            let room = configuration.resultLimit - report.hits
            if localHits.count >= room {
                localHits = Array(localHits.prefix(max(0, room)))
                report.limitReached = true
                stop = true
            }
            report.hits += localHits.count
            buffer += localHits
        }
        lock.unlock()
        if stop { cancelForLimit() }
        flush(force: false)
        return stop ? [] : subdirectories
    }

    private enum ArchiveResult { case matched(Set<SearchReason>), noMatch, unreadable }

    static let archiveEntryLimit = 20_000

    private func archiveMatch(_ url: URL, folderPath: String) -> ArchiveResult {
        guard let handle = FileHandle.openRegularFile(atPath: url.path) else { return .unreadable }
        defer { try? handle.close() }
        guard let entries = try? ZipDirectory.read(handle, limit: Self.archiveEntryLimit) else { return .unreadable }
        var reasons: Set<SearchReason> = []
        for entry in entries {
            // nil for unsafe names (absolute, "..").
            guard let path = entry.path else { continue }
            let isFolder = entry.kind == .directory
            let name = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            let candidate = SearchCandidate(name: name, folderPath: parent.isEmpty ? folderPath : folderPath + "/" + parent,
                                            isFolder: isFolder, size: isFolder ? nil : (entry.size ?? 0),
                                            modified: entry.modified, created: nil, typeIdentifier: nil,
                                            typeDescription: nil, tags: [], authors: nil, contentContains: nil)
            if evaluator.evaluate(candidate).truth == .yes {
                reasons.insert(.archiveEntry(path))
                if reasons.count >= 3 { break }
            }
        }
        return reasons.isEmpty ? .noMatch : .matched(reasons)
    }

    private func cancelForLimit() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }

    private func flush(force: Bool) {
        lock.lock()
        guard !buffer.isEmpty,
              force || buffer.count >= configuration.batchSize || Date().timeIntervalSince(lastFlush) >= configuration.batchInterval else {
            lock.unlock()
            return
        }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        lastFlush = Date()
        let deliver = onHits
        lock.unlock()
        deliver?(batch)
    }
}
