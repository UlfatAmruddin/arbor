import Foundation

/// Maps temporary copies of nested archives to their folder in the outer archive, so Up and the
/// breadcrumb lead back there instead of into the temporary folder.
public enum NestedArchives {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var origins: [String: Location] = [:]
    public static let limit = 256

    /// Records that `copy` came from folder `parent` of the outer archive.
    public static func register(copy: URL, parent: Location) {
        lock.lock()
        defer { lock.unlock() }
        if origins.count >= limit, let first = origins.keys.first { origins[first] = nil }
        origins[key(copy)] = parent
    }

    public static func parent(of copy: URL) -> Location? {
        lock.lock()
        defer { lock.unlock() }
        return origins[key(copy)]
    }

    public static func removeAll() {
        lock.lock()
        origins.removeAll()
        lock.unlock()
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
