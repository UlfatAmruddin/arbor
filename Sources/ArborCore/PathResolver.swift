import Foundation

public enum PathResolution: Equatable, Sendable {
    case folder(URL)
    /// An existing file: show its folder and select it.
    case file(URL)
    /// For the system's connect flow.
    case network(URL)
}

public enum PathResolutionError: Error, Equatable, LocalizedError {
    case empty
    case windowsDriveLetter(String)
    case notFound(String)
    case unsupportedScheme(String)
    case invalidAddress(String)
    case pathTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return L10n.tr("Type a folder path.")
        case .windowsDriveLetter(let input):
            return L10n.format("“%@” is a Windows drive path. Macs don't use drive letters; other disks appear under /Volumes.", "\(input)")
        case .notFound(let path):
            return L10n.format("Can't find “%@”. Check the spelling and try again.", "\(path)")
        case .unsupportedScheme(let input):
            return L10n.format("“%@” isn't a supported address. Use a folder path, a file:// URL, or a server address such as smb://server/share.", "\(input)")
        case .invalidAddress(let input):
            return L10n.format("“%@” isn't a valid address.", "\(input)")
        case .pathTooLong(let path):
            return L10n.format("The path to “%@” is too long for macOS to open.", (path as NSString).lastPathComponent)
        }
    }
}

/// Resolves address-bar text (FE-005, FE-013, FE-014). Never evaluated by a shell.
public struct PathResolver: Sendable {
    /// nil if nothing exists, else whether it is a directory.
    public typealias Probe = @Sendable (String) -> Bool?

    public static let liveProbe: Probe = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ? isDirectory.boolValue : nil
    }

    public static let networkSchemes: Set<String> = ["smb", "afp", "nfs", "cifs"]

    public var homeDirectory: URL
    public var probe: Probe

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, probe: @escaping Probe = PathResolver.liveProbe) {
        self.homeDirectory = homeDirectory
        self.probe = probe
    }

    public func resolve(_ raw: String, relativeTo current: URL?) -> Result<PathResolution, PathResolutionError> {
        let text = Self.unquoted(raw)
        guard !text.isEmpty else { return .failure(.empty) }

        // UNC \\server\share\folder → smb://server/share/folder
        if text.hasPrefix("\\\\") {
            let parts = text.split(separator: "\\").map(String.init)
            // "\\\share" has no server name.
            guard parts.count >= 1, !text.hasPrefix("\\\\\\"), !parts[0].contains("/"), !parts[0].contains(" ") else {
                return .failure(.invalidAddress(text))
            }
            var components = URLComponents()
            components.scheme = "smb"
            components.host = parts[0]
            components.path = parts.count == 1 ? "" : "/" + parts.dropFirst().joined(separator: "/")
            guard let url = components.url else { return .failure(.invalidAddress(text)) }
            return .success(.network(url))
        }

        if Self.isWindowsDrivePath(text) { return .failure(.windowsDriveLetter(text)) }

        var path: String
        if text.lowercased().hasPrefix("file://") {
            var rest = String(text.dropFirst("file://".count))
            if rest.lowercased().hasPrefix("localhost/") { rest = String(rest.dropFirst("localhost".count)) }
            path = rest.removingPercentEncoding ?? rest
            guard path.hasPrefix("/") else { return .failure(.invalidAddress(text)) }
        } else if let scheme = Self.scheme(of: text) {
            guard Self.networkSchemes.contains(scheme.lowercased()) else { return .failure(.unsupportedScheme(text)) }
            guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
                return .failure(.invalidAddress(text))
            }
            // "smb:///share" names no server; never pass it to the connect flow.
            guard let host = url.host, !host.isEmpty else { return .failure(.invalidAddress(text)) }
            return .success(.network(url))
        } else if let local = Self.localPath(text, home: homeDirectory, base: current) {
            path = local
        } else {
            // ~user can ask directory services, so it stays out of `localPath`, which runs on every keystroke.
            let expanded = (text as NSString).expandingTildeInPath
            guard !expanded.hasPrefix("~") else { return .failure(.notFound(text)) }
            path = expanded
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard PathLimits.fits(url) else { return .failure(.pathTooLong(url.path)) }
        switch probe(url.path) {
        case .some(true): return .success(.folder(Self.onDiskSpelling(url)))
        case .some(false): return .success(.file(Self.onDiskSpelling(url)))
        case .none: return .failure(.notFound(url.path))
        }
    }

    /// Trimmed, and without one pair of surrounding quotes.
    static func unquoted(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// The `~`, `~/x`, `/x` or relative form as a path; nil for `~user`. Strings only: `isDirectory:` keeps URL from calling stat.
    static func localPath(_ text: String, home: URL, base: URL?) -> String? {
        if text == "~" { return home.path }
        if text.hasPrefix("~/") { return home.appendingPathComponent(String(text.dropFirst(2)), isDirectory: false).path }
        if text.hasPrefix("~") { return nil }
        if text.hasPrefix("/") { return text }
        let parent = base ?? home
        return text.isEmpty ? parent.path : parent.appendingPathComponent(text, isDirectory: false).path
    }

    /// Case and Unicode form as stored on disk, so a typed folder matches the clicked one (QA-CORE-2).
    /// Symlinks and missing components stay as typed.
    public static func onDiskSpelling(_ url: URL) -> URL {
        var result = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            let next = result.appendingPathComponent(component)
            let stored = (try? next.resourceValues(forKeys: [.nameKey]).name) ?? component
            let sameName = stored.compare(component, options: [.caseInsensitive]) == .orderedSame
            result = result.appendingPathComponent(sameName ? stored : component)
        }
        return result.standardizedFileURL
    }

    static func isWindowsDrivePath(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 2, chars[0].isASCII, chars[0].isLetter, chars[1] == ":" else { return false }
        return chars.count == 2 || chars[2] == "\\" || chars[2] == "/"
    }

    static func scheme(of text: String) -> String? {
        guard let range = text.range(of: "://") else { return nil }
        let scheme = text[text.startIndex..<range.lowerBound]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        return String(scheme)
    }
}
