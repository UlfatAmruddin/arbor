import Foundation

/// Arbor's temporary files and their cleanup.
/// - Headless runs (`ARBOR_HEADLESS`) keep journal, history and Trash in `arbor-headless-<pid>`, removed at exit;
///   leftovers from crashed or killed runs are removed next launch (`sweepLeftovers`).
/// - Opened version copies are read-only files in "Arbor Versions", removed when the app showing them quits;
///   any left are removed a day later, or by the system's temp cleanup if Arbor isn't opened again.
/// - "Arbor Archives" is cleaned per launch by `ArchiveJobs`.
public enum TemporaryFiles {
    public static let headlessPrefix = "arbor-headless-"
    /// Older per-process prefixes (and fake network shares); swept the same way.
    static let perProcessPrefixes = [headlessPrefix, "arbor-test-journal-", "arbor-test-history-",
                                     "arbor-test-trash-", "arbor-fake-network-"]
    public static let versionCopyLifetime: TimeInterval = 24 * 60 * 60

    public static var directory: URL { FileManager.default.temporaryDirectory }

    /// Created on first use, removed at exit.
    public static let headlessRoot: URL = {
        let url = directory.appendingPathComponent("\(headlessPrefix)\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        TemporaryFilesExit.path = url.path
        atexit {
            if let path = TemporaryFilesExit.path { TemporaryFiles.removeTree(URL(fileURLWithPath: path)) }
        }
        return url
    }()

    /// A subfolder ("journal", "history", "trash").
    public static func headlessFolder(_ name: String) -> URL {
        headlessRoot.appendingPathComponent(name, isDirectory: true)
    }

    public static var versionsFolder: URL { directory.appendingPathComponent("Arbor Versions", isDirectory: true) }

    /// True if the process exists, even when another user owns it.
    public static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes per-process folders (and files named after them) of dead processes, and version copies older
    /// than `versionCopyLifetime`. Returns the names removed. Call off the main thread.
    @discardableResult
    public static func sweepLeftovers(in directory: URL = TemporaryFiles.directory,
                                      now: Date = Date(),
                                      isRunning: (pid_t) -> Bool = TemporaryFiles.isRunning) -> [String] {
        var removed: [String] = []
        let fm = FileManager.default
        let me = getpid()
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard let pid = ownerPID(of: name), pid != me, !isRunning(pid) else { continue }
            removeTree(directory.appendingPathComponent(name))
            removed.append(name)
        }
        let versions = directory.appendingPathComponent("Arbor Versions", isDirectory: true)
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        for entry in (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: Array(keys))) ?? [] {
            let values = try? entry.resourceValues(forKeys: keys)
            guard let date = values?.creationDate ?? values?.contentModificationDate,
                  now.timeIntervalSince(date) > versionCopyLifetime else { continue }
            removeTree(entry)
            removed.append("Arbor Versions/" + entry.lastPathComponent)
        }
        return removed
    }

    /// Makes an opened version copy read-only; not locked, since the system's temp cleanup can't remove locked files.
    public static func makeVersionCopyReadOnly(_ copy: URL) throws {
        let fm = FileManager.default
        var items = [copy]
        if let walker = fm.enumerator(at: copy, includingPropertiesForKeys: nil) {
            for case let item as URL in walker { items.append(item) }
        }
        for item in items where (try? fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType) == .typeRegular {
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: item.path)
        }
    }

    /// The pid in a per-process name ("arbor-headless-123").
    static func ownerPID(of name: String) -> pid_t? {
        guard let prefix = perProcessPrefixes.first(where: { name.hasPrefix($0) }) else { return nil }
        let digits = name.dropFirst(prefix.count).prefix(while: \.isNumber)
        guard !digits.isEmpty, let pid = pid_t(digits) else { return nil }
        return pid
    }

    /// Deletes a file or folder, unlocking locked items if that's what blocked it.
    public static func removeTree(_ url: URL) {
        let fm = FileManager.default
        if (try? fm.removeItem(at: url)) != nil { return }
        var items = [url]
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in walker { items.append(item) }
        }
        for item in items {
            var values = URLResourceValues()
            values.isUserImmutable = false
            var target = item
            try? target.setResourceValues(values)
            // Read-only folders can't have their contents removed.
            if let attributes = try? fm.attributesOfItem(atPath: item.path),
               (attributes[.type] as? FileAttributeType) == .typeDirectory {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
            }
        }
        try? fm.removeItem(at: url)
    }
}

/// The headless folder's path for the exit handler (a C function pointer can't capture).
enum TemporaryFilesExit {
    nonisolated(unsafe) static var path: String?
}
