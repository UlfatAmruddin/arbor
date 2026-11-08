import Foundation

/// Paths as messages show them: always without `/private`, which Foundation strips only for paths
/// that exist (qa-places #14). Stored paths are unchanged.
public enum DisplayPath {
    public static func of(_ url: URL) -> String { of(url.standardizedFileURL.path) }

    public static func of(_ path: String) -> String {
        for top in ["tmp", "var", "etc"] where path == "/private/\(top)" || path.hasPrefix("/private/\(top)/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// “/a”, “/b” for a list of folders.
    public static func quotedList(_ urls: [URL]) -> String {
        urls.map { "“\(of($0))”" }.joined(separator: ", ")
    }
}
