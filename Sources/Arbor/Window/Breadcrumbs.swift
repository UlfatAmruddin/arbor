import AppKit
import ArborCore

/// One breadcrumb segment and what its chevron lists (FE-003, FE-004).
struct Crumb {
    let title: String
    let location: Location
    /// The chevron's list, built only when clicked.
    let children: () -> [CrumbChild]
}

struct CrumbChild {
    let title: String
    let location: Location
    let icon: NSImage
}

/// Builds breadcrumbs; features with new location kinds register a builder.
enum Breadcrumbs {
    static let builders = Handlers<Location, [Crumb]>(
        "Breadcrumbs.builders", "Breadcrumbs for location kinds the core doesn't build.", signature: "(location) -> [Crumb]?")

    /// The first builder (in run order) that answers wins; otherwise the core builds them.
    static func register(_ id: String, order: ExtensionOrder = .normal, _ builder: @escaping (Location) -> [Crumb]?) {
        builders.register(id, order: order, builder)
    }

    static func crumbs(for location: Location) -> [Crumb] {
        if let crumbs = builders.first(location) { return crumbs }
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
            return [Crumb(title: L10n.tr("This Mac"), location: .thisMac, children: volumeChildren)]
        case .home:
            return [Crumb(title: L10n.tr("Home"), location: .home, children: quickAccessChildren)]
        default:
            return [Crumb(title: location.displayName, location: location, children: { [] })]
        }
    }

    /// Top-level places for the chevron after the location icon.
    static func rootChildren() -> [CrumbChild] {
        let places: [Location] = [.home, .gallery]
        let tail: [Location] = [.thisMac, .network, .trash]
        return places.map(child) + quickAccessChildren() + tail.map(child)
    }

    /// Volume root down to the folder.
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
