import AppKit
import ArborCore

/// One breadcrumb segment and what its chevron lists (FE-003, FE-004).
struct Crumb {
    let title: String
    let location: Location
    /// Locations listed by the chevron after this segment; built only when the chevron is clicked.
    let children: () -> [CrumbChild]
}

struct CrumbChild {
    let title: String
    let location: Location
    let icon: NSImage
}

/// Builds breadcrumbs for a location. Features with new location kinds can register a builder.
enum Breadcrumbs {
    private static var builders: [(Location) -> [Crumb]?] = []

    /// Most recently registered builder that returns non-nil wins.
    static func register(_ builder: @escaping (Location) -> [Crumb]?) { builders.append(builder) }

    static func crumbs(for location: Location) -> [Crumb] {
        for builder in builders.reversed() { if let crumbs = builder(location) { return crumbs } }
        switch location {
        case .folder(let url): return folderCrumbs(url)
        case .archive(let url, let inner):
            var crumbs = folderCrumbs(url.deletingLastPathComponent())
            var path = ""
            crumbs.append(Crumb(title: url.lastPathComponent, location: .archive(url, innerPath: ""), children: { [] }))
            for part in inner.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                crumbs.append(Crumb(title: String(part), location: .archive(url, innerPath: path), children: { [] }))
            }
            return crumbs
        case .search(let request):
            var crumbs = request.scope.map { folderCrumbs($0) } ?? []
            crumbs.append(Crumb(title: location.displayName, location: location, children: { [] }))
            return crumbs
        case .thisMac:
            return [Crumb(title: "This Mac", location: .thisMac, children: volumeChildren)]
        case .home:
            return [Crumb(title: "Home", location: .home, children: quickAccessChildren)]
        default:
            return [Crumb(title: location.displayName, location: location, children: { [] })]
        }
    }

    /// Entries for the chevron right after the location icon: top-level places.
    static func rootChildren() -> [CrumbChild] {
        let places: [Location] = [.home, .gallery]
        let tail: [Location] = [.thisMac, .network, .trash]
        return places.map(child) + quickAccessChildren() + tail.map(child)
    }

    /// Volume root ("Macintosh HD") down to the folder. Each chevron lists that folder's subfolders.
    static func folderCrumbs(_ url: URL) -> [Crumb] {
        var chain: [URL] = []
        var current = url.standardizedFileURL
        while true {
            chain.insert(current, at: 0)
            if Location.isVolumeRoot(current) || current.path == "/" { break }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return chain.map { folder in
            let location = Location.folder(folder)
            return Crumb(title: LocationRegistry.provider(for: location).title(for: location), location: location,
                         children: { subfolderChildren(of: folder) })
        }
    }

    /// One directory level, read when the chevron is clicked; never recursive.
    static func subfolderChildren(of folder: URL) -> [CrumbChild] {
        let folders = (try? DirectoryLister.subfolders(of: folder, includeHidden: Prefs.showHidden)) ?? []
        return folders.prefix(500).map {
            CrumbChild(title: $0.name, location: .folder($0.url), icon: IconProvider.shared.icon(for: $0, size: 16))
        }
    }

    static func volumeChildren() -> [CrumbChild] {
        ThisMacProvider.volumes().map {
            CrumbChild(title: $0.name, location: .folder($0.url), icon: IconProvider.shared.icon(for: $0, size: 16))
        }
    }

    static func quickAccessChildren() -> [CrumbChild] {
        QuickAccess.urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { child(.folder($0)) }
    }

    private static func child(_ location: Location) -> CrumbChild {
        CrumbChild(title: LocationRegistry.provider(for: location).title(for: location), location: location,
                   icon: IconProvider.shared.icon(for: location, size: 16))
    }
}
