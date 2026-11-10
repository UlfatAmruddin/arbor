import Foundation

/// Previous Versions tab sources (FE-155): `NSFileVersion` (Auto Save versions, restorable per file)
/// and Time Machine status via `tmutil`. Arbor never invents backup entries.
public struct DocumentVersion: Equatable, Sendable {
    public var date: Date?
    public var name: String
    public var savingComputer: String?
    public var url: URL
}

public enum DocumentVersions {
    /// Newest first.
    public static func list(_ url: URL) -> [DocumentVersion] {
        (NSFileVersion.otherVersionsOfItem(at: url) ?? [])
            .map { DocumentVersion(date: $0.modificationDate, name: $0.localizedName ?? url.lastPathComponent,
                                   savingComputer: $0.localizedNameOfSavingComputer, url: $0.url) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// "Restore To…"; never overwrites.
    public static func restore(_ version: DocumentVersion, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try FileManager.default.copyItem(at: version.url, to: destination)
    }

    /// Saves the current contents as a version first, so the restore is undoable.
    public static func restoreInPlace(_ version: DocumentVersion, of url: URL) throws {
        guard let match = (NSFileVersion.otherVersionsOfItem(at: url) ?? []).first(where: { $0.url == version.url }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try NSFileVersion.addOfItem(at: url, withContentsOf: url, options: [])
        try match.replaceItem(at: url, options: [])
    }
}

/// Parsing is separate from running so it can be tested.
public struct TimeMachineStatus: Equatable, Sendable {
    public struct Destination: Equatable, Sendable {
        public var name: String
        public var kind: String
        public var mountPoint: String?
    }

    public var destinations: [Destination]
    public var localSnapshotDates: [Date]
    /// False when `tmutil` is missing or blocked.
    public var available: Bool

    public var isConfigured: Bool { !destinations.isEmpty }

    public init(destinations: [Destination] = [], localSnapshotDates: [Date] = [], available: Bool = true) {
        self.destinations = destinations
        self.localSnapshotDates = localSnapshotDates
        self.available = available
    }

    /// `tmutil destinationinfo -X` plist.
    public static func parseDestinations(_ data: Data) -> [Destination] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let list = plist["Destinations"] as? [[String: Any]] else { return [] }
        return list.map {
            Destination(name: $0["Name"] as? String ?? L10n.tr("Backup disk"), kind: $0["Kind"] as? String ?? "",
                        mountPoint: $0["MountPoint"] as? String)
        }
    }

    /// `tmutil listlocalsnapshotdates` lines like `2026-11-07-101530`.
    public static func parseSnapshotDates(_ text: String) -> [Date] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return text.split(whereSeparator: \.isNewline)
            .compactMap { f.date(from: $0.trimmingCharacters(in: .whitespaces)) }
            .sorted(by: >)
    }

    /// Read-only `tmutil` verbs with a timeout. Call off the main thread.
    public static func read(volume: URL, timeout: TimeInterval = 5) -> TimeMachineStatus {
        let tool = URL(fileURLWithPath: "/usr/bin/tmutil")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return TimeMachineStatus(available: false) }
        let info = run(tool, ["destinationinfo", "-X"], timeout: timeout)
        let dates = run(tool, ["listlocalsnapshotdates", volume.path], timeout: timeout)
        guard info != nil || dates != nil else { return TimeMachineStatus(available: false) }
        return TimeMachineStatus(destinations: info.map(parseDestinations) ?? [],
                                 localSnapshotDates: dates.map { parseSnapshotDates(String(decoding: $0, as: UTF8.self)) } ?? [])
    }

    /// nil when unknown.
    public static func isExcluded(_ url: URL, timeout: TimeInterval = 5) -> Bool? {
        guard let out = run(URL(fileURLWithPath: "/usr/bin/tmutil"), ["isexcluded", url.path], timeout: timeout) else { return nil }
        let text = String(decoding: out, as: UTF8.self)
        if text.contains("[Excluded]") { return true }
        if text.contains("[Included]") { return false }
        return nil
    }

    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
