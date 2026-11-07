import Darwin
import Foundation

/// Mount points from the kernel's table (`getmntinfo` with `MNT_NOWAIT`: no disk or network access),
/// refreshed at most every two seconds or when the app is told volumes changed. Lets "is this folder a
/// volume root?" run on the main thread for every tab title, icon and Up button without a `stat` per
/// call, which can block on a slow network volume. Thread-safe.
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

    /// Volumes were mounted or unmounted.
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

    /// `sameVolume` with each item's volume remembered for a few seconds: drag-and-drop asks on every
    /// mouse move while hovering, and each answer was a metadata read on the main thread. For decisions
    /// shown to the user only (copy versus move cursor); transfers use `sameVolume`.
    public static func sameVolumeCached(_ a: URL, _ b: URL) -> Bool {
        guard let va = volumeID(a), let vb = volumeID(b) else { return false }
        return va.isEqual(vb)
    }

    /// Forgets remembered volumes (mounts changed).
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
