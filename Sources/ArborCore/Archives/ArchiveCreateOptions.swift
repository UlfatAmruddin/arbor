import Foundation

/// Compress to ▸ Additional options (Windows 11 24H2, FE-168), written by system `bsdtar` via an argument array.
/// No Zstandard: the system libarchive lacks it and would need a separately installed `zstd`.
public enum ArchiveOutputFormat: String, Sendable, CaseIterable, Codable {
    case zip, sevenZip, tar, tarGzip, tarBzip2, tarXz
    /// One file compressed on its own (no archive around it), like Windows' gzip/BZip2/xz options.
    case gzip, bzip2, xz

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        }
    }

    public var title: String {
        switch self {
        case .zip: return L10n.tr("ZIP")
        case .sevenZip: return "7z"
        case .tar: return L10n.tr("TAR")
        case .tarGzip: return L10n.tr("TAR + gzip (.tar.gz)")
        case .tarBzip2: return L10n.tr("TAR + BZip2 (.tar.bz2)")
        case .tarXz: return L10n.tr("TAR + xz (.tar.xz)")
        case .gzip: return L10n.tr("gzip (.gz, one file)")
        case .bzip2: return L10n.tr("BZip2 (.bz2, one file)")
        case .xz: return L10n.tr("xz (.xz, one file)")
        }
    }

    /// gzip/BZip2/xz without TAR hold exactly one regular file.
    public var isSingleFile: Bool { self == .gzip || self == .bzip2 || self == .xz }

    public var methods: [CompressionMethod] {
        switch self {
        case .zip: return [.deflate, .store]
        case .sevenZip: return [.lzma2, .lzma, .bzip2, .deflate, .store]
        case .tar: return [.none]
        case .tarGzip, .gzip: return [.gzip]
        case .tarBzip2, .bzip2: return [.bzip2]
        case .tarXz, .xz: return [.xz]
        }
    }

    public var levels: [CompressionLevel] {
        switch self {
        case .tar: return []
        default: return [.fastest, .normal, .maximum]
        }
    }

    /// Formats offered for a selection (single-file formats only for one regular file).
    public static func available(forSingleFile single: Bool) -> [ArchiveOutputFormat] {
        allCases.filter { single || !$0.isSingleFile }
    }
}

public enum CompressionMethod: String, Sendable, CaseIterable, Codable {
    case deflate, store, lzma2, lzma, bzip2, gzip, xz, none

    public var title: String {
        switch self {
        case .deflate: return L10n.tr("Deflate")
        case .store: return L10n.tr("Store (no compression)")
        case .lzma2: return L10n.tr("LZMA2")
        case .lzma: return L10n.tr("LZMA")
        case .bzip2: return L10n.tr("BZip2")
        case .gzip: return "gzip"
        case .xz: return "xz"
        case .none: return L10n.tr("None")
        }
    }
}

public enum CompressionLevel: Int, Sendable, CaseIterable, Codable {
    case fastest = 1, normal = 6, maximum = 9

    public var title: String {
        switch self {
        case .fastest: return L10n.tr("Fastest")
        case .normal: return L10n.tr("Normal")
        case .maximum: return L10n.tr("Maximum")
        }
    }
}

public struct ArchiveCreateOptions: Sendable, Equatable {
    public var format: ArchiveOutputFormat
    public var method: CompressionMethod
    public var level: CompressionLevel
    /// Include dot-files inside selected folders; selected items are always included.
    public var includeHiddenItems: Bool
    /// The archive's file name, including its extension.
    public var name: String
    public var destinationFolder: URL

    public init(format: ArchiveOutputFormat = .zip, method: CompressionMethod? = nil, level: CompressionLevel = .normal,
                includeHiddenItems: Bool = true, name: String, destinationFolder: URL) {
        self.format = format
        self.method = method.flatMap { format.methods.contains($0) ? $0 : nil } ?? format.methods[0]
        self.level = level
        self.includeHiddenItems = includeHiddenItems
        self.name = name
        self.destinationFolder = destinationFolder
    }

    /// The name with this format's extension: "report.zip" → "report.tar.gz".
    public static func name(_ name: String, withExtensionFor format: ArchiveOutputFormat) -> String {
        let base = ArchiveFormat.baseName(of: name)
        let stem = base.isEmpty ? name : base
        return "\(stem).\(format.fileExtension)"
    }

    /// Checks the options for a selection; returns a readable problem or nil.
    public func problem(for sources: [URL]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return L10n.tr("Type a name for the archive.") }
        if trimmed.contains("/") || trimmed.contains(":") { return L10n.tr("A file name can't contain / or :.") }
        if sources.isEmpty { return L10n.tr("Nothing is selected.") }
        if format.isSingleFile {
            var isDirectory: ObjCBool = false
            guard sources.count == 1, FileManager.default.fileExists(atPath: sources[0].path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return L10n.format("%@ compresses one file. Choose a TAR format for folders or several items.", "\(format.title)")
            }
        }
        let parent = sources[0].deletingLastPathComponent().standardizedFileURL
        if sources.contains(where: { $0.deletingLastPathComponent().standardizedFileURL != parent }) {
            return L10n.tr("The items must be in the same folder.")
        }
        return nil
    }

    /// bsdtar arguments writing `sources` (all in one folder) to `output`, names read from `listFile`.
    public func bsdtarArguments(sources: [URL], output: URL, listFile: URL) -> [String] {
        let parent = sources[0].deletingLastPathComponent().path
        var args = ["-c", "-v"]
        var options: [String] = []
        switch format {
        case .zip:
            args += ["--format", "zip"]
            if method == .store {
                options.append("zip:compression=store")
            } else {
                options += ["zip:compression=deflate", "zip:compression-level=\(level.rawValue)"]
            }
        case .sevenZip:
            args += ["--format", "7zip"]
            let name: String
            switch method {
            case .lzma: name = "lzma1"
            case .bzip2: name = "bzip2"
            case .deflate: name = "deflate"
            case .store: name = "store"
            default: name = "lzma2"
            }
            options.append("7zip:compression=\(name)")
            if method != .store { options.append("7zip:compression-level=\(level.rawValue)") }
        case .tar:
            args += ["--format", "paxr"]
        case .tarGzip, .gzip:
            args += ["--format", format == .gzip ? "raw" : "paxr", "--gzip"]
            options.append("gzip:compression-level=\(level.rawValue)")
        case .tarBzip2, .bzip2:
            args += ["--format", format == .bzip2 ? "raw" : "paxr", "--bzip2"]
            options.append("bzip2:compression-level=\(level.rawValue)")
        case .tarXz, .xz:
            args += ["--format", format == .xz ? "raw" : "paxr", "--xz"]
            options.append("xz:compression-level=\(level.rawValue)")
        }
        if !options.isEmpty { args += ["--options", options.joined(separator: ",")] }
        // "*/.*" matches hidden names below a selected item but not the selected items themselves.
        if !includeHiddenItems { args += ["--exclude", "*/.*"] }
        args += ["-f", output.path, "-C", parent, "--null", "-T", listFile.path]
        return args
    }
}

extension ArchiveTool {
    /// Writes an archive with Additional options to `output` (which must not exist).
    public static func create(_ options: ArchiveCreateOptions, sources: [URL], output: URL, process: ToolProcess,
                              onItem: (() -> Void)? = nil) throws {
        if let problem = options.problem(for: sources) { throw ArchiveError.toolFailed(problem) }
        let list = output.deletingLastPathComponent().appendingPathComponent(".arbor-names-\(UUID().uuidString)")
        try createList(sources).write(to: list)
        defer { try? FileManager.default.removeItem(at: list) }
        let result = try process.run(bsdtar, options.bsdtarArguments(sources: sources, output: output, listFile: list),
                                     collectStdout: false) { line in
            if line.hasPrefix("a ") { onItem?() }
        }
        if result.wasCancelled { throw ArchiveError.cancelled }
        if result.status != 0 {
            try? FileManager.default.removeItem(at: output)
            throw ArchiveError.toolFailed(ArchiveError.summarize(result.stderr).nilIfEmpty ?? L10n.tr("The archive couldn't be created."))
        }
    }
}
