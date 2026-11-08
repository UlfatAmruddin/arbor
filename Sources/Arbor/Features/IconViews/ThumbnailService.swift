import AppKit
import ImageIO
import QuickLookThumbnailing
import ArborCore

/// App-wide thumbnail cache (FE-149, FE-243, spec §15.3): one byte budget for all windows, keyed by
/// path + mod date + size + pixel size so replaced files never show stale. Main thread only.
final class ThumbnailService {
    static let shared = ThumbnailService()

    /// Decoded-bytes budget; 64 MB ≈ 64 Extra large or ~1,700 Medium thumbnails.
    static var defaultByteLimit: Int { CacheBudgets.thumbnailBytes }   // ARBOR_THUMBNAIL_BUDGET_MB overrides

    let cache = ByteBudgetCache<ThumbnailKey, CGImage>(byteLimit: ThumbnailService.defaultByteLimit)
    /// Files the generator couldn't thumbnail (bounded; cleared when it grows).
    private var failed = Set<ThumbnailKey>()
    private var pressure: DispatchSourceMemoryPressure?

    private(set) var generated = 0
    private(set) var cancelled = 0
    private(set) var failures = 0

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.critical) { self.cache.removeAll() } else { self.cache.trim(toBytes: self.cache.byteLimit / 4) }
        }
        source.resume()
        pressure = source
    }

    /// Best cached image: exact size, else smallest larger, else a smaller placeholder (`exact` false).
    func image(for key: ThumbnailKey) -> (image: CGImage, exact: Bool)? {
        if let hit = cache.value(for: key) { return (hit, true) }
        var placeholder: CGImage?
        for pixels in Self.knownPixelSizes {
            guard pixels != key.pixels, let other = cache.peek(key.resized(pixels)) else { continue }
            if pixels > key.pixels { return (other, true) }
            placeholder = other
        }
        return placeholder.map { ($0, false) }
    }

    func hasFailed(_ key: ThumbnailKey) -> Bool { failed.contains(key) }

    /// Pixel sizes used by the layouts at 1× and 2× (48, 96, 256 pt icons).
    static let knownPixelSizes: [Int] = [48, 72, 96, 144, 192, 256, 384, 512]

    func store(_ image: CGImage, for key: ThumbnailKey) {
        generated += 1
        cache.insert(image, for: key, cost: ThumbnailPolicy.decodedCost(width: image.width, height: image.height,
                                                                         bytesPerRow: image.bytesPerRow))
    }

    func markFailed(_ key: ThumbnailKey) {
        failures += 1
        if failed.count > 4000 { failed.removeAll() }
        failed.insert(key)
    }

    func noteCancelled() { cancelled += 1 }

    var debugSummary: String {
        "thumbnails: cached=\(cache.count) bytes=\(cache.totalCost) limit=\(cache.byteLimit) generated=\(generated) failed=\(failures) cancelled=\(cancelled)"
    }
}

/// Per-view thumbnail requests (FE-242): on-screen items only, a few at a time, cancelled on scroll
/// or folder change. Late results are checked against the generation and the item's identity.
final class ThumbnailLoader {
    private var inFlight: [ThumbnailKey: QLThumbnailGenerator.Request] = [:]
    /// Keys requested while on screen; an evicted one shows its icon instead of regenerating in a loop.
    private var attempted = Set<ThumbnailKey>()
    private var generation = 0
    let maxConcurrent = 8
    /// Called on the main thread when a thumbnail arrives for a key that's still wanted.
    var onLoaded: ((ThumbnailKey) -> Void)?

    var inFlightCount: Int { inFlight.count }

    /// Cancels everything (folder change, view removed).
    func reset() {
        generation += 1
        for request in inFlight.values {
            QLThumbnailGenerator.shared.cancel(request)
            ThumbnailService.shared.noteCancelled()
        }
        inFlight.removeAll()
        attempted.removeAll()
    }

    /// `wanted` is in priority order (visible items first). Requests not in it are cancelled.
    func update(wanted: [(item: FileItem, key: ThumbnailKey, points: CGFloat, scale: CGFloat)]) {
        let wantedKeys = Set(wanted.map(\.key))
        for (key, request) in inFlight where !wantedKeys.contains(key) {
            QLThumbnailGenerator.shared.cancel(request)
            inFlight[key] = nil
            ThumbnailService.shared.noteCancelled()
        }
        attempted.formIntersection(wantedKeys)
        let service = ThumbnailService.shared
        for entry in wanted {
            guard inFlight.count < maxConcurrent else { break }
            guard inFlight[entry.key] == nil, !attempted.contains(entry.key), !service.cache.contains(entry.key),
                  !service.hasFailed(entry.key) else { continue }
            attempted.insert(entry.key)
            start(entry.item, key: entry.key, points: entry.points, scale: entry.scale)
        }
    }

    private func start(_ item: FileItem, key: ThumbnailKey, points: CGFloat, scale: CGFloat) {
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: points, height: points),
                                                   scale: scale, representationTypes: .thumbnail)
        inFlight[key] = request
        let token = generation
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.cgImage
            DispatchQueue.main.async {
                guard let self else { return }
                // Stale: the folder changed, or this request was cancelled and maybe re-issued.
                guard token == self.generation, self.inFlight[key] === request else { return }
                self.inFlight[key] = nil
                if let image { ThumbnailService.shared.store(image, for: key) } else { ThumbnailService.shared.markFailed(key) }
                self.onLoaded?(key)
            }
        }
    }

    deinit { reset() }
}

/// Pixel dimensions for Content, read from headers off-main for visible items, cached by file version.
final class ImageInfoService {
    static let shared = ImageInfoService()
    private let cache = ByteBudgetCache<ThumbnailKey, String>(byteLimit: 5000)
    private var pending = Set<ThumbnailKey>()
    private let queue = DispatchQueue(label: "arbor.imageinfo", qos: .utility)
    private let lock = NSLock()
    private var currentGeneration = 0
    /// Also read from the background queue, hence the lock.
    private var generation: Int { lock.withLock { currentGeneration } }

    func dimensions(for item: FileItem) -> String? { cache.value(for: ThumbnailKey(item: item, pixels: 0)) }

    func cancelPending() {
        lock.withLock { currentGeneration += 1 }
        pending.removeAll()
    }

    func request(_ item: FileItem, completion: @escaping () -> Void) {
        let key = ThumbnailKey(item: item, pixels: 0)
        guard cache.peek(key) == nil, !pending.contains(key), pending.count < 64 else { return }
        pending.insert(key)
        let token = generation
        let url = item.url
        queue.async { [weak self] in
            guard let self else { return }
            var text = ""
            if token == self.generation,
               let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                text = "\(w) x \(h)"
            }
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.pending.remove(key)
                self.cache.insert(text, for: key, cost: 1)
                completion()
            }
        }
    }
}
