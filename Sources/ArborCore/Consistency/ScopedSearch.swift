import Foundation

/// What the search box covers in places that aren't a single folder (Explorer: Home searches the
/// user folder plus what Home shows, a library searches all its folders, This PC searches every drive).
public enum ScopedSearch {
    /// At most this many extra places, so a long Recent list can't turn one search into hundreds.
    public static let extraLimit = 64

    /// True if `url` is `root` or inside it.
    public static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        if base == "/" { return true }
        return path == base || path.hasPrefix(base + "/")
    }

    /// Keeps the first of each place and drops places inside one kept before (or inside `scope`).
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

    /// Home: the user folder, plus pinned folders and Favorites/Recent files that live elsewhere.
    public static func home(userFolder: URL, pinnedFolders: [URL], files: [URL]) -> SearchRequest {
        SearchRequest(query: "", scope: userFolder, recursive: true,
                      extraScopes: extras(pinnedFolders + files, excluding: userFolder), originKey: Location.home.key)
    }

    /// A library: every included folder. nil when it includes none (the box then filters the page).
    public static func library(_ name: String, folders: [URL]) -> SearchRequest? {
        let unique = extras(folders, excluding: nil, limit: .max)
        guard let first = unique.first else { return nil }
        return SearchRequest(query: "", scope: first, recursive: true, extraScopes: Array(unique.dropFirst()),
                             originKey: Location.library(name).key)
    }

    /// This Mac: the Spotlight index everywhere, plus a direct scan of the other local drives (the
    /// index may not cover them). Network volumes are left to the index: scanning them is too slow.
    public static func allDrives(localVolumes: [URL]) -> SearchRequest {
        let others = localVolumes.filter { $0.standardizedFileURL.path != "/" }
        return SearchRequest(query: "", scope: nil, recursive: true, extraScopes: extras(others, excluding: nil),
                             originKey: Location.thisMac.key)
    }
}
