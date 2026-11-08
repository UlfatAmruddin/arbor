import Foundation

/// What the search box covers in places that aren't a single folder (Home, libraries, This PC).
public enum ScopedSearch {
    /// Caps extra places so a long Recent list can't fan one search out into hundreds.
    public static let extraLimit = 64

    public static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        if base == "/" { return true }
        return path == base || path.hasPrefix(base + "/")
    }

    /// Dedupes and drops places nested in an earlier one (or in `scope`).
    public static func extras(_ urls: [URL], excluding scope: URL?, limit: Int = extraLimit) -> [URL] {
        var kept: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            if let scope, isInside(url, scope) { continue }
            if kept.contains(where: { isInside(url, $0) }) { continue }
            kept.removeAll { isInside($0, url) }
            kept.append(url)
        }
        return Array(kept.prefix(limit))
    }

    /// Home: the user folder plus pinned, Favorites and Recent items outside it.
    public static func home(userFolder: URL, pinnedFolders: [URL], files: [URL]) -> SearchRequest {
        SearchRequest(query: "", scope: userFolder, recursive: true,
                      extraScopes: extras(pinnedFolders + files, excluding: userFolder), originKey: Location.home.key)
    }

    /// nil when the library has no folders (the box then filters the page).
    public static func library(_ name: String, folders: [URL]) -> SearchRequest? {
        let unique = extras(folders, excluding: nil, limit: .max)
        guard let first = unique.first else { return nil }
        return SearchRequest(query: "", scope: first, recursive: true, extraScopes: Array(unique.dropFirst()),
                             originKey: Location.library(name).key)
    }

    /// Spotlight everywhere plus a direct scan of other local drives it may miss; network ones are too slow to scan.
    public static func allDrives(localVolumes: [URL]) -> SearchRequest {
        let others = localVolumes.filter { $0.standardizedFileURL.path != "/" }
        return SearchRequest(query: "", scope: nil, recursive: true, extraScopes: extras(others, excluding: nil),
                             originKey: Location.thisMac.key)
    }
}
