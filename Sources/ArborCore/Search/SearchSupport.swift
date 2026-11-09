import Foundation

// MARK: - History (FE-135)

/// Recent searches, most recent first.
public struct SearchHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [String]
    public var limit: Int

    public init(entries: [String] = [], limit: Int = 20) {
        self.entries = entries
        self.limit = limit
    }

    /// With `refining` (search while typing), the newest entry is replaced when either extends the other.
    public mutating func record(_ query: String, refining: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if refining, let first = entries.first {
            let a = first.lowercased(), b = q.lowercased()
            if b.hasPrefix(a) || a.hasPrefix(b) { entries.removeFirst() }
        }
        entries.removeAll { $0.compare(q, options: .caseInsensitive) == .orderedSame }
        entries.insert(q, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func remove(_ query: String) { entries.removeAll { $0 == query } }
    public mutating func clear() { entries.removeAll() }

    /// Recent searches for an empty box, otherwise earlier searches containing the text (not the text itself).
    public func suggestions(for text: String, max: Int = 8) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return Array(entries.prefix(max)) }
        return Array(entries.filter {
            $0.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil && $0.compare(t, options: .caseInsensitive) != .orderedSame
        }.prefix(max))
    }
}

// MARK: - Saved searches (FE-138)

/// A saved `.arborsearch` file. The scope keeps path, volume UUID and bookmark, so a moved folder is
/// still found and a same-named folder on another disk isn't searched instead.
public struct SavedSearch: Codable, Equatable, Sendable {
    public static let fileExtension = "arborsearch"
    public static let formatName = "arbor.search"
    public static let currentVersion = 1
    static let maxFileBytes = 1 << 20

    public var format: String = SavedSearch.formatName
    public var version: Int = SavedSearch.currentVersion
    public var query: String
    /// nil = everywhere (This Mac).
    public var scopePath: String?
    public var scopeVolumeUUID: String?
    public var scopeBookmark: Data?
    public var recursive: Bool
    public var fileContents: Bool
    public var systemFiles: Bool
    public var zippedFiles: Bool
    public var saved: Date

    public init(request: SearchRequest, volumeUUID: String? = nil, bookmark: Data? = nil, saved: Date = Date()) {
        query = request.query
        scopePath = request.scope?.path
        scopeVolumeUUID = volumeUUID
        scopeBookmark = bookmark
        recursive = request.recursive
        fileContents = request.options.contains(.contents)
        systemFiles = request.options.contains(.systemFiles)
        zippedFiles = request.options.contains(.zipped)
        self.saved = saved
    }

    public var options: SearchOptions {
        var o: SearchOptions = []
        if fileContents { o.insert(.contents) }
        if systemFiles { o.insert(.systemFiles) }
        if zippedFiles { o.insert(.zipped) }
        return o
    }

    /// The request with the scope found at `resolvedScope` (from the bookmark) or the stored path.
    public func request(resolvedScope: URL? = nil) -> SearchRequest {
        SearchRequest(query: query, scope: resolvedScope ?? scopePath.map { URL(fileURLWithPath: $0) },
                      recursive: recursive, options: options)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public enum DecodeError: Error, LocalizedError, Equatable {
        case notASavedSearch
        case newerVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .notASavedSearch: return L10n.tr("This file isn't an Arbor saved search.")
            case .newerVersion(let v): return L10n.format("This saved search was made by a newer version of Arbor (format %@).", "\(v)")
            }
        }
    }

    public static func decode(_ data: Data) throws -> SavedSearch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let search = try? decoder.decode(SavedSearch.self, from: data), search.format == formatName else {
            throw DecodeError.notASavedSearch
        }
        guard search.version <= currentVersion else { throw DecodeError.newerVersion(search.version) }
        return search
    }

    /// A tag collection is named after its tag, any other search after its query.
    public static func suggestedFileName(for request: SearchRequest) -> String {
        suggestedFileName(for: TagCollectionQuery.title(of: request) ?? request.query)
    }

    /// Reads a saved file: never blocks on a FIFO, and takes no more than a saved search can need.
    public static func read(from url: URL) throws -> SavedSearch {
        guard let data = try FileHandle.readRegularFile(at: url, maxBytes: maxFileBytes) else { throw DecodeError.notASavedSearch }
        return try decode(data)
    }

    /// File name for the query ("report" → "report.arborsearch").
    public static func suggestedFileName(for query: String) -> String {
        let cleaned = query.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        var base = String(cleaned).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Search" }
        if base.count > 80 { base = String(base.prefix(80)) }
        return base + "." + fileExtension
    }
}

// MARK: - Identity (merge/dedupe)

/// Merge key for index and scan hits: one entry seen twice is one result; hard links stay separate (spec §3.2).
public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    /// Set only for multiply linked files: the entry's path (case- and normalization-folded).
    public let entry: String?

    public init(device: UInt64, inode: UInt64, linkCount: UInt64, isDirectory: Bool, path: String) {
        self.device = device
        self.inode = inode
        entry = (!isDirectory && linkCount > 1) ? path.precomposedStringWithCanonicalMapping.lowercased() : nil
    }

    /// Read with `lstat` (links not followed); nil if the item is gone.
    public static func of(path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino),
                            linkCount: UInt64(st.st_nlink), isDirectory: (st.st_mode & S_IFMT) == S_IFDIR, path: path)
    }
}

// MARK: - Coverage (FE-140, FE-141, FE-144)

/// What a search did and didn't cover, so the status line never overclaims.
public struct SearchCoverage: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case searching
        case finished
        /// Stopped before finishing (navigated away, typed a new query, closed).
        case stopped
        case failed(String)
    }

    public var phase: Phase = .searching
    /// Folders denied by permissions; the first few paths are kept.
    public var deniedFolders: [String] = []
    public var deniedCount = 0
    /// Folders that failed for other reasons (I/O error, vanished volume).
    public var unreadableCount = 0
    /// Mounted disks inside the scope that weren't entered.
    public var skippedVolumes: [String] = []
    /// The scope folder doesn't exist or its disk isn't connected.
    public var scopeUnavailable: String?
    /// The query needs the Spotlight index (non-text contents, authors) and it's off or unknown.
    public var indexUnavailable = false
    /// Spotlight didn't answer in time.
    public var indexTimedOut = false
    /// Searching This Mac uses the index only.
    public var indexOnly = false
    /// Files whose contents couldn't be checked directly (not plain text, too large, not downloaded).
    public var contentUnchecked = 0
    /// Contents of files Arbor can't read as text came from the index.
    public var contentFromIndex = false
    public var archivesUnreadable = 0
    public var resultLimit: Int?
    /// Change notifications were lost; results may be out of date until Refresh.
    public var mayBeStale = false

    public init() {}

    /// Reasons the results may be incomplete, most important first.
    public var gaps: [String] {
        var out: [String] = []
        if let scope = scopeUnavailable { out.append("“\(scope)” isn't available (moved, deleted or disconnected)") }
        if phase == .stopped { out.append("the search was stopped before it finished") }
        if let limit = resultLimit { out.append("only the first \(limit.formatted()) results are shown") }
        if deniedCount > 0 { out.append(deniedCount == 1 ? "1 folder couldn't be opened (access denied)" : "\(deniedCount.formatted()) folders couldn't be opened (access denied)") }
        if unreadableCount > 0 { out.append(unreadableCount == 1 ? "1 folder couldn't be read" : "\(unreadableCount.formatted()) folders couldn't be read") }
        if indexUnavailable { out.append("this location isn't indexed, so contents of documents and authors weren't searched") }
        if indexTimedOut { out.append("the Spotlight index didn't respond in time") }
        if indexOnly { out.append("only places in the Spotlight index were searched") }
        if contentUnchecked > 0, !contentFromIndex {
            out.append(contentUnchecked == 1 ? "1 file's contents couldn't be checked" : "\(contentUnchecked.formatted()) files' contents couldn't be checked")
        }
        if archivesUnreadable > 0 { out.append(archivesUnreadable == 1 ? "1 archive couldn't be read" : "\(archivesUnreadable.formatted()) archives couldn't be read") }
        if !skippedVolumes.isEmpty { out.append("other disks inside this folder weren't searched (\(skippedVolumes.joined(separator: ", ")))") }
        if mayBeStale { out.append("files changed faster than Arbor could follow; Refresh to update") }
        return out
    }

    public var isComplete: Bool { phase == .finished && gaps.isEmpty }

    /// One short phrase for the status bar: "Searching…", "Search complete", "Search incomplete: …".
    public var statusLine: String {
        switch phase {
        case .searching: return L10n.tr("Searching…")
        case .failed(let message):
            // The status bar gets the first sentence; the empty view shows the whole explanation.
            let first = message.range(of: ". ").map { String(message[..<$0.lowerBound]) + "." } ?? message
            return L10n.format("Search couldn't run: %@", "\(first)")
        case .finished, .stopped:
            let g = gaps
            if g.isEmpty { return L10n.tr("Search complete") }
            let lead = phase == .stopped ? L10n.tr("Search stopped") : L10n.tr("Search incomplete")
            let rest = g.filter { $0 != "the search was stopped before it finished" }
            guard let first = rest.first else { return lead }
            return "\(lead): \(first)" + (rest.count > 1 ? " (+\(rest.count - 1) more)" : "")
        }
    }

    /// Full explanation for the "Why might results be missing?" dialog.
    public var details: [String] {
        var lines = gaps.map { "• " + $0.prefix(1).uppercased() + $0.dropFirst() + "." }
        if !deniedFolders.isEmpty {
            lines.append("Folders that couldn't be opened:")
            lines += deniedFolders.map { "    " + $0 }
            if deniedCount > deniedFolders.count { lines.append("    …and \(deniedCount - deniedFolders.count) more") }
        }
        if contentFromIndex {
            lines.append("• Contents of documents Arbor can't read as plain text (PDF, Office, Pages…) come from the Spotlight index. Folders excluded in System Settings ▸ Spotlight aren't covered.")
        }
        if lines.isEmpty { lines.append("Every folder in the search location was searched.") }
        return lines
    }

    public mutating func addDenied(_ path: String) {
        deniedCount += 1
        if deniedFolders.count < 20 { deniedFolders.append(path) }
    }
}
