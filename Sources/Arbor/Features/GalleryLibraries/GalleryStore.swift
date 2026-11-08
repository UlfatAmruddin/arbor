import AppKit
import ArborCore
import ImageIO
import UniformTypeIdentifiers

/// Gallery preferences: folders and thumbnail size.
enum GalleryPrefs {
    static let changed = Notification.Name("ArborGalleryCollectionChanged")
    private static let collectionKey = "gallery.collection.v1"

    static var collection: GalleryCollection {
        get {
            if let data = Prefs.store.data(forKey: collectionKey),
               let value = try? JSONDecoder().decode(GalleryCollection.self, from: data) { return value }
            return GalleryCollection.defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { Prefs.store.set(data, forKey: collectionKey) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// View ▾ size in Gallery: target row height for each icon size.
    static var size: ViewMode {
        get { ViewMode(rawValue: Prefs.store.string(forKey: "gallery.size") ?? "") ?? .largeIcons }
        set {
            Prefs.store.set(newValue.rawValue, forKey: "gallery.size")
            NotificationCenter.default.post(name: changed, object: nil, userInfo: ["size": true])
        }
    }

    static var newestFirst: Bool {
        get { Prefs.store.object(forKey: "gallery.newestFirst") as? Bool ?? true }
        set {
            Prefs.store.set(newValue, forKey: "gallery.newestFirst")
            NotificationCenter.default.post(name: changed, object: nil, userInfo: ["order": true])
        }
    }

    static let sizes: [ViewMode] = [.extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons]

    static func rowHeight(_ mode: ViewMode) -> CGFloat {
        switch mode {
        case .extraLargeIcons: return 280
        case .mediumIcons: return 120
        case .smallIcons: return 76
        default: return 184
        }
    }
}

/// App-wide Gallery index (newest first, capped at `limit`), shared so returning to Gallery is instant.
/// Scans run off-main in batches and stop when no Gallery page is shown (spec §15.3).
final class GalleryStore {
    static let shared = GalleryStore()
    static let changed = Notification.Name("ArborGalleryStoreChanged")
    static let limit = 100_000

    private var itemSet = GalleryItemSet(limit: GalleryStore.limit)
    private var scanner: GalleryScanner?
    private var scannedRoots: [String] = []
    private var lastScan: Date?
    private var clients = NSHashTable<AnyObject>.weakObjects()
    private(set) var isScanning = false
    /// Folders unreadable on the last scan (partial coverage).
    private(set) var unavailable: [URL] = []
    private var visibleCache: [GalleryItem]?

    /// Items shown now: in an included folder, sorted by date.
    var items: [GalleryItem] {
        if let visibleCache { return visibleCache }
        let collection = GalleryPrefs.collection
        let shown = GalleryTimeline.sorted(itemSet.all.filter { GalleryScanRules.isVisible(path: $0.key, in: collection) },
                                           newestFirst: GalleryPrefs.newestFirst)
        visibleCache = shown
        return shown
    }

    var droppedForLimit: Int { itemSet.droppedForLimit }

    init() {
        NotificationCenter.default.addObserver(forName: GalleryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.visibleCache = nil
            let roots = Set(GalleryPrefs.collection.scanRoots.map(\.path))
            self.unavailable = self.unavailable.filter { roots.contains($0.path) }
            if !self.clients.allObjects.isEmpty { self.refreshIfNeeded(force: false) }
            self.post()
        }
    }

    /// A page appeared: show the cache; rescan if the collection changed or the index is stale.
    func attach(_ client: AnyObject) {
        clients.add(client)
        refreshIfNeeded(force: false)
    }

    /// A Gallery page went away; scanning stops when none is left.
    func detach(_ client: AnyObject) {
        clients.remove(client)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.clients.allObjects.isEmpty else { return }
            self.cancelScan()
        }
    }

    /// Refresh or a reload after Trash/rename: rescan now.
    func refresh() { refreshIfNeeded(force: true) }

    private func refreshIfNeeded(force: Bool) {
        let roots = GalleryPrefs.collection.scanRoots
        let covered = Set(roots.map(\.path)).isSubset(of: Set(scannedRoots))
        if !force, covered, isScanning { return }   // the running scan already covers these folders
        let fresh = lastScan.map { Date().timeIntervalSince($0) < 120 } ?? false
        if !force, covered, fresh { return }        // unchecking or removing a folder only filters
        startScan(roots)
    }

    private func startScan(_ roots: [URL]) {
        cancelScan()
        scannedRoots = roots.map(\.path)
        guard !roots.isEmpty else {
            itemSet.retain { _ in false }
            unavailable = []
            lastScan = Date()
            visibleCache = nil
            post()
            return
        }
        isScanning = true
        var seen = Set<String>()
        let scanner = GalleryScanner(roots: roots)
        scanner.onBatch = { [weak self] batch in
            guard let self else { return }
            batch.forEach { seen.insert($0.key) }
            self.itemSet.insert(batch)
            self.visibleCache = nil
            self.post()
        }
        scanner.onFinish = { [weak self] summary in
            guard let self else { return }
            self.isScanning = false
            self.scanner = nil
            self.unavailable = summary.unavailable
            if !summary.cancelled {
                // A complete scan is the truth for its roots: drop missing items.
                let rootPaths = roots.map(\.path)
                let missing = summary.unavailable.map(\.path)
                self.itemSet.retain { key in
                    seen.contains(key) || missing.contains { GalleryScanRules.isInside(key, $0) }
                        || !rootPaths.contains { GalleryScanRules.isInside(key, $0) }
                }
                self.lastScan = Date()
            }
            self.visibleCache = nil
            self.post()
        }
        self.scanner = scanner
        scanner.start()
        post()
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        if isScanning { isScanning = false; lastScan = nil; post() }
    }

    /// Drops trashed or renamed items now; the next scan confirms.
    func forget(_ urls: [URL]) {
        itemSet.remove(keys: urls.map { Location.normalizedKey($0) })
        visibleCache = nil
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

// MARK: - Scanner

struct GalleryScanSummary {
    var unavailable: [URL]
    var cancelled: Bool
}

/// Finds photos and videos off-main: Spotlight first (fast when indexed), then a direct enumeration
/// for what it missed, with ImageIO EXIF. Skips packages and hidden files; never writes. `cancel()` stops both.
final class GalleryScanner {
    var onBatch: (([GalleryItem]) -> Void)?
    var onFinish: ((GalleryScanSummary) -> Void)?
    private let roots: [URL]
    private let queue = OperationQueue()
    private let cancelLock = NSLock()
    private var _cancelled = false
    private var query: NSMetadataQuery?
    private var spotlightTimeout: DispatchWorkItem?
    private var gatherObserver: NSObjectProtocol?
    private var known = Set<String>()
    /// `ARBOR_GALLERY_NO_SPOTLIGHT=1` forces the direct scan (tests).
    private let useSpotlight = Automation.environment["ARBOR_GALLERY_NO_SPOTLIGHT"] == nil

    private var cancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _cancelled
    }

    init(roots: [URL]) {
        self.roots = roots
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    func start() {
        guard useSpotlight else { directScan(); return }
        let query = NSMetadataQuery()
        query.operationQueue = queue
        query.searchScopes = roots
        query.predicate = NSPredicate(format: "%K == 'public.image' || %K == 'public.movie'",
                                      NSMetadataItemContentTypeTreeKey, NSMetadataItemContentTypeTreeKey)
        self.query = query
        gatherObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue) { [weak self] _ in
            self?.spotlightFinished(query)
        }
        // Spotlight can be off or slow: wait a few seconds at most.
        let timeout = DispatchWorkItem { [weak self] in
            self?.queue.addOperation { self?.spotlightFinished(query) }
        }
        spotlightTimeout = timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: timeout)
        queue.addOperation { if !query.start() { self.spotlightFinished(query) } }
    }

    func cancel() {
        cancelLock.lock(); _cancelled = true; cancelLock.unlock()
        spotlightTimeout?.cancel()
        queue.addOperation { [query] in query?.stop() }
    }

    // Runs on `queue`.
    private func spotlightFinished(_ query: NSMetadataQuery) {
        guard self.query === query else { return }
        self.query = nil
        if let gatherObserver { NotificationCenter.default.removeObserver(gatherObserver) }
        gatherObserver = nil
        spotlightTimeout?.cancel()
        query.disableUpdates()
        var batch: [GalleryItem] = []
        for index in 0..<query.resultCount {
            if cancelled { break }
            guard let result = query.result(at: index) as? NSMetadataItem,
                  let path = result.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !GalleryScanRules.isExcluded(path: path), !isHiddenBelowRoot(path),
                  let tree = result.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String],
                  let kind = GalleryScanRules.kind(forContentTypeTree: tree) else { continue }
            let taken = result.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
            let created = result.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
            let modified = result.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            let width = (result.value(forAttribute: NSMetadataItemPixelWidthKey) as? NSNumber)?.doubleValue ?? 0
            let height = (result.value(forAttribute: NSMetadataItemPixelHeightKey) as? NSNumber)?.doubleValue ?? 0
            let orientation = (result.value(forAttribute: NSMetadataItemOrientationKey) as? NSNumber)?.intValue ?? 0
            // kMDItemOrientation: 0 = landscape, 1 = portrait (already the displayed shape).
            var aspect = GalleryTimeline.aspect(width: width, height: height)
            if let a = aspect, orientation == 1, a > 1 { aspect = 1 / a }
            guard let date = GalleryTimeline.bestDate(taken: taken, created: created, modified: modified) else { continue }
            let size = (result.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
            let item = GalleryItem(url: URL(fileURLWithPath: path), date: date, kind: kind, size: size,
                                   aspect: aspect ?? (kind == .video ? 16.0 / 9 : nil), modified: modified)
            known.insert(item.key)
            batch.append(item)
            if batch.count >= 500 { deliver(batch); batch = [] }
        }
        query.stop()
        deliver(batch)
        directScan()
    }

    private func isHiddenBelowRoot(_ path: String) -> Bool {
        guard let root = roots.first(where: { GalleryScanRules.isInside(path, $0.path) }) else { return false }
        return path.dropFirst(root.path.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }

    private func directScan() {
        queue.addOperation { [weak self] in self?.enumerateRoots() }
    }

    // Runs on `queue`.
    private func enumerateRoots() {
        var unavailable: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .creationDateKey,
                                      .contentModificationDateKey, .fileSizeKey, .contentTypeKey]
        var batch: [GalleryItem] = []
        var lastDelivery = Date()
        for root in roots {
            if cancelled { break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                unavailable.append(root)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                                  errorHandler: { _, _ in true }) else {
                unavailable.append(root)
                continue
            }
            for case let url as URL in enumerator {
                if cancelled { break }
                let path = url.standardizedFileURL.path
                if GalleryScanRules.isExcluded(path: path) { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let kind = values.contentType.flatMap(Self.kind(for:)) ?? GalleryScanRules.kind(forExtension: url.pathExtension)
                else { continue }
                let key = Location.normalizedKey(url)
                if known.contains(key) { continue }
                known.insert(key)
                let meta = kind == .image ? Self.imageMetadata(url) : (taken: nil, aspect: 16.0 / 9)
                guard let date = GalleryTimeline.bestDate(taken: meta.taken, created: values.creationDate,
                                                          modified: values.contentModificationDate) else { continue }
                batch.append(GalleryItem(url: url, date: date, kind: kind, size: values.fileSize.map(Int64.init),
                                         aspect: meta.aspect, modified: values.contentModificationDate))
                if batch.count >= 300 || (Date().timeIntervalSince(lastDelivery) > 0.3 && !batch.isEmpty) {
                    deliver(batch)
                    batch = []
                    lastDelivery = Date()
                }
            }
        }
        deliver(batch)
        let wasCancelled = cancelled
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?(GalleryScanSummary(unavailable: unavailable, cancelled: wasCancelled))
        }
    }

    private static func kind(for type: UTType) -> GalleryMediaKind? {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    /// EXIF date taken and displayed aspect ratio, from the header only.
    static func imageMetadata(_ url: URL) -> (taken: Date?, aspect: Double?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        else { return (nil, nil) }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        return (text.flatMap { GalleryTimeline.parseExifDate($0) },
                GalleryTimeline.aspect(width: width, height: height, orientation: orientation))
    }

    private func deliver(_ batch: [GalleryItem]) {
        guard !batch.isEmpty, !cancelled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onBatch?(batch)
        }
    }
}
