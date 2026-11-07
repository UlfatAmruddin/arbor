import AppKit
import ArborCore

/// Puts the app-wide caches in `CacheRegistry` (sizes for benchmarks, trimming under memory pressure)
/// and keeps volume lookups fresh when disks come and go (spec §15.3, FE-251).
enum PerformanceCaches {
    private static var observers: [NSObjectProtocol] = []

    static func register() {
        let registry = CacheRegistry.shared
        registry.register("thumbnails", budget: CacheBudgets.thumbnailBytes,
                          bytes: { ThumbnailService.shared.cache.totalCost }, count: { ThumbnailService.shared.cache.count }) { level in
            let cache = ThumbnailService.shared.cache
            if level == .critical { cache.removeAll() } else { cache.trim(toBytes: cache.byteLimit / 4) }
        }
        registry.register("icons", budget: CacheBudgets.iconBytes,
                          bytes: { IconProvider.shared.cachedBytes }, count: { IconProvider.shared.cachedCount }) { level in
            IconProvider.shared.trim(level)
        }
        registry.register("listings", budget: CacheBudgets.tabListingBytes,
                          bytes: { TabState.listingBudget.totalCost }, count: { TabState.listingBudget.count }) { level in
            TabState.trimListings(toBytes: level == .critical ? 0 : CacheBudgets.tabListingBytes / 4)
        }
        // Bounded by count, reported with an estimate (a Details metadata row ~0.5 KB, an archive entry ~0.3 KB).
        registry.register("metadata", budget: ColumnValueStore.shared.limit * 512,
                          bytes: { ColumnValueStore.shared.count * 512 }, count: { ColumnValueStore.shared.count }) { _ in
            ColumnValueStore.shared.removeAll()
        }
        registry.register("archives", budget: 0, bytes: { ArchiveCatalog.shared.entryCount * 300 },
                          count: { ArchiveCatalog.shared.entryCount }) { level in
            ArchiveCatalog.shared.trim(keeping: level == .critical ? 0 : 1)
        }
        registry.startMonitoringPressure()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MountPoints.shared.invalidate()
                FileOps.forgetVolumes()
            })
        }
    }
}
