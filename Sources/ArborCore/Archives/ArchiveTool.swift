import Foundation

/// Runs one system tool (`bsdtar`, `ditto`, `hdiutil`) with an argument array, never a shell string; cancellable.
public final class ToolProcess: @unchecked Sendable {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        /// The last part of stderr (bounded).
        public var stderr: String
        public var wasCancelled: Bool
        /// stdout passed `stdoutLimit`; the tool was stopped and `stdout` is incomplete.
        public var stdoutOverflowed: Bool
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

    /// Runs to completion. `onStderrLine` sees each stderr line as it arrives (progress); past `stdoutLimit` it stops the tool.
    public func run(_ executable: String, _ arguments: [String], environment: [String: String] = ToolProcess.toolEnvironment,
                    collectStdout: Bool = true, stdoutLimit: Int? = nil, onStderrLine: ((Substring) -> Void)? = nil) throws -> Output {
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
            var stdoutOverflowed = false
            var stderrTail = Data()
            let onLine: ((Substring) -> Void)?
            init(_ onLine: ((Substring) -> Void)?) { self.onLine = onLine }
        }
        let collected = Collected(onStderrLine)
        let group = DispatchGroup()
        // Drain pipes on dedicated threads: callers block pool threads here, so with several tools running
        // pool-scheduled readers could starve and every run would wait forever.
        func reader(_ body: @escaping @Sendable () -> Void) {
            let thread = Thread(block: body)
            thread.qualityOfService = .utility
            thread.start()
        }
        if collectStdout {
            group.enter()
            reader {
                let handle = out.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if let stdoutLimit, collected.stdout.count + chunk.count > stdoutLimit {
                        // Keep draining (and discarding) so the tool never blocks on a full pipe.
                        if !collected.stdoutOverflowed { collected.stdoutOverflowed = true; self.terminate() }
                        continue
                    }
                    collected.stdout.append(chunk)
                }
                group.leave()
            }
        }
        group.enter()
        reader {
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
                      stderr: String(decoding: collected.stderrTail, as: UTF8.self), wasCancelled: isCancelled,
                      stdoutOverflowed: collected.stdoutOverflowed)
    }

    /// Stops the running tool without marking the run cancelled.
    private func terminate() {
        lock.withLock { if let p = process, p.isRunning { p.terminate() } }
    }
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case toolFailed(String)
    case encrypted
    case cancelled
    case nothingToExtract
    case unreadable(String)
    case tooManyEntries

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let text): return text
        case .encrypted: return L10n.tr("This archive is password-protected. Like Windows, Arbor can't open password-protected archives.")
        case .cancelled: return L10n.tr("The operation was cancelled.")
        case .nothingToExtract: return L10n.tr("There's nothing in the archive that can be extracted safely.")
        case .unreadable(let text): return text
        case .tooManyEntries: return L10n.tr("The archive lists more items than Arbor can show.")
        }
    }

    /// The useful part of a tool's stderr: drops "Error exit delayed" noise and prefixes.
    public static func summarize(_ stderr: String, limit: Int = 4) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Error exit delayed") }
            .map { $0.hasPrefix("bsdtar: ") ? String($0.dropFirst(8)) : $0 }
            // -v progress ("x name") isn't an error; keep only progress lines with one ("x name: failed").
            .compactMap { line -> String? in
                guard line.hasPrefix("x ") || line.hasPrefix("a ") else { return line }
                return line.contains(": ") ? String(line.dropFirst(2)) : nil
            }
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

    /// Upper bound on bsdtar listing output, so a hostile archive can't exhaust memory.
    public static let listingByteLimit = 256 << 20
    /// Upper bound on distinct paths (entries and implied folders) in a listing.
    public static let maxPaths = 2 * ZipDirectory.maxEntries

    /// Lists without extracting: ZIP via the central directory (compressed sizes, encryption), else bsdtar.
    public static func list(_ url: URL, process: ToolProcess = ToolProcess()) throws -> Listing {
        if ArchiveFormat.detect(url) == .zip {
            do {
                let entries = try ZipDirectory.read(url)
                try checkBounds(entries)
                return Listing(entries: entries, warning: nil)
            } catch ZipDirectory.ReadError.tooManyEntries, ArchiveError.tooManyEntries {
                throw ArchiveError.tooManyEntries
            } catch {
                // A damaged directory: bsdtar may still read the local headers.
            }
        }
        return try listWithBsdtar(url, process: process)
    }

    /// Throws `tooManyEntries` when a listing has more entries, or implies more folders, than Arbor can index.
    static func checkBounds(_ entries: [ArchiveEntry], maxEntries: Int = ZipDirectory.maxEntries, maxPaths: Int = maxPaths) throws {
        guard entries.count <= maxEntries else { throw ArchiveError.tooManyEntries }
        var tree = PathTree()
        for entry in entries {
            guard let parts = entry.components else { continue }
            tree.insert(parts)
            if tree.nodeCount > maxPaths { throw ArchiveError.tooManyEntries }
        }
    }

    /// bsdtar's view of the names, which is what extraction patterns must match.
    public static func listWithBsdtar(_ url: URL, process: ToolProcess = ToolProcess()) throws -> Listing {
        let rar = ArchiveFormat.detect(url) == .rar ? RarHeaders.traits(of: url) : RarHeaders.Traits()
        if let refusal = rar.refusal { throw ArchiveError.unreadable(refusal) }
        let output = try process.run(bsdtar, ["-t", "-v", "--numeric-owner", "-f", url.path], stdoutLimit: listingByteLimit)
        var result = try listing(from: output, unmarkedLinksExcept: rar.hasHardLinks ? rar.regularNamesLikeHardLinks : nil)
        try rar.apply(to: &result)
        return result
    }

    /// Turns bsdtar's output into a listing, enforcing the size and entry bounds.
    static func listing(from output: ToolProcess.Output, maxLines: Int = ZipDirectory.maxEntries, maxPaths: Int = maxPaths,
                        unmarkedLinksExcept: Set<String>? = nil) throws -> Listing {
        if output.wasCancelled { throw ArchiveError.cancelled }
        if output.stdoutOverflowed { throw ArchiveError.tooManyEntries }
        var parsed = BsdtarListing.parse(String(decoding: output.stdout, as: UTF8.self), maxLines: maxLines, unmarkedLinksExcept: unmarkedLinksExcept)
        if parsed.exceededLimit { throw ArchiveError.tooManyEntries }
        let nothingReadable = parsed.entries.isEmpty
        // A row that can't be read still exists: an unsafe stand-in keeps it out of whole-folder extraction.
        parsed.entries += Array(repeating: ArchiveEntry(rawPath: "", kind: .special), count: parsed.malformedLines)
        try checkBounds(parsed.entries, maxPaths: maxPaths)
        if output.status != 0 {
            let message = ArchiveError.summarize(output.stderr)
            if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("encrypt") {
                throw ArchiveError.encrypted
            }
            if nothingReadable { throw ArchiveError.unreadable(message.isEmpty ? L10n.tr("The archive couldn't be read.") : message) }
            return Listing(entries: parsed.entries, warning: message)
        }
        return Listing(entries: parsed.entries, warning: nil)
    }

    /// Names for extraction plans: bsdtar's, renamed for Windows ZIPs (`ZipNames`), and whether "\" must be rewritten.
    public static func extractionListing(_ url: URL, process: ToolProcess = ToolProcess()) throws -> (listing: Listing, rewritesBackslashes: Bool) {
        var listing = try listWithBsdtar(url, process: process)
        let format = ArchiveFormat.detect(url)
        // RAR reading can stop quietly at damage, which would write only part of the archive.
        if format == .rar, let warning = listing.warning { throw ArchiveError.toolFailed(warning) }
        guard format == .zip, (try? ZipDirectory.usesWindowsSeparators(url)) == true else { return (listing, false) }
        listing.entries = ZipNames.rewritten(listing.entries)
        return (listing, true)
    }

    // MARK: Extraction

    /// Runs bsdtar for a plan into an empty staging folder. Ownership, flags and ACLs aren't restored (lockout risk);
    /// bsdtar's own `..`, absolute-name and symlink checks stay on as a second line of defense.
    public static func extract(_ archive: URL, plan: ExtractionPlanner.Plan, into staging: URL,
                               process: ToolProcess, rewritesBackslashes: Bool = false, onEntry: (() -> Void)? = nil) throws {
        var args = ["-x", "-v", "-f", archive.path, "-C", staging.path, "--no-same-owner", "--no-fflags", "--no-acls"]
        if rewritesBackslashes { args += ZipNames.bsdtarRewrite }
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
                throw ArchiveError.toolFailed(message.isEmpty ? L10n.tr("The archive couldn't be extracted.") : message)
            }
        }
        for folder in plan.folders {
            try? FileManager.default.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    // MARK: Creation

    /// The command writing `sources` (one folder) to `output`. A single item becomes a ZIP via `ditto`, keeping Mac
    /// metadata like Finder (`__MACOSX`); otherwise bsdtar, with names relative to the folder.
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
            throw ArchiveError.toolFailed(ArchiveError.summarize(output.stderr).nilIfEmpty ?? L10n.tr("The archive couldn't be created."))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
