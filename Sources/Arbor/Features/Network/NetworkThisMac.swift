import AppKit
import ArborCore

/// Mapped network drives in This Mac's "Network locations" and under This Mac in the navigation
/// pane (FE-177), through the This Mac feature's `VolumeCatalog` hooks: connected shares get their
/// `share (\\server)` label, and mapped drives that aren't connected are listed as unavailable
/// (open = Reconnect). The catalog may be read off the main thread, so it reads a locked snapshot.
enum NetworkThisMac {
    struct Snapshot {
        /// Mount point path → label for connected shares.
        var labels: [String: String] = [:]
        /// Shares the system volume list doesn't contain (the fake network's folders).
        var extraMounted: [(url: URL, label: String)] = []
        /// Disconnected mapped drives: placeholder path → (label, status text, drive id).
        var disconnected: [(url: URL, label: String, status: String, id: UUID)] = []
        var mountPoints: Set<String> = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = Snapshot()

    static var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Placeholder path → mapped drive, for rows of disconnected drives (main thread).
    static func drive(forPlaceholder url: URL) -> MappedDrive? {
        let key = Location.normalizedKey(url)
        guard let id = snapshot.disconnected.first(where: { Location.normalizedKey($0.url) == key })?.id else { return nil }
        return NetworkCenter.shared.drives.drive(id: id)
    }

    /// Where a disconnected mapped drive is listed: its last mount point (so tabs inside it and its
    /// row agree), else `/Volumes/<share>`.
    static func placeholder(for drive: MappedDrive) -> URL {
        URL(fileURLWithPath: drive.lastMountPoint ?? "/Volumes/\(drive.address.share ?? drive.address.hostDisplayName)").standardizedFileURL
    }

    /// Rebuilds the snapshot (main thread), on every network change.
    static func refresh() {
        let center = NetworkCenter.shared
        center.invalidateMounts()
        let shares = center.mountedShares()
        let match = center.drives.match(shares)
        var snap = Snapshot()
        for share in shares {
            let label = center.mappedDrive(for: share)?.label ?? share.address?.driveLabel ?? share.volumeName
            snap.labels[share.mountPoint.path] = label
            snap.mountPoints.insert(Location.normalizedKey(share.mountPoint))
            if center.isFake { snap.extraMounted.append((share.mountPoint, label)) }
        }
        for drive in center.drives.drives where match[drive.id] == nil {
            let status: String
            switch center.status(of: drive) {
            case .connecting: status = "Connecting…"
            case .disconnected(let reason?): status = "Unavailable — \(reason)"
            default: status = "Disconnected"
            }
            snap.disconnected.append((placeholder(for: drive), drive.label, status, drive.id))
        }
        lock.lock()
        current = snap
        lock.unlock()
    }

    static func register() {
        refresh()
        NotificationCenter.default.addObserver(forName: NetworkCenter.changed, object: nil, queue: .main) { _ in refresh() }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in refresh() }
        }

        VolumeCatalog.adjustments.append { volumes in
            let snap = snapshot
            var result = volumes.map { v -> VolumeSummary in
                guard v.kind == .network, let label = snap.labels[v.url.path] else { return v }
                var copy = v
                copy.name = label
                return copy
            }
            var listed = Set(result.map { Location.normalizedKey($0.url) })
            for extra in snap.extraMounted where !listed.contains(Location.normalizedKey(extra.url)) {
                result.append(VolumeSummary(url: extra.url, name: extra.label, kind: .network, isEjectable: true))
                listed.insert(Location.normalizedKey(extra.url))
            }
            for gone in snap.disconnected where !listed.contains(Location.normalizedKey(gone.url)) {
                result.append(VolumeSummary(url: gone.url, name: gone.label, kind: .network))
            }
            return result
        }
        VolumeCatalog.iconOverride = { volume, size in
            guard volume.kind == .network else { return nil }
            let key = Location.normalizedKey(volume.url)
            return NetworkIcons.drive(size, disconnected: snapshot.disconnected.contains { Location.normalizedKey($0.url) == key })
        }
        VolumeCatalog.statusOverride = { volume in
            guard volume.kind == .network else { return nil }
            let key = Location.normalizedKey(volume.url)
            return snapshot.disconnected.first { Location.normalizedKey($0.url) == key }?.status
        }

        // This Mac reloads when mapped drives change state (not only on mount events).
        LocationRegistry.register(ThisMacReloadOnNetworkChange(base: LocationRegistry.provider(for: .thisMac)))
    }
}

/// Passes This Mac through unchanged, adding a reload when mapped drives connect or disconnect.
final class ThisMacReloadOnNetworkChange: LocationProvider {
    private let base: LocationProvider
    init(base: LocationProvider) { self.base = base }

    func handles(_ location: Location) -> Bool { location == .thisMac }
    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        base.load(location, context: context, completion: completion)
    }
    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        var last = NetworkThisMac.snapshot.disconnected.map(\.status) + NetworkThisMac.snapshot.labels.values.sorted()
        let token = NetworkChangeWatcher {
            let now = NetworkThisMac.snapshot.disconnected.map(\.status) + NetworkThisMac.snapshot.labels.values.sorted()
            if now != last { last = now; onChange() }
        }
        token.inner = base.watch(location, onChange: onChange)
        return token
    }
    func title(for location: Location) -> String { base.title(for: location) }
    func icon(for location: Location, size: CGFloat) -> NSImage { base.icon(for: location, size: size) }
    func targetFolder(for location: Location) -> URL? { base.targetFolder(for: location) }
    func allowsItemEditing(in location: Location) -> Bool { base.allowsItemEditing(in: location) }
    func emptyText(for location: Location) -> String { base.emptyText(for: location) }
}
