import Darwin
import Foundation

/// How much care a path's volume needs before Arbor lists it unasked (FE-006).
public enum VolumeClass: Equatable, Sendable {
    case local
    case network
    /// Reading it could mount something.
    case automount
}

/// One row of the kernel's mount table.
struct MountEntry: Equatable, Sendable {
    var path: String
    var isLocal: Bool
    var fileSystemType: String
}

/// Cached kernel mount table (`getmntinfo` + `MNT_NOWAIT`, no disk access), refreshed every 2 s or on
/// invalidate, so main-thread volume checks avoid a `stat` that can block on network volumes. Thread-safe.
public final class MountPoints: @unchecked Sendable {
    /// Keyed by mount point path.
    typealias Table = [String: MountEntry]

    public static let shared = MountPoints()

    private let lock = NSLock()
    private let read: () -> Table
    private var table: Table = [:]
    private var loadedAt: TimeInterval = -.infinity
    private let lifetime: TimeInterval = 2

    public convenience init() { self.init(read: MountPoints.kernelTable) }

    init(read: @escaping () -> Table) { self.read = read }

    public func isMountPoint(_ path: String) -> Bool {
        if path == "/" { return true }
        return current()[path] != nil
    }

    /// The network mount holding `path`, or nil. Goes by the path as written: a symlink into a share reads as local.
    public func networkMount(holding path: String) -> String? {
        let table = current()
        let holder = table.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.utf8.count < $1.utf8.count }
        return holder.flatMap { table[$0]?.isLocal == false ? $0 : nil }
    }

    /// Mount table only, so it is safe on the main thread.
    public func volumeClass(containing path: String) -> VolumeClass {
        Self.classify(path, mounts: Array(current().values))
    }

    /// Call when volumes mount or unmount.
    public func invalidate() { lock.withLock { loadedAt = -.infinity } }

    /// `/home` is a symbolic link to the real autofs entry, so the mount table alone can't see these.
    private static let automountEntries = ["/home", "/net", "/network/servers"]

    static func classify(_ path: String, mounts: [MountEntry]) -> VolumeClass {
        func folded(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
        func isInside(_ candidate: String, _ root: String) -> Bool {
            root == "/" || candidate == root || candidate.hasPrefix(root + "/")
        }
        let target = folded(path)
        if automountEntries.contains(where: { isInside(target, $0) }) { return .automount }
        let owner = mounts.filter { isInside(target, folded($0.path)) }.max { $0.path.utf8.count < $1.path.utf8.count }
        guard let owner else { return .local }
        if owner.fileSystemType == "autofs" { return .automount }
        return owner.isLocal ? .local : .network
    }

    private func current() -> Table {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if now - loadedAt < lifetime { return table }
        table = read()
        loadedAt = now
        return table
    }

    static func kernelTable() -> Table {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        var result: Table = [:]
        if count > 0, let buffer {
            for i in 0..<Int(count) {
                var entry = buffer[i]
                let path = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                let type = withUnsafePointer(to: &entry.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
                }
                result[path] = MountEntry(path: path, isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0, fileSystemType: type)
            }
        }
        return result
    }
}

extension FileOps {
    private static let volumeLock = NSLock()
    nonisolated(unsafe) private static var volumeIDs: [String: (id: NSObject, at: TimeInterval)] = [:]

    /// `sameVolume` cached for 5 s, since drag hover asks on every mouse move. Network paths are answered
    /// from the mount table so a stalled server can't freeze the window. UI hints only (copy/move cursor);
    /// transfers must use `sameVolume`.
    public static func sameVolumeCached(_ a: URL, _ b: URL, mounts: MountPoints = .shared) -> Bool {
        let shareA = mounts.networkMount(holding: a.path), shareB = mounts.networkMount(holding: b.path)
        if shareA != nil || shareB != nil { return shareA == shareB }
        guard let va = volumeID(a), let vb = volumeID(b) else { return false }
        return va.isEqual(vb)
    }

    /// Call when mounts change.
    public static func forgetVolumes() { volumeLock.withLock { volumeIDs.removeAll() } }

    private static func volumeID(_ url: URL) -> NSObject? {
        let path = url.path
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = volumeLock.withLock({ volumeIDs[path] }), now - hit.at < 5 { return hit.id }
        guard let id = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        else { return nil }
        volumeLock.withLock {
            if volumeIDs.count > 512 { volumeIDs.removeAll() }
            volumeIDs[path] = (id, now)
        }
        return id
    }
}
