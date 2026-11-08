import Darwin
import Foundation

/// Cached kernel mount table (`getmntinfo` + `MNT_NOWAIT`, no disk access), refreshed every 2 s or on
/// invalidate, so main-thread volume-root checks avoid a `stat` that can block on network volumes. Thread-safe.
public final class MountPoints: @unchecked Sendable {
    public static let shared = MountPoints()

    private let lock = NSLock()
    private var points: Set<String> = []
    private var loadedAt: TimeInterval = -.infinity
    private let lifetime: TimeInterval = 2

    public init() {}

    public func isMountPoint(_ path: String) -> Bool {
        if path == "/" { return true }
        return current().contains(path)
    }

    /// Call when volumes mount or unmount.
    public func invalidate() { lock.withLock { loadedAt = -.infinity } }

    private func current() -> Set<String> {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if now - loadedAt < lifetime { return points }
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        var result: Set<String> = []
        if count > 0, let buffer {
            for i in 0..<Int(count) {
                var entry = buffer[i]
                let path = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                result.insert(path)
            }
        }
        points = result
        loadedAt = now
        return result
    }
}

extension FileOps {
    private static let volumeLock = NSLock()
    nonisolated(unsafe) private static var volumeIDs: [String: (id: NSObject, at: TimeInterval)] = [:]

    /// `sameVolume` cached for 5 s, since drag hover asks on every mouse move. UI hints only (copy/move
    /// cursor); transfers must use `sameVolume`.
    public static func sameVolumeCached(_ a: URL, _ b: URL) -> Bool {
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
