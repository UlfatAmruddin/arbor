import Foundation

/// Paths as messages show them.
///
/// `/tmp`, `/var` and `/etc` are links into `/private`. Foundation drops the `/private` prefix when it
/// standardizes a path that exists, but keeps it for one that doesn't, so a message listing an existing and
/// a missing folder side by side showed `/tmp/a` next to `/private/tmp/b` (qa-places #14). Shown paths
/// always use the short spelling; stored paths are unchanged.
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
