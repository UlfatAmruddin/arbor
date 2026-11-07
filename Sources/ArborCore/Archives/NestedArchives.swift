import Foundation

/// Archives opened from inside another archive are browsed from a temporary copy. This remembers
/// where each copy came from, so Up and the breadcrumb lead back into the outer archive
/// ("outer.zip > inner.zip") instead of into the temporary folder.
public enum NestedArchives {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var origins: [String: Location] = [:]
    /// Bound on remembered copies (one per nested archive opened in this launch).
    public static let limit = 256

    /// Records that `copy` is a temporary copy of a member whose folder inside the outer archive is `parent`.
    public static func register(copy: URL, parent: Location) {
        lock.lock()
        defer { lock.unlock() }
        if origins.count >= limit, let first = origins.keys.first { origins[first] = nil }
        origins[key(copy)] = parent
    }

    /// The folder inside the outer archive that `copy` was opened from, if it is such a copy.
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
