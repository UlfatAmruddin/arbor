import AppKit
import ArborCore

/// The cloud roots on this Mac. Headless runs use only `ARBOR_TEST_CLOUD_ROOT`, never the user's folders.
enum CloudEnvironment {
    private(set) static var roots: [CloudRoot] = detect()
    static let testStatuses: [String: CloudStatus] =
        CloudRoots.parseTestStatuses(Automation.environment["ARBOR_TEST_CLOUD_STATUS"] ?? "")

    private static func detect() -> [CloudRoot] {
        let env = Automation.environment
        if AppDelegate.isHeadless { return CloudRoots.testRoots(environment: env) }
        return CloudRoots.detect(home: FileManager.default.homeDirectoryForCurrentUser) + CloudRoots.testRoots(environment: env)
    }

    /// Re-detects (cheap); returns whether the set changed.
    @discardableResult
    static func refresh() -> Bool {
        let fresh = detect()
        defer { roots = fresh }
        if fresh != roots { CloudCapabilityStore.shared.invalidateAll() }
        return fresh != roots
    }

    static func root(containing url: URL) -> CloudRoot? { CloudRoots.root(containing: url, in: roots) }

    static func root(for location: Location?) -> CloudRoot? { location?.folderURL.flatMap(root(containing:)) }

    static var iCloudRoot: CloudRoot? { roots.first { $0.kind == .iCloud } }

    private static let simulatedInfo = CloudRoots.simulatedInfo(reporting: Automation.environment["ARBOR_TEST_CLOUD_KEYS"])

    /// What a simulated provider answers for this item; nil for anything real, which must be read.
    static func simulatedInfo(for url: URL) -> UbiquityInfo? {
        root(containing: url)?.kind == .test ? simulatedInfo : nil
    }

    /// The failure a simulated provider's root listing is set up to have.
    static func simulatedListingFailure(of root: CloudRoot) -> Error? {
        guard root.kind == .test else { return nil }
        return Automation.environment["ARBOR_TEST_CLOUD_ROOT_ERROR"].flatMap(CloudProviderError.simulatedListingFailure)
    }
}

/// Bounded main-thread cache of item statuses, read in background batches for displayed rows.
/// Only reads metadata keys; never downloads.
final class CloudStatusStore {
    static let shared = CloudStatusStore()
    static let changed = Notification.Name("ArborCloudStatusChanged")

    struct Entry: Equatable {
        let status: CloudStatus
        /// The system reports the item as ubiquitous (provider actions can apply).
        let ubiquitous: Bool
        let time: Date
    }

    static let limit = 4000
    static let freshness: TimeInterval = 15

    private var cache: [String: Entry] = [:]
    private var pending = Set<String>()
    private var queued: [URL] = []
    private var flushScheduled = false
    private var postScheduled = false
    private let queue = DispatchQueue(label: "arbor.cloud-status", qos: .utility)

    /// Cached entry (possibly stale); schedules a read when missing or stale. Main thread.
    func entry(for url: URL) -> Entry? {
        if let override = testOverride(url) { return Entry(status: override, ubiquitous: true, time: Date()) }
        let key = url.standardizedFileURL.path
        let hit = cache[key]
        if hit == nil || Date().timeIntervalSince(hit!.time) > Self.freshness { request(url) }
        return hit
    }

    func status(for url: URL) -> CloudStatus? { entry(for: url)?.status }

    /// Forgets and re-reads items (after Download / Free up space).
    func invalidate(_ urls: [URL]) {
        for url in urls {
            cache[url.standardizedFileURL.path] = nil
            request(url)
        }
    }

    /// Reads fresh statuses now (background) and hands them back on the main thread.
    func read(_ urls: [URL], completion: @escaping ([CloudStatus]) -> Void) {
        let overrides = urls.map(testOverride)
        queue.async {
            let statuses = zip(urls, overrides).map { url, override in
                override ?? UbiquityInfo.read(url).map(CloudStatusMapper.status) ?? .unknown
            }
            DispatchQueue.main.async { completion(statuses) }
        }
    }

    private func testOverride(_ url: URL) -> CloudStatus? {
        guard let root = CloudEnvironment.root(containing: url), root.kind == .test else { return nil }
        return CloudEnvironment.testStatuses[url.lastPathComponent]
    }

    private func request(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard !pending.contains(key) else { return }
        pending.insert(key)
        queued.append(url)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { self.flush() }
    }

    private func flush() {
        flushScheduled = false
        let batch = queued
        queued = []
        guard !batch.isEmpty else { return }
        let simulated = batch.map(CloudEnvironment.simulatedInfo(for:))
        queue.async {
            let results = zip(batch, simulated).map { url, simulated in (url: url, info: simulated ?? UbiquityInfo.read(url)) }
            DispatchQueue.main.async { self.store(results) }
        }
    }

    private func store(_ results: [(url: URL, info: UbiquityInfo?)]) {
        var changedAny = false
        let now = Date()
        CloudCapabilityStore.shared.observe(results)
        for (url, info) in results {
            let key = url.standardizedFileURL.path
            pending.remove(key)
            let entry = Entry(status: info.map(CloudStatusMapper.status) ?? .unknown, ubiquitous: info?.isUbiquitous == true, time: now)
            if cache[key]?.status != entry.status || cache[key]?.ubiquitous != entry.ubiquitous { changedAny = true }
            cache[key] = entry
        }
        if cache.count > Self.limit {
            let keep = cache.sorted { $0.value.time > $1.value.time }.prefix(Self.limit * 3 / 4)
            cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if changedAny { postChanged() }
    }

    private func postChanged() {
        guard !postScheduled else { return }
        postScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.postScheduled = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
}

/// Status glyphs (SF Symbols, our own colors).
enum CloudGlyph {
    static func image(_ status: CloudStatus, size: CGFloat) -> NSImage {
        let (symbol, color): (String, UInt32) = {
            switch status {
            case .availableOnDevice: return ("checkmark.circle", 0x2E9E44)
            case .onlineOnly: return ("cloud", 0x1F6FC5)
            case .downloading, .uploading: return ("arrow.triangle.2.circlepath", 0x1F6FC5)
            case .syncPending: return ("arrow.triangle.2.circlepath", 0x8A8A8A)
            case .conflict: return ("exclamationmark.triangle.fill", 0xC77700)
            case .error: return ("xmark.circle", 0xC42B1C)
            case .signInRequired: return ("person.crop.circle.badge.exclamationmark", 0xC42B1C)
            case .unknown: return ("questionmark.circle", 0x8A8A8A)
            }
        }()
        return IconProvider.shared.symbolIcon(symbol, color: color, size: size)
    }

    static func rootIcon(_ root: CloudRoot, size: CGFloat) -> NSImage {
        if CloudCapabilityStore.shared.probe(for: root)?.needsSignIn == true {
            return IconProvider.shared.symbolIcon("exclamationmark.icloud.fill", color: 0xC42B1C, size: size)
        }
        return root.kind == .iCloud ? IconProvider.shared.symbolIcon("icloud.fill", color: 0x3D8BE0, size: size)
                             : IconProvider.shared.symbolIcon("cloud.fill", color: 0x1F6FC5, size: size)
    }
}

/// Status cell: glyph only, with the wording as tooltip and accessibility label.
final class CloudStatusCell: NSTableCellView {
    let glyph = NSImageView()

    static func make(_ table: NSTableView) -> CloudStatusCell {
        let id = NSUserInterfaceItemIdentifier("CloudStatusCell")
        if let reused = table.makeView(withIdentifier: id, owner: nil) as? CloudStatusCell { return reused }
        let cell = CloudStatusCell()
        cell.identifier = id
        return cell
    }

    init() {
        super.init(frame: .zero)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        imageView = glyph
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ status: CloudStatus?) {
        glyph.image = status.map { CloudGlyph.image($0, size: 16) }
        toolTip = status?.title ?? L10n.tr("Checking status…")
        setAccessibilityLabel(status?.title ?? L10n.tr("Checking status"))
    }
}
