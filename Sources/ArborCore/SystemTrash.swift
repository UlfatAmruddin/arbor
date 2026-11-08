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

    // MARK: Observers (e.g. the Trash journal that remembers original locations)

    /// Called after every successful move to Trash, on the thread that trashed the item. Observers are
    /// added at launch (main thread) and only read afterwards, so any thread may trash.
    public static let observers = Observers<(original: URL, trashed: URL)>(
        "SystemTrash.observers", "An item was moved to the Trash (any thread).", signature: "(original, trashed)")

    public static func addObserver(_ id: String, _ observer: @escaping (_ original: URL, _ trashed: URL) -> Void) {
        observers.observe(id) { original, trashed in observer(original, trashed) }
    }

    private static func notify(original: URL, trashed: URL) {
        observers.send((original.standardizedFileURL, trashed.standardizedFileURL))
    }
}
