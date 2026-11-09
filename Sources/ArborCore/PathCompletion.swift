import Foundation

/// Address-bar text split for completion (FE-006); lexical only, because it runs on the main thread on every keystroke.
public struct PathCompletionQuery: Equatable, Sendable {
    public let text: String
    /// Through the last "/", exactly as typed, so `~/Doc` offers `~/Documents/` and keeps the user's form.
    public let literalPrefix: String
    public let folder: URL
    public let typedName: String
    fileprivate let base: URL?
    fileprivate let homeDirectory: URL

    static let maximumBytes = 1_024

    /// nil means no completion: only plain local path forms are ever listed.
    public static func parse(_ text: String, base: URL?, homeDirectory: URL) -> PathCompletionQuery? {
        guard isLocalPathForm(text), PathResolver.localPath(text, home: homeDirectory, base: base) != nil else { return nil }
        let nameStart = text.lastIndex(of: "/").map(text.index(after:)) ?? text.startIndex
        let literalPrefix = String(text[..<nameStart])
        guard let folderPath = PathResolver.localPath(literalPrefix, home: homeDirectory, base: base) else { return nil }
        return PathCompletionQuery(text: text, literalPrefix: literalPrefix,
                                   folder: URL(fileURLWithPath: lexicallyNormalized(folderPath), isDirectory: true),
                                   typedName: String(text[nameStart...]), base: base, homeDirectory: homeDirectory)
    }

    private static func isLocalPathForm(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, text.utf8.count <= maximumBytes, text != "~",
              !CharacterSet.whitespacesAndNewlines.contains(first), first != "\"", first != "'",
              !text.unicodeScalars.contains(where: PathCompletion.isControl),
              !text.hasPrefix("//"), !text.hasPrefix("\\\\") else { return false }
        return PathResolver.scheme(of: text) == nil && !PathResolver.isWindowsDrivePath(text) && !ShellAddress.hasPrefix(text)
    }

    /// Same result as `standardizedFileURL` for `.` and `..`, without its disk check.
    private static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    fileprivate var namedPath: String { Self.path(of: typedName, in: folder) }

    fileprivate static func path(of name: String, in folder: URL) -> String {
        guard !name.isEmpty else { return folder.path }
        return folder.path == "/" ? "/" + name : folder.path + "/" + name
    }
}

/// One name from a folder listing.
public struct PathCompletionEntry: Equatable, Sendable {
    public var name: String
    /// False for a symbolic link, even one to a folder: its target is never read.
    public var isFolder: Bool
    public var isHidden: Bool

    public init(name: String, isFolder: Bool, isHidden: Bool) {
        self.name = name
        self.isFolder = isFolder
        self.isHidden = isHidden
    }

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
        self.init(name: url.lastPathComponent,
                  isFolder: values?.isDirectory == true && values?.isSymbolicLink != true,
                  isHidden: values?.isHidden == true)
    }

    static func displayOrder(_ a: PathCompletionEntry, _ b: PathCompletionEntry) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// A row the user can pick.
public struct PathCompletionCandidate: Equatable, Sendable {
    /// The whole address text the pick puts in the field.
    public let text: String
    public let name: String
    public let isFolder: Bool
}

/// What a list leaves out; each case needs different advice.
public enum PathCompletionNotice: Equatable, Sendable {
    /// Typing more can still bring up the rest.
    case moreMatches
    /// Names the scan never reached can't appear, however much is typed.
    case partialListing
}

public enum PathCompletion {
    public static let rowLimit = 12
    /// Each rejected name costs a full round trip on the main thread, and a hostile folder can hold thousands.
    static let rejectedLimit = 256

    public static func candidates(in entries: [PathCompletionEntry], for query: PathCompletionQuery, includeHidden: Bool,
                                  limit: Int = rowLimit) -> (rows: [PathCompletionCandidate], hasMore: Bool) {
        let showsHidden = includeHidden || query.typedName.hasPrefix(".")
        var rows: [PathCompletionCandidate] = []
        var hasMore = false
        var rejected = 0
        for entry in entries where (showsHidden || !entry.isHidden) && matches(entry.name, query.typedName) {
            guard let row = candidate(for: entry, query: query) else {
                rejected += 1
                if rejected == rejectedLimit {
                    hasMore = true
                    break
                }
                continue
            }
            if rows.count == limit {
                hasMore = true
                break
            }
            rows.append(row)
        }
        if rows.count == 1, rows[0].text == query.text { rows = [] }
        return (rows, hasMore)
    }

    /// A partial listing wins: its rows may be missing for good, which typing can't fix.
    public static func notice(hasMore: Bool, listingIsComplete: Bool) -> PathCompletionNotice? {
        if !listingIsComplete { return .partialListing }
        return hasMore ? .moreMatches : nil
    }

    private static func matches(_ name: String, _ typedName: String) -> Bool {
        typedName.isEmpty || TypeSelect.matches(name, typedName)
    }

    /// A row must lead to the entry it names: `submitAddress` tests place keywords first, then the resolver parses and trims the text.
    private static func candidate(for entry: PathCompletionEntry, query: PathCompletionQuery) -> PathCompletionCandidate? {
        guard isDisplayable(entry.name) else { return nil }
        let text = query.literalPrefix + entry.name + (entry.isFolder ? "/" : "")
        guard Location.keyword(text) == nil, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = PathCompletionQuery.parse(text, base: query.base, homeDirectory: query.homeDirectory),
              parsed.namedPath == PathCompletionQuery.path(of: entry.name, in: query.folder) else { return nil }
        return PathCompletionCandidate(text: text, name: entry.name, isFolder: entry.isFolder)
    }

    private static func isDisplayable(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.unicodeScalars.contains { isControl($0) || isBidiOverride($0) }
    }

    /// Category Cc only: `CharacterSet.controlCharacters` also holds U+200C/D, which Persian, Indic and emoji names need.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .control }

    private static func isBidiOverride(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
}
