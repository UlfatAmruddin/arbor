import Foundation

/// An item's copy in a Time Machine backup (FE-155). Without Full Disk Access tmutil says "Operation
/// not permitted", reported as such, never as "no versions". Local snapshots need root, so are only counted.
public struct BackupVersion: Equatable, Sendable {
    /// Backup time.
    public var date: Date
    /// Read-only.
    public var url: URL
    public var modified: Date?
    public var size: Int64?
    public var isFolder: Bool
}

public enum TimeMachineBackups {
    public enum Listing: Equatable, Sendable {
        case backups([URL])
        case notConfigured
        case needsFullDiskAccess
        /// Disk not connected or tmutil failed.
        case unavailable(String)
    }

    public static func parseList(_ text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0) }
    }

    /// From "2026-11-07-101530[.backup]".
    public static func date(ofBackup url: URL) -> Date? {
        var name = url.lastPathComponent
        if name.hasSuffix(".backup") { name = String(name.dropLast(7)) }
        if name.hasSuffix(".previous") || name.hasSuffix(".inprogress") { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: name)
    }

    public static func classify(stdout: String, stderr: String, status: Int32, configured: Bool) -> Listing {
        let backups = parseList(stdout)
        if status == 0, !backups.isEmpty { return .backups(backups) }
        let all = (stdout + "\n" + stderr).lowercased()
        if all.contains("full disk access") || all.contains("operation not permitted") {
            return configured ? .needsFullDiskAccess : .notConfigured
        }
        if !configured { return .notConfigured }
        if status == 0 { return .backups([]) }
        let message = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .unavailable(message.isEmpty ? "Time Machine backups couldn't be listed." : message)
    }

    /// Bounded by `timeout`. Call off the main thread.
    public static func list(configured: Bool, timeout: TimeInterval = 10) -> Listing {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listbackups"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .unavailable("tmutil couldn't be started.") }
        final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return .unavailable("Time Machine didn't answer in time. Is the backup disk connected?")
        }
        p.waitUntilExit()
        return classify(stdout: String(decoding: box.out, as: UTF8.self), stderr: String(decoding: box.err, as: UTF8.self),
                        status: p.terminationStatus, configured: configured)
    }

    /// Candidate paths inside a backed-up volume; startup-disk items may be under their Data-volume path.
    public static func relativePaths(of item: URL, volumeRoot: URL) -> [String] {
        let path = item.standardizedFileURL.path
        var root = volumeRoot.standardizedFileURL.path
        if !root.hasSuffix("/") { root += "/" }
        var results: [String] = []
        if path.hasPrefix(root) { results.append(String(path.dropFirst(root.count))) }
        let data = "/System/Volumes/Data/"
        if path.hasPrefix(data) { results.append(String(path.dropFirst(data.count))) }
        if root == "/", !path.hasPrefix(data) { results.append(String(path.dropFirst())) }
        var seen = Set<String>()
        return results.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Newest first; consecutive unchanged copies (same size and date) are listed once.
    public static func versions(of item: URL, volumeRoot: URL, in backups: [URL], limit: Int = 200,
                                fileManager: FileManager = .default) -> [BackupVersion] {
        let relatives = relativePaths(of: item, volumeRoot: volumeRoot)
        guard !relatives.isEmpty else { return [] }
        var found: [BackupVersion] = []
        let dated = backups.compactMap { b in date(ofBackup: b).map { (b, $0) } }.sorted { $0.1 > $1.1 }
        for (backup, date) in dated {
            let volumes = ((try? fileManager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
            var hit: URL?
            outer: for volume in volumes {
                for relative in relatives {
                    let candidate = volume.appendingPathComponent(relative)
                    if fileManager.fileExists(atPath: candidate.path) { hit = candidate; break outer }
                }
            }
            guard let hit else { continue }
            let values = try? hit.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
            let version = BackupVersion(date: date, url: hit, modified: values?.contentModificationDate,
                                        size: values?.fileSize.map(Int64.init), isFolder: values?.isDirectory ?? false)
            if let last = found.last, !version.isFolder, last.modified == version.modified, last.size == version.size {
                continue   // unchanged
            }
            found.append(version)
            if found.count >= limit { break }
        }
        return found
    }

    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
