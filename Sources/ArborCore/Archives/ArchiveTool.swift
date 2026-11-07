import Foundation

/// Runs one system tool (`bsdtar`, `ditto`, `hdiutil`) with an argument array — never a shell
/// string — and can be cancelled from another thread.
public final class ToolProcess: @unchecked Sendable {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        /// The last part of stderr (bounded).
        public var stderr: String
        public var wasCancelled: Bool
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock {
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    /// Environment for libarchive tools: UTF-8 names, English month names in listings, and no
    /// AppleDouble `._` members when writing.
    public static let toolEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["COPYFILE_DISABLE"] = "1"
        return env
    }()

    /// Runs to completion. `onStderrLine` sees each stderr line as it arrives (progress).
    public func run(_ executable: String, _ arguments: [String], environment: [String: String] = ToolProcess.toolEnvironment,
                    collectStdout: Bool = true, onStderrLine: ((Substring) -> Void)? = nil) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = collectStdout ? out : FileHandle.nullDevice
        p.standardError = err

        final class Collected: @unchecked Sendable {
            var stdout = Data()
            var stderrTail = Data()
            let onLine: ((Substring) -> Void)?
            init(_ onLine: ((Substring) -> Void)?) { self.onLine = onLine }
        }
        let collected = Collected(onStderrLine)
        let group = DispatchGroup()
        if collectStdout {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                collected.stdout = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            let handle = err.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.stderrTail.append(chunk)
                if collected.stderrTail.count > 16_384 { collected.stderrTail = collected.stderrTail.suffix(8_192) }
                if let onLine = collected.onLine {
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        onLine(Substring(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)))
                        pending.removeSubrange(pending.startIndex...nl)
                    }
                }
            }
            group.leave()
        }

        try lock.withLock {
            if cancelled { throw CancellationError() }
            try p.run()
            process = p
        }
        p.waitUntilExit()
        group.wait()
        lock.withLock { process = nil }
        return Output(status: p.terminationStatus, stdout: collected.stdout,
                      stderr: String(decoding: collected.stderrTail, as: UTF8.self), wasCancelled: isCancelled)
    }
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case toolFailed(String)
    case encrypted
    case cancelled
    case nothingToExtract
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let text): return text
        case .encrypted: return "This archive is password-protected. Like Windows, Arbor can't open password-protected archives."
        case .cancelled: return "The operation was cancelled."
        case .nothingToExtract: return "There's nothing in the archive that can be extracted safely."
        case .unreadable(let text): return text
        }
    }

    /// The useful part of a tool's stderr: drops "Error exit delayed" noise and prefixes.
    public static func summarize(_ stderr: String, limit: Int = 4) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Error exit delayed") }
            .map { $0.hasPrefix("bsdtar: ") ? String($0.dropFirst(8)) : $0 }
        return lines.suffix(limit).joined(separator: "\n")
    }
}

/// Lists, extracts and creates archives with the system's libarchive (`/usr/bin/bsdtar`) and `ditto`.
public enum ArchiveTool {
    public static let bsdtar = "/usr/bin/bsdtar"
    public static let ditto = "/usr/bin/ditto"

    // MARK: Listing

    public struct Listing: Sendable {
        public var entries: [ArchiveEntry]
        /// Set when the tool reported a problem but listed something (damaged archive).
        public var warning: String?
    }

    /// Lists an archive without extracting it. ZIP uses the central directory directly (adds compressed
    /// sizes and encryption flags); everything else goes through bsdtar.
    public static func list(_ url: URL, process: ToolProcess = ToolProcess()) throws -> Listing {
        if ArchiveFormat.detect(url) == .zip, let entries = try? ZipDirectory.read(url) {
            return Listing(entries: entries, warning: nil)
        }
        return try listWithBsdtar(url, process: process)
    }

    /// bsdtar's view of the names, which is what extraction patterns must match.
    public static func listWithBsdtar(_ url: URL, process: ToolProcess = ToolProcess()) throws -> Listing {
        let output = try process.run(bsdtar, ["-t", "-v", "--numeric-owner", "-f", url.path])
        if output.wasCancelled { throw ArchiveError.cancelled }
        let parsed = BsdtarListing.parse(String(decoding: output.stdout, as: UTF8.self))
        if output.status != 0 {
            let message = ArchiveError.summarize(output.stderr)
            if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("encrypt") {
                throw ArchiveError.encrypted
            }
            if parsed.entries.isEmpty { throw ArchiveError.unreadable(message.isEmpty ? "The archive couldn't be read." : message) }
            return Listing(entries: parsed.entries, warning: message)
        }
        return Listing(entries: parsed.entries, warning: nil)
    }

    // MARK: Extraction

    /// Runs bsdtar for a plan into an empty staging folder. Ownership, file flags and ACLs are not
    /// restored (they could lock the user out); bsdtar's own refusal of `..`, absolute names and
    /// writes through symlinks stays on as a second line of defense.
    public static func extract(_ archive: URL, plan: ExtractionPlanner.Plan, into staging: URL,
                               process: ToolProcess, onEntry: (() -> Void)? = nil) throws {
        var args = ["-x", "-v", "-f", archive.path, "-C", staging.path, "--no-same-owner", "--no-fflags", "--no-acls"]
        var listFile: URL?
        if !plan.patterns.isEmpty {
            let list = staging.deletingLastPathComponent().appendingPathComponent(".arbor-patterns-\(UUID().uuidString)")
            var data = Data()
            for pattern in plan.patterns { data.append(contentsOf: Array(pattern.utf8)); data.append(0) }
            try data.write(to: list)
            listFile = list
            args += ["--null", "-T", list.path]
        }
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
        if plan.patterns.isEmpty, plan.included.isEmpty {
            // Only empty folders: nothing for bsdtar to do.
        } else {
            let output = try process.run(bsdtar, args, collectStdout: false) { line in
                if line.hasPrefix("x ") { onEntry?() }
            }
            if output.wasCancelled { throw ArchiveError.cancelled }
            if output.status != 0 {
                let message = ArchiveError.summarize(output.stderr)
                if plan.hasEncrypted || message.localizedCaseInsensitiveContains("passphrase")
                    || message.localizedCaseInsensitiveContains("encrypt") { throw ArchiveError.encrypted }
                throw ArchiveError.toolFailed(message.isEmpty ? "The archive couldn't be extracted." : message)
            }
        }
        for folder in plan.folders {
            try? FileManager.default.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    // MARK: Creation

    /// The command that writes `sources` (all in one folder) to `output`.
    /// A single item becomes a ZIP through `ditto`, which keeps Mac metadata the way Finder's Compress does
    /// (`__MACOSX`); several items, 7z and TAR go through bsdtar, named relative to their folder.
    public static func createCommand(format: ArchiveCreateFormat, sources: [URL], output: URL, listFile: URL) -> (String, [String]) {
        if format == .zip, sources.count == 1 {
            let source = sources[0]
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            // --keepParent embeds the folder's own name; for a file it would embed its parent's name.
            return (ditto, ["-c", "-k", "-V", "--sequesterRsrc"] + (isDirectory.boolValue ? ["--keepParent"] : [])
                + [source.path, output.path])
        }
        let parent = sources[0].deletingLastPathComponent().path
        return (bsdtar, ["-c", "-v", "--format", format.bsdtarFormat, "-f", output.path, "-C", parent, "--null", "-T", listFile.path])
    }

    /// Names for bsdtar's `-T` list. The only special line is "-C", so that name is written as "./-C".
    public static func createList(_ sources: [URL]) -> Data {
        var data = Data()
        for source in sources {
            let name = source.lastPathComponent == "-C" ? "./-C" : source.lastPathComponent
            data.append(contentsOf: Array(name.utf8))
            data.append(0)
        }
        return data
    }

    /// Writes an archive to `output` (which must not exist). Calls `onItem` once per file written.
    public static func create(format: ArchiveCreateFormat, sources: [URL], output: URL, process: ToolProcess,
                              onItem: (() -> Void)? = nil) throws {
        guard !sources.isEmpty else { throw ArchiveError.nothingToExtract }
        let list = output.deletingLastPathComponent().appendingPathComponent(".arbor-names-\(UUID().uuidString)")
        try createList(sources).write(to: list)
        defer { try? FileManager.default.removeItem(at: list) }
        let (tool, args) = createCommand(format: format, sources: sources, output: output, listFile: list)
        let output = try process.run(tool, args, collectStdout: false) { line in
            if line.hasPrefix("a ") || line.hasPrefix("copying file") { onItem?() }
        }
        if output.wasCancelled { throw ArchiveError.cancelled }
        if output.status != 0 {
            throw ArchiveError.toolFailed(ArchiveError.summarize(output.stderr).nilIfEmpty ?? "The archive couldn't be created.")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
