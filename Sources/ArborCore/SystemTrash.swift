import Foundation

/// Why an item couldn't go to the Trash, and whether deleting it outright could still work.
public struct TrashFailure: Equatable, Sendable {
    public let reason: String
    public let canDeletePermanently: Bool
}

/// The single path for "move to Trash". Headless runs (`ARBOR_HEADLESS`) never touch the real Trash:
/// items go to a per-process folder (or `ARBOR_TEST_TRASH`).
public enum SystemTrash {
    public static let testDirectory: URL? = {
        let env = Automation.environment
        if let path = env["ARBOR_TEST_TRASH"] { return URL(fileURLWithPath: path) }
        guard env["ARBOR_HEADLESS"] != nil else { return nil }
        return TemporaryFiles.headlessFolder("trash")
    }()

    /// Returns where the item ended up.
    @discardableResult
    public static func trash(_ url: URL) throws -> URL {
        let trashed = try trash(url, into: testDirectory)
        notify(original: url, trashed: trashed)
        return trashed
    }

    /// For an item staged elsewhere: the Trash journal records where it really came from.
    @discardableResult
    public static func trash(_ url: URL, recordedAs original: URL) throws -> URL {
        let trashed = try trash(url, into: testDirectory)
        notify(original: original, trashed: trashed)
        return trashed
    }

    /// `directory`: a private stand-in for the Trash, or nil for the real one; like the Trash, it keeps the name when free.
    @discardableResult
    static func trash(_ url: URL, into directory: URL?) throws -> URL {
        if let dir = directory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var target = dir.appendingPathComponent(url.lastPathComponent)
            if FileOps.exists(target) { target = dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)") }
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    /// Why `url` couldn't go to the Trash, in the user's words. The Trash reports a path past the limit as a missing file.
    public static func failure(_ error: Error, for url: URL) -> TrashFailure {
        let tooLong = TrashFailure(reason: L10n.tr("The path to this item is too long for the Trash."), canDeletePermanently: true)
        guard PathLimits.fits(url) else { return tooLong }
        if TransferFailure.hasLockFlag(url) {
            return TrashFailure(reason: L10n.tr("The item is locked. Unlock it in Get Info, then try again."), canDeletePermanently: false)
        }
        switch FileOps.posixCode(of: error) {
        case EACCES?, EPERM?:
            return TrashFailure(reason: L10n.tr("You don't have permission to remove this item from its folder."), canDeletePermanently: true)
        case EROFS?:
            return TrashFailure(reason: L10n.tr("This disk is read-only, so nothing on it can be removed."), canDeletePermanently: false)
        case ENAMETOOLONG?:
            return tooLong
        case ENOENT? where !FileOps.exists(url):
            return TrashFailure(reason: L10n.tr("The item no longer exists."), canDeletePermanently: false)
        default:
            return TrashFailure(reason: L10n.tr("This location may not support the Trash. You can delete permanently instead, which can't be undone."),
                                canDeletePermanently: true)
        }
    }

    /// Only a real, user-owned `.Trash` or `.Trashes/<uid>` (no links on the way) may be emptied.
    public static func isRealTrashFolder(_ folder: URL, uid: uid_t = getuid()) -> Bool {
        guard let (base, chain) = trashChain(folder, uid: uid) else { return false }
        var current = base
        for component in chain {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            if component == chain.last, info.st_uid != uid { return false }
        }
        return true
    }

    /// The folder holding the Trash parts, and those parts: `.Trash` or `.Trashes`, `<uid>`.
    private static func trashChain(_ folder: URL, uid: uid_t) -> (URL, [String])? {
        let folder = folder.standardizedFileURL
        let parent = folder.deletingLastPathComponent()
        if folder.lastPathComponent == ".Trash" { return (parent, [".Trash"]) }
        if folder.lastPathComponent == String(uid), parent.lastPathComponent == ".Trashes" {
            return (parent.deletingLastPathComponent(), [".Trashes", folder.lastPathComponent])
        }
        return nil
    }

    /// Deletes an item directly in a real Trash `folder` (or a `trusted` one) via no-follow descriptors; 0, an errno, or nil if refused.
    public static func removePermanently(_ item: URL, inTrash folder: URL, trusted: Bool = false, uid: uid_t = getuid()) -> Int32? {
        let item = item.standardizedFileURL
        guard item.deletingLastPathComponent().path == folder.standardizedFileURL.path else { return nil }
        var trash: Int32
        if trusted {
            trash = open(folder.path, O_SEARCH | O_CLOEXEC)
        } else {
            guard let (base, chain) = trashChain(folder, uid: uid) else { return nil }
            trash = open(base.path, O_SEARCH | O_CLOEXEC)
            for component in chain where trash >= 0 {
                let next = openat(trash, component, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                let error = errno
                close(trash)
                guard next >= 0 else { return error == ELOOP || error == ENOTDIR ? nil : error }
                trash = next
            }
            var info = stat()
            if trash >= 0, fstat(trash, &info) != 0 || info.st_uid != uid { close(trash); return nil }
        }
        guard trash >= 0 else { return errno }
        defer { close(trash) }
        return FileOps.removeTree(item.lastPathComponent, in: trash)
    }

    // MARK: Observers (e.g. the Trash journal that remembers original locations)

    /// Called on the trashing thread after each move. Added at launch only, so any thread may trash.
    public static let observers = Observers<(original: URL, trashed: URL)>(
        "SystemTrash.observers", "An item was moved to the Trash (any thread).", signature: "(original, trashed)")

    public static func addObserver(_ id: String, _ observer: @escaping (_ original: URL, _ trashed: URL) -> Void) {
        observers.observe(id) { original, trashed in observer(original, trashed) }
    }

    private static func notify(original: URL, trashed: URL) {
        observers.send((original.standardizedFileURL, trashed.standardizedFileURL))
    }
}
