import Foundation

/// How hard a cache should shrink.
public enum CacheTrimLevel: Int, Comparable, Sendable {
    /// System memory is getting tight: keep roughly a quarter of the budget (what is on screen).
    case warning = 1
    /// Memory is critical: drop everything that can be rebuilt.
    case critical = 2

    public static func < (a: CacheTrimLevel, b: CacheTrimLevel) -> Bool { a.rawValue < b.rawValue }
}

/// App-wide byte budgets for every reconstructible cache (spec §15.3, FE-251). One table so the
/// total is known and reviewed in one place; the numbers and the measurements behind them are in
/// docs/PERFORMANCE.md. Environment overrides exist for benchmarks only.
public enum CacheBudgets {
    /// Decoded thumbnails, all windows (FE-243).
    public static var thumbnailBytes: Int { megabytes("ARBOR_THUMBNAIL_BUDGET_MB", 64) }
    /// File and folder icons (rendered representations).
    public static var iconBytes: Int { megabytes("ARBOR_ICON_BUDGET_MB", 12) }
    /// Listings kept for inactive tabs so switching back is instant.
    public static var tabListingBytes: Int { megabytes("ARBOR_LISTING_BUDGET_MB", 48) }
    /// Sum of the budgets above: the most the byte-budgeted caches may hold together. (Details
    /// metadata, archive directories, search sessions and image dimensions are bounded by count; see docs/PERFORMANCE.md.)
    public static var totalBytes: Int { thumbnailBytes + iconBytes + tabListingBytes }

    private static func megabytes(_ variable: String, _ fallback: Int) -> Int {
        if let text = ProcessInfo.processInfo.environment[variable], let mb = Int(text), mb >= 0 { return mb << 20 }
        return fallback << 20
    }

    /// Estimated resident cost of one listing row (`FileItem`: URL, name, type string, dates). Measured
    /// on 100,000-entry folders (docs/PERFORMANCE.md); used to budget listings by bytes, not count.
    public static func listingCost(_ item: FileItem) -> Int {
        // Fixed struct + URL object + string storage (UTF-8, path held twice: URL and name).
        320 + item.url.path.utf8.count + item.name.utf8.count * 2 + item.typeDescription.utf8.count
    }

    /// Estimated from up to 256 evenly spread rows, so it stays cheap for 100,000-entry listings.
    public static func listingCost(_ items: [FileItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        let step = max(1, items.count / 256)
        var sampled = 0, total = 0
        for i in stride(from: 0, to: items.count, by: step) {
            total += listingCost(items[i])
            sampled += 1
        }
        return total * items.count / sampled
    }
}

/// Registry of app-wide caches: one place that reports their sizes and trims them all when the system
/// signals memory pressure. Main thread only.
public final class CacheRegistry {
    public static let shared = CacheRegistry()

    public struct Entry {
        public let name: String
        public let budget: Int
        public let bytes: () -> Int
        public let count: () -> Int
        public let trim: (CacheTrimLevel) -> Void
    }

    public private(set) var entries: [Entry] = []
    public private(set) var trims: [CacheTrimLevel] = []

    public init() {}

    /// Registers a cache. Registering a name again replaces it.
    public func register(_ name: String, budget: Int, bytes: @escaping () -> Int, count: @escaping () -> Int,
                         trim: @escaping (CacheTrimLevel) -> Void) {
        entries.removeAll { $0.name == name }
        entries.append(Entry(name: name, budget: budget, bytes: bytes, count: count, trim: trim))
    }

    /// Shrinks every cache.
    public func trim(_ level: CacheTrimLevel) {
        trims.append(level)
        if trims.count > 64 { trims.removeFirst(trims.count - 64) }
        entries.forEach { $0.trim(level) }
    }

    public var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes() } }

    /// `name=bytes/count` for every cache, for logs and benchmarks.
    public var summary: String {
        entries.map { "\($0.name)=\(ProcessMetrics.megabytes(UInt64(max(0, $0.bytes()))))MB/\($0.count())" }.joined(separator: " ")
    }

    private var pressureSource: DispatchSourceMemoryPressure?

    /// Listens for the system's memory pressure notifications and trims on `queue` (the main queue).
    public func startMonitoringPressure(queue: DispatchQueue = .main) {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.trim(event.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        pressureSource = source
    }
}
