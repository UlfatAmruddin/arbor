import Foundation

/// What a request from outside Arbor shows: the Dock, `open -a`, Finder documents, the Open in Arbor service (FE-218).
public enum ExternalOpen {
    public static let maxItems = 5_000
    public static let maxTabs = 16
    /// A check that finishes later than this (a dead mount) is dropped, so no tab jumps up long after the request.
    public static let staleAfter: TimeInterval = 15

    public struct Target: Equatable, Sendable {
        public let location: Location
        public fileprivate(set) var select: [String]
    }

    public struct Plan: Equatable, Sendable {
        public let targets: [Target]
        public let skipped: Int
    }

    /// Reads the disk, so callers stay off the main thread.
    public static func items(for urls: [URL]) -> (items: [FileItem], skipped: Int) {
        var items: [FileItem] = []
        var seen = Set<String>()
        var skipped = max(urls.count - maxItems, 0)
        for url in urls.prefix(maxItems) {
            guard let local = localFileURL(url) else { skipped += 1; continue }
            guard seen.insert(local.path).inserted else { continue }
            if let item = FileItem(url: local) { items.append(item) } else { skipped += 1 }
        }
        return (items, skipped)
    }

    /// `ownLocation` may read the disk, so it stops being asked once every tab is taken.
    public static func plan(_ items: [FileItem], skipped: Int, ownLocation: (FileItem) -> Location?) -> Plan {
        var targets: [Target] = []
        var indexes: [Location: Int] = [:]
        var skipped = skipped
        for item in items {
            let isFull = targets.count >= maxTabs
            let target = target(for: item, own: item.isFolder || isFull ? nil : ownLocation(item))
            if let index = indexes[target.location] {
                targets[index].select += target.select
            } else if isFull {
                skipped += 1
            } else {
                indexes[target.location] = targets.count
                targets.append(target)
            }
        }
        return Plan(targets: targets, skipped: skipped)
    }

    /// Packages are revealed too: Show Package Contents stays the explicit way in.
    private static func target(for item: FileItem, own: Location?) -> Target {
        if item.isFolder { return Target(location: .folder(item.url), select: []) }
        if let own { return Target(location: own, select: []) }
        return Target(location: .folder(item.url.deletingLastPathComponent()), select: [item.name])
    }

    /// The stored spelling keeps one folder one location (QA-CORE-2).
    private static func localFileURL(_ url: URL) -> URL? {
        let host = url.host ?? ""
        guard url.isFileURL, url.baseURL == nil, host.isEmpty || host == "localhost",
              // Foundation keeps %00 as literal text, and a file could have that name.
              !url.absoluteString.contains("%00"),
              // A file reference URL gives its current path, or nil once the file is gone.
              let path = (url as NSURL).filePathURL, path.path.hasPrefix("/") else { return nil }
        return PathResolver.onDiskSpelling(path)
    }
}
