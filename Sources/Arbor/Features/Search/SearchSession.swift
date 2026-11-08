import AppKit
import ArborCore

/// One search (spec §10.3): Spotlight query and direct scan side by side, merged by file identity,
/// kept fresh by file events. Main-thread confined; engines call back on background queues.
final class SearchSession {
    static let resultLimit = 10_000

    let request: SearchRequest
    let key: String
    let showHidden: Bool
    private(set) var coverage = SearchCoverage()
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    /// Set when a change notification asked for a reload; the next load returns the snapshot as is.
    var snapshotRequested = false

    private struct Entry {
        var item: FileItem
        var reasons: Set<SearchReason>
    }

    private var results: [FileIdentity: Entry] = [:]
    private var identityByPath: [String: FileIdentity] = [:]
    private var cachedItems: [FileItem]?
    private var evaluator: SearchEvaluator?
    private var direct: DirectSearch?
    private var spotlight: SpotlightSearch?
    private var spotlightExact = false
    private var watcher: FileEventWatcher?
    private var directDone = true
    private var spotlightDone = true
    private var spotlightTimedOut = false
    private var spotlightRan = false
    private var indexState: SpotlightIndexState?
    private var directReport: DirectSearchReport?
    private var notifyScheduled = false
    private var lastNotify = Date.distantPast
    private let filter: ScopeFilter?
    /// Direct scans of `request.extraScopes` (library folders, pinned folders, other drives).
    private var extraSearches: [DirectSearch] = []
    private var extraPending = 0
    private var extraReports: [DirectSearchReport] = []

    init(request: SearchRequest, showHidden: Bool) {
        self.request = request
        self.showHidden = showHidden
        key = SearchSession.key(request, showHidden: showHidden)
        filter = request.scope.map {
            ScopeFilter(scope: $0, recursive: request.recursive,
                        includeHidden: showHidden || request.options.contains(.systemFiles),
                        enterPackages: request.options.contains(.systemFiles))
        }
    }

    static func key(_ request: SearchRequest, showHidden: Bool) -> String {
        Location.search(request).key + (showHidden ? "&hidden=1" : "")
    }

    var isRunning: Bool { coverage.phase == .searching }
    var parseError: String? { if case .failed(let m) = coverage.phase { return m }; return nil }

    /// Current results (unsorted; the window sorts).
    var items: [FileItem] {
        if let cachedItems { return cachedItems }
        let list = results.values.map(\.item)
        cachedItems = list
        return list
    }

    var count: Int { results.count }

    func reasons(forPath path: String) -> Set<SearchReason>? {
        identityByPath[path].flatMap { results[$0]?.reasons }
    }

    // MARK: Observing

    final class Token {
        let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    /// Calls `onChange` (throttled) on result or coverage changes. Release the token to stop.
    func observe(_ onChange: @escaping () -> Void) -> Token {
        let id = UUID()
        let box = observerBox
        box.observers[id] = onChange
        return Token { [weak box] in box?.observers[id] = nil }
    }

    /// Takes over another session's observers (Refresh replaces sessions).
    /// The box is shared, so the old session's tokens still remove their entries.
    func adoptObservers(from other: SearchSession) {
        observerBox = other.observerBox
        other.observerBox = ObserverBox()
    }

    private final class ObserverBox { var observers: [UUID: () -> Void] = [:] }
    private var observerBox = ObserverBox()

    private func changed(immediate: Bool = false) {
        cachedItems = nil
        guard !notifyScheduled else { return }
        notifyScheduled = true
        let interval: TimeInterval = results.count > 2000 ? 0.8 : 0.3
        let delay = immediate ? 0.02 : max(0.02, interval - Date().timeIntervalSince(lastNotify))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.lastNotify = Date()
            self.observerBox.observers.values.forEach { $0() }
        }
    }

    // MARK: Running

    func start() {
        startedAt = Date()
        coverage = SearchCoverage()
        let parsed = AQSParser.parse(request.query)
        guard case .success(let expression) = parsed else {
            if case .failure(let error) = parsed { coverage.phase = .failed(error.message) }
            finishedAt = Date()
            changed(immediate: true)
            return
        }
        let evaluator = SearchEvaluator(expression, matchContents: request.options.contains(.contents))
        self.evaluator = evaluator

        if let scope = request.scope {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: scope.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                coverage.scopeUnavailable = Location.folder(scope).displayName
                coverage.phase = .finished
                finishedAt = Date()
                changed(immediate: true)
                return
            }
            startDirect(scope: scope, evaluator: evaluator)
            watcher = FileEventWatcher(root: scope) { [weak self] paths, rescan in self?.filesChanged(paths, mustRescan: rescan) }
        } else {
            coverage.indexOnly = true
        }
        startExtras(evaluator: evaluator)
        startSpotlight(expression: expression, evaluator: evaluator)
        let needsIndex = request.scope == nil || evaluator.needsContents || evaluator.needsIndexOnlyMetadata
        if needsIndex {
            let scope = request.scope
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let state = SpotlightSearch.indexState(for: scope)
                DispatchQueue.main.async { self?.indexState = state; self?.finishIfDone() }
            }
        } else {
            indexState = .unknown
        }
        changed(immediate: true)
    }

    private func startDirect(scope: URL, evaluator: SearchEvaluator) {
        var config = DirectSearch.Configuration(root: scope)
        config.recursive = request.recursive
        config.includeHidden = showHidden || request.options.contains(.systemFiles)
        config.enterPackages = request.options.contains(.systemFiles)
        config.searchArchives = request.options.contains(.zipped)
        config.resultLimit = Self.resultLimit
        let search = DirectSearch(evaluator: evaluator, configuration: config)
        direct = search
        directDone = false
        search.start(onHits: { [weak self] hits in
            DispatchQueue.main.async { self?.merge(hits) }
        }, completion: { [weak self] report in
            DispatchQueue.main.async {
                guard let self, self.direct === search else { return }
                self.directReport = report
                self.directDone = true
                self.finishIfDone()
            }
        })
    }

    /// Extra folders are scanned like the scope; extra files are matched by themselves.
    private func startExtras(evaluator: SearchEvaluator) {
        let primary = request.scope?.path
        let extras = request.extraScopes.filter { url in
            guard let primary else { return true }
            return url.path != primary && !url.path.hasPrefix(primary == "/" ? "/" : primary + "/")
        }
        guard !extras.isEmpty else { return }
        extraPending = extras.count
        for root in extras {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { extraFinished(nil); continue }
            if !isDirectory.boolValue || (FileItem(url: root)?.isPackage ?? false) {
                let readContents = evaluator.needsContents
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let hit = SearchCandidates.hit(path: root.path, evaluator: evaluator, authors: nil, acceptUnknown: false,
                                                   readContents: readContents)
                    DispatchQueue.main.async {
                        if let hit { self?.merge([hit]) }
                        self?.extraFinished(nil)
                    }
                }
                continue
            }
            var config = DirectSearch.Configuration(root: root)
            config.recursive = request.recursive
            config.includeHidden = showHidden || request.options.contains(.systemFiles)
            config.enterPackages = request.options.contains(.systemFiles)
            config.searchArchives = request.options.contains(.zipped)
            config.resultLimit = Self.resultLimit
            let search = DirectSearch(evaluator: evaluator, configuration: config)
            extraSearches.append(search)
            search.start(onHits: { [weak self] hits in
                DispatchQueue.main.async { self?.merge(hits) }
            }, completion: { [weak self] report in
                DispatchQueue.main.async {
                    guard let self, self.extraSearches.contains(where: { $0 === search }) else { return }
                    self.extraFinished(report)
                }
            })
        }
    }

    private func extraFinished(_ report: DirectSearchReport?) {
        if let report { extraReports.append(report) }
        extraPending = max(0, extraPending - 1)
        finishIfDone()
    }

    private func startSpotlight(expression: SearchExpression, evaluator: SearchEvaluator) {
        guard let predicate = SpotlightPredicate.make(expression, matchContents: evaluator.matchContents) else {
            if request.scope == nil { coverage.phase = .failed("this search can't be answered from the Spotlight index. Search a folder instead.") }
            return
        }
        spotlightExact = predicate.isExact
        let filter = self.filter
        let exact = predicate.isExact
        let verifyQueue = DispatchQueue(label: "Arbor search verify", qos: .userInitiated)
        let search = SpotlightSearch(predicate: predicate.query, scope: request.scope, onHits: { [weak self] hits in
            verifyQueue.async {
                let verified = hits.compactMap { hit -> SearchHit? in
                    if let filter, !filter.accepts(hit.path) { return nil }
                    return SearchCandidates.hit(path: hit.path, evaluator: evaluator, authors: hit.authors ?? [],
                                                acceptUnknown: exact, readContents: false)
                }
                guard !verified.isEmpty else { return }
                DispatchQueue.main.async { self?.merge(verified) }
            }
        }, onFinish: { [weak self] timedOut in
            verifyQueue.async {   // after the last verification batch
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spotlightTimedOut = timedOut
                    self.spotlightDone = true
                    self.finishIfDone()
                }
            }
        })
        guard let search else { return }
        spotlight = search
        spotlightDone = false
        spotlightRan = true
        search.start()
    }

    private func merge(_ hits: [SearchHit]) {
        guard coverage.phase == .searching || coverage.phase == .finished else { return }
        var added = false
        for hit in hits {
            if var existing = results[hit.identity] {
                existing.reasons.formUnion(hit.reasons)
                results[hit.identity] = existing
                continue
            }
            guard results.count < Self.resultLimit else {
                coverage.resultLimit = Self.resultLimit
                stopEngines()
                break
            }
            results[hit.identity] = Entry(item: hit.item, reasons: hit.reasons)
            identityByPath[hit.item.url.path] = hit.identity
            added = true
        }
        if added { changed() }
    }

    private func finishIfDone() {
        guard coverage.phase == .searching, directDone, spotlightDone, extraPending == 0,
              indexState != nil || !needsIndexState else { return }
        coverage.phase = .finished
        finishedAt = Date()
        if let report = directReport {
            report.apply(to: &coverage)
            if report.limitReached { coverage.resultLimit = Self.resultLimit }
        }
        for report in extraReports {
            report.apply(to: &coverage)
            if report.limitReached { coverage.resultLimit = Self.resultLimit }
        }
        if let evaluator {
            let indexed = indexState == .enabled
            if evaluator.needsContents {
                coverage.contentFromIndex = spotlightRan && spotlightExact && !spotlightTimedOut && indexed
                if (coverage.contentUnchecked > 0 || request.scope == nil) && !indexed { coverage.indexUnavailable = true }
            }
            if evaluator.needsIndexOnlyMetadata, !(spotlightRan && indexed) { coverage.indexUnavailable = true }
            if request.scope == nil, !indexed { coverage.indexUnavailable = true }
            let indexNeeded = evaluator.needsContents || evaluator.needsIndexOnlyMetadata || request.scope == nil
            if spotlightTimedOut, indexNeeded { coverage.indexTimedOut = true }
        }
        changed(immediate: true)
    }

    private var needsIndexState: Bool {
        guard let evaluator else { return false }
        return request.scope == nil || evaluator.needsContents || evaluator.needsIndexOnlyMetadata
    }

    private func stopEngines() {
        direct?.cancel()
        spotlight?.cancel()
        extraSearches.forEach { $0.cancel() }
    }

    /// Stopped because a newer query replaces it (status keeps saying "Searching…").
    private(set) var superseded = false

    /// Stops a running search, keeping results so far; coverage says "stopped" and loading reruns it.
    func cancel(superseded: Bool = false) {
        stopEngines()
        watcher?.stop()
        watcher = nil
        guard coverage.phase == .searching else { return }
        self.superseded = superseded
        coverage.phase = .stopped
        directDone = true
        spotlightDone = true
        extraPending = 0
        extraSearches = []
        if let report = directReport { report.apply(to: &coverage) }
        finishedAt = Date()
        changed(immediate: true)
    }

    var wasStopped: Bool { coverage.phase == .stopped }

    // MARK: Freshness (FE-146)

    /// Drops results whose files are gone (before showing a cached search again).
    func revalidate(completion: @escaping () -> Void) {
        let paths = Array(identityByPath.keys)
        guard !paths.isEmpty else { completion(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let gone = paths.filter { FileIdentity.of(path: $0) == nil }
            DispatchQueue.main.async {
                self?.remove(paths: gone)
                completion()
            }
        }
    }

    private func remove(paths: [String]) {
        var removed = false
        for path in paths {
            if let id = identityByPath.removeValue(forKey: path) { results[id] = nil; removed = true }
            // A removed or renamed folder takes its results with it.
            let prefix = path.hasSuffix("/") ? path : path + "/"
            for (p, id) in identityByPath where p.hasPrefix(prefix) {
                identityByPath[p] = nil
                results[id] = nil
                removed = true
            }
        }
        if removed { changed() }
    }

    private func filesChanged(_ paths: [String], mustRescan: Bool) {
        guard let evaluator, let filter else { return }
        if mustRescan || paths.count > 2000 {
            DispatchQueue.main.async { [weak self] in
                self?.coverage.mayBeStale = true
                self?.changed()
            }
            return
        }
        var gone: [String] = []
        var updated: [SearchHit] = []
        var nonMatching: [String] = []
        for path in Set(paths) {
            guard FileIdentity.of(path: path) != nil else { gone.append(path); continue }
            guard filter.accepts(path) else { continue }
            if let hit = SearchCandidates.hit(path: path, evaluator: evaluator, authors: nil, acceptUnknown: false,
                                              readContents: evaluator.needsContents) {
                updated.append(hit)
            } else {
                nonMatching.append(path)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.remove(paths: gone + nonMatching)
            // A changed file gets fresh metadata (size, date).
            for hit in updated {
                if let old = self.identityByPath[hit.item.url.path], old != hit.identity { self.results[old] = nil }
                self.results[hit.identity] = nil
            }
            self.merge(updated)
        }
    }

    deinit {
        direct?.cancel()
        spotlight?.cancel()
        extraSearches.forEach { $0.cancel() }
        watcher?.stop()
    }
}

/// Builds hits for single paths (Spotlight results, file events).
enum SearchCandidates {
    static func hit(path: String, evaluator: SearchEvaluator, authors: [String]?, acceptUnknown: Bool, readContents: Bool) -> SearchHit? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey, .creationDateKey, .typeIdentifierKey,
                                         .localizedTypeDescriptionKey, .tagNamesKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = v.isDirectory ?? false
        let isPackage = v.isPackage ?? false
        let isFolder = isDirectory && !isPackage
        let content = readContents && !isDirectory
            ? TextContent(url: url, typeIdentifier: v.typeIdentifier, size: v.fileSize.map(Int64.init)) : nil
        let candidate = SearchCandidate(
            name: v.name ?? url.lastPathComponent, folderPath: url.deletingLastPathComponent().path, isFolder: isFolder,
            isPackage: isPackage, isSymbolicLink: v.isSymbolicLink ?? false,
            size: isFolder ? nil : v.fileSize.map(Int64.init), modified: v.contentModificationDate, created: v.creationDate,
            typeIdentifier: v.typeIdentifier, typeDescription: v.localizedTypeDescription, tags: v.tagNames ?? [],
            authors: authors, contentContains: content.map { c in { c.contains($0) } })
        let match = evaluator.evaluate(candidate)
        guard match.truth == .yes || (match.truth == .unknown && acceptUnknown),
              let item = FileItem(url: url), let identity = FileIdentity.of(path: path) else { return nil }
        var reasons = match.reasons
        if reasons.isEmpty, match.truth == .unknown {
            // Accepted on the index's word: Arbor couldn't check contents or authors.
            reasons = evaluator.expression.properties.contains(.author) ? [.property(.author)] : [.contents]
        }
        return SearchHit(item: item, identity: identity, reasons: reasons)
    }
}

/// Applies the direct scan's scope rules to paths from the index or file events: inside the scope,
/// one level for "Current folder", no hidden folders, packages (unless asked) or other disks.
final class ScopeFilter {
    let scopePaths: [String]
    let recursive: Bool
    let includeHidden: Bool
    let enterPackages: Bool
    private var cache: [String: Bool] = [:]
    private let lock = NSLock()

    init(scope: URL, recursive: Bool, includeHidden: Bool, enterPackages: Bool) {
        var paths = [scope.path]
        if let real = realpath(scope.path, nil) {
            paths.append(String(cString: real))
            free(real)
        }
        scopePaths = Array(Set(paths.map { $0 == "/" ? "" : $0 }))
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.enterPackages = enterPackages
    }

    func accepts(_ path: String) -> Bool {
        guard let base = scopePaths.first(where: { path.hasPrefix($0 + "/") }) else { return false }
        let relative = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard !relative.isEmpty, recursive || relative.count == 1 else { return false }
        var dir = base
        for component in relative.dropLast() {
            dir += "/" + component
            if !directoryAllowed(dir, name: component) { return false }
        }
        if !includeHidden, let name = relative.last {
            if name.hasPrefix(".") { return false }
            if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isHiddenKey]).isHidden) == true { return false }
        }
        return true
    }

    private func directoryAllowed(_ dir: String, name: String) -> Bool {
        lock.lock()
        if let cached = cache[dir] { lock.unlock(); return cached }
        lock.unlock()
        var allowed = true
        if !includeHidden, name.hasPrefix(".") { allowed = false }
        if allowed, let v = try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.isHiddenKey, .isPackageKey, .isVolumeKey, .isSymbolicLinkKey]) {
            if !includeHidden, v.isHidden == true { allowed = false }
            if !enterPackages, v.isPackage == true { allowed = false }
            if v.isVolume == true || v.isSymbolicLink == true { allowed = false }
        }
        lock.lock()
        if cache.count > 5000 { cache.removeAll() }
        cache[dir] = allowed
        lock.unlock()
        return allowed
    }
}

/// Sessions behind search tabs: a small LRU so Back/Forward and tab switches are instant; running
/// searches no tab shows are cancelled (spec §10.4, §15.3).
enum SearchSessions {
    static var limit = 4
    private static var sessions: [SearchSession] = []

    static func existing(_ request: SearchRequest, showHidden: Bool) -> SearchSession? {
        let key = SearchSession.key(request, showHidden: showHidden)
        return sessions.first { $0.key == key }
    }

    /// The session for a request, started if new or if it was stopped earlier.
    static func session(for request: SearchRequest, showHidden: Bool) -> SearchSession {
        if let existing = existing(request, showHidden: showHidden), !existing.wasStopped {
            touch(existing)
            return existing
        }
        return restart(request, showHidden: showHidden)
    }

    @discardableResult
    static func restart(_ request: SearchRequest, showHidden: Bool) -> SearchSession {
        let key = SearchSession.key(request, showHidden: showHidden)
        let session = SearchSession(request: request, showHidden: showHidden)
        if let old = sessions.first(where: { $0.key == key }) {
            old.cancel()
            sessions.removeAll { $0 === old }
            session.adoptObservers(from: old)   // tabs showing it (Refresh) follow the new run
        }
        sessions.append(session)
        while sessions.count > limit {
            let evicted = sessions.removeFirst()
            evicted.cancel()
        }
        session.start()
        return session
    }

    private static func touch(_ session: SearchSession) {
        sessions.removeAll { $0 === session }
        sessions.append(session)
    }

    /// Cancels running searches that no tab in any window shows or is about to show.
    static func cancelUnreferenced() {
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        var keys = Set<String>()
        for controller in controllers {
            for tab in controller.tabs {
                for location in [tab.location, tab.displayedLocation].compactMap({ $0 }) {
                    if case .search(let r) = location { keys.insert(Location.search(r).key) }
                }
            }
        }
        for session in sessions where session.isRunning && !keys.contains(Location.search(session.request).key) {
            session.cancel()
        }
    }

    /// Stops a search that's about to be replaced while typing.
    static func cancel(_ request: SearchRequest, superseded: Bool = false) {
        for session in sessions where session.isRunning && session.request == request { session.cancel(superseded: superseded) }
    }

    static func reasons(forPath path: String) -> Set<SearchReason>? {
        for session in sessions.reversed() { if let r = session.reasons(forPath: path) { return r } }
        return nil
    }

    static var debugSummary: String { sessions.map { "\($0.request.query)=\($0.count)" }.joined(separator: ",") }
}
