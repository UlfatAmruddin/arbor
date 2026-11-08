import Foundation

/// Arbor's files in the temporary folder, and their cleanup.
///
/// - Headless runs (`ARBOR_HEADLESS`, used by the scripted checks) keep the journal, history and Trash
///   that a normal launch keeps in ~/Library in one folder per process, `arbor-headless-<pid>`. It is
///   removed when the process exits; folders left by runs that crashed or were killed are removed at
///   the next launch (`sweepLeftovers`).
/// - Copies of Time Machine versions opened from Properties are locked, read-only files in
///   "Arbor Versions". They stay while an app may still have them open and are removed a day later.
/// - "Arbor Archives" (items opened from inside an archive) cleans itself per launch (`ArchiveJobs`).
public enum TemporaryFiles {
    /// Per-process folder for headless runs.
    public static let headlessPrefix = "arbor-headless-"
    /// Per-process names used by earlier versions (and by the fake network shares); swept the same way.
    static let perProcessPrefixes = [headlessPrefix, "arbor-test-journal-", "arbor-test-history-",
                                     "arbor-test-trash-", "arbor-fake-network-"]
    /// How long an opened version copy is kept.
    public static let versionCopyLifetime: TimeInterval = 24 * 60 * 60

    public static var directory: URL { FileManager.default.temporaryDirectory }

    /// This process's headless folder, created on first use and removed at exit.
    public static let headlessRoot: URL = {
        let url = directory.appendingPathComponent("\(headlessPrefix)\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        TemporaryFilesExit.path = url.path
        atexit {
            if let path = TemporaryFilesExit.path { TemporaryFiles.removeTree(URL(fileURLWithPath: path)) }
        }
        return url
    }()

    /// A subfolder of the headless folder ("journal", "history", "trash").
    public static func headlessFolder(_ name: String) -> URL {
        headlessRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Where opened Time Machine version copies go.
    public static var versionsFolder: URL { directory.appendingPathComponent("Arbor Versions", isDirectory: true) }

    /// True when a process with this id exists (including one owned by another user).
    public static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes what earlier runs left behind: per-process folders (and files named after them, such as
    /// `arbor-test-trash-<pid>.arbor-journal.json`) of processes that no longer run, and version copies
    /// older than `versionCopyLifetime`. Returns the names removed. Cheap; call off the main thread.
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

    /// The process id in a per-process name ("arbor-headless-123", "arbor-test-trash-123.arbor-journal.json").
    static func ownerPID(of name: String) -> pid_t? {
        guard let prefix = perProcessPrefixes.first(where: { name.hasPrefix($0) }) else { return nil }
        let digits = name.dropFirst(prefix.count).prefix(while: \.isNumber)
        guard !digits.isEmpty, let pid = pid_t(digits) else { return nil }
        return pid
    }

    /// Deletes a file or folder, unlocking locked items first when that is what stopped it.
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
