import Foundation

/// The single path for "move to Trash". Headless test runs (`ARBOR_HEADLESS`) never touch the
/// user's real Trash: items go to a private per-process folder instead (or `ARBOR_TEST_TRASH`).
public enum SystemTrash {
    public static let testDirectory: URL? = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ARBOR_TEST_TRASH"] { return URL(fileURLWithPath: path) }
        guard env["ARBOR_HEADLESS"] != nil else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("arbor-test-trash-\(getpid())")
    }()

    /// Moves the item to the Trash and returns where it ended up.
    @discardableResult
    public static func trash(_ url: URL) throws -> URL {
        if let dir = testDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            notify(original: url, trashed: target)
            return target
        }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        let trashed = (result as URL?) ?? url
        notify(original: url, trashed: trashed)
        return trashed
    }

    // MARK: Observers (additive hook, e.g. the Trash journal that remembers original locations)

    private static let observerLock = NSLock()
    private static var observers: [(_ original: URL, _ trashed: URL) -> Void] = []

    /// Called after every successful move to Trash, on the thread that trashed the item.
    public static func addObserver(_ observer: @escaping (_ original: URL, _ trashed: URL) -> Void) {
        observerLock.lock()
        observers.append(observer)
        observerLock.unlock()
    }

    private static func notify(original: URL, trashed: URL) {
        observerLock.lock()
        let list = observers
        observerLock.unlock()
        list.forEach { $0(original.standardizedFileURL, trashed.standardizedFileURL) }
    }
}
