import AppKit
import UniformTypeIdentifiers
import ArborCore

/// Icons for items and locations. Folders use our own flat yellow folder artwork, drawn in code
/// (DEC-018: no Microsoft assets). Special folders add an SF Symbol glyph; drives use SF Symbols;
/// files use the macOS icon for their type. One bounded cache is shared by every window and tab.
final class IconProvider {
    static let shared = IconProvider()

    enum FolderKind: String {
        case plain, desktop, documents, downloads, pictures, music, movies, home, applications, library

        var glyph: (symbol: String, color: UInt32)? {
            switch self {
            case .plain: return nil
            case .desktop: return ("menubar.dock.rectangle", 0x1F6FC5)
            case .documents: return ("doc.text.fill", 0x4F6D8F)
            case .downloads: return ("arrow.down", 0x1E8B3A)
            case .pictures: return ("photo.fill", 0x2A8FBD)
            case .music: return ("music.note", 0xD2561E)
            case .movies: return ("film.fill", 0x7A4FC1)
            case .home: return ("house.fill", 0x2F6DB5)
            case .applications: return ("square.grid.2x2.fill", 0x3D63C9)
            case .library: return ("books.vertical.fill", 0x8A5A2B)
            }
        }
    }

    /// One byte budget for every window (CacheBudgets.iconBytes), trimmed under memory pressure.
    let cache = ByteBudgetCache<String, NSImage>(byteLimit: CacheBudgets.iconBytes)
    private let lock = NSLock()
    private lazy var specialFolders: [String: FolderKind] = {
        let fm = FileManager.default
        var map: [String: FolderKind] = [:]
        func add(_ dir: FileManager.SearchPathDirectory, _ kind: FolderKind) {
            if let url = fm.urls(for: dir, in: .userDomainMask).first { map[Location.normalizedKey(url)] = kind }
        }
        add(.desktopDirectory, .desktop)
        add(.documentDirectory, .documents)
        add(.downloadsDirectory, .downloads)
        add(.picturesDirectory, .pictures)
        add(.musicDirectory, .music)
        add(.moviesDirectory, .movies)
        map[Location.normalizedKey(fm.homeDirectoryForCurrentUser)] = .home
        map["/Applications"] = .applications
        return map
    }()

    init() {}

    func folderKind(for url: URL) -> FolderKind {
        specialFolders[Location.normalizedKey(url)] ?? .plain
    }

    // MARK: Public API

    /// Features may override icons for some items or locations (e.g. network drives). Keep these cheap: no I/O.
    static var itemIconOverrides: [(FileItem, CGFloat) -> NSImage?] = []
    static var locationIconOverrides: [(Location, CGFloat) -> NSImage?] = []

    func icon(for item: FileItem, size: CGFloat = 16) -> NSImage {
        for override in Self.itemIconOverrides { if let image = override(item, size) { return image } }
        return ItemBadges.decorate(decoratedIcon(for: item, size: size), item: item, size: size)
    }

    /// Plain icon plus feature decorations such as shortcut arrows (cached). Status badges, which
    /// change over time, are added on top by `icon(for:size:)` (see `ItemBadges`).
    func decoratedIcon(for item: FileItem, size: CGFloat) -> NSImage {
        guard let decorate = InteractionHooks.decorateIcon else { return plainIcon(for: item, size: size) }
        // A custom icon found later gets its own entry (the type icon was cached under the plain key).
        let custom = !item.isFolder && CustomIcons.shared.icon(for: item.url) != nil
        let key = "decorated-\(item.url.path)-\(size)" + (custom ? "-custom" : "")
        if let hit = lock.withLock({ cache.value(for: key) }) { return hit }
        let plain = plainIcon(for: item, size: size)
        let decorated = decorate(item, plain, size)
        // Most items aren't decorated: the entry then only points at the shared plain icon.
        let pixels = Int(size * 2)
        lock.withLock { cache.insert(decorated ?? plain, for: key, cost: decorated == nil ? 256 : max(1024, pixels * pixels * 4)) }
        return decorated ?? plain
    }

    /// The icon without decorations or status badges.
    func plainIcon(for item: FileItem, size: CGFloat = 16) -> NSImage {
        if item.isFolder {
            // The volume check reads the cached mount table, so folders share their kind's artwork instead of
            // one cache entry per folder path; only drives are cached per path.
            let key = Location.normalizedKey(item.url)
            if MountPoints.shared.isMountPoint(key) {
                return cached("item-\(key)-\(size)", cost: size) { driveIcon(for: item.url, size: size) }
            }
            return folderIcon(folderKind(for: item.url), size: size)
        }
        return fileIcon(item.url, size: size)
    }

    func icon(for location: Location, size: CGFloat = 16) -> NSImage {
        for override in Self.locationIconOverrides { if let image = override(location, size) { return image } }
        switch location {
        case .folder(let url):
            if Location.isVolumeRoot(url) { return driveIcon(for: url, size: size) }
            return folderIcon(folderKind(for: url), size: size)
        case .home: return symbolIcon("house.fill", color: 0x2F6DB5, size: size)
        case .thisMac: return symbolIcon("desktopcomputer", color: 0x2F6DB5, size: size)
        case .gallery: return symbolIcon("photo.on.rectangle.angled", color: 0x2A8FBD, size: size)
        case .network: return symbolIcon("network", color: 0x2F6DB5, size: size)
        case .trash: return symbolIcon("trash.fill", color: 0x6B6B6B, size: size)
        case .search: return symbolIcon("magnifyingglass", color: 0x2F6DB5, size: size)
        case .archive: return symbolIcon("doc.zipper", color: 0x8A6D1F, size: size)
        case .library: return folderIcon(.library, size: size)
        case .server(let address): return symbolIcon(address.isServer ? "desktopcomputer" : "externaldrive.connected.to.line.below.fill",
                                                     color: 0x6E6E6E, size: size)
        }
    }

    func folderIcon(_ kind: FolderKind = .plain, size: CGFloat) -> NSImage {
        cached("folder-\(kind.rawValue)-\(size)", cost: size) {
            NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
                Self.drawFolder(in: rect, glyph: kind.glyph)
                return true
            }
        }
    }

    func driveIcon(for url: URL, size: CGFloat) -> NSImage {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey])
        let symbol: String
        if values?.volumeIsLocal == false { symbol = "server.rack" }
        else if values?.volumeIsInternal == false || values?.volumeIsRemovable == true { symbol = "externaldrive.fill" }
        else { symbol = "internaldrive.fill" }
        return symbolIcon(symbol, color: 0x6E6E6E, size: size)
    }

    func symbolIcon(_ name: String, color: UInt32, size: CGFloat) -> NSImage {
        cached("sym-\(name)-\(color)-\(size)", cost: size) {
            NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                guard let img = NSImage.tintedSymbol(name, size: size * 0.78, color: Theme.rgb(color)) else { return false }
                let s = img.size
                let scale = min(rect.width / s.width, rect.height / s.height, 1)
                let w = s.width * scale, h = s.height * scale
                img.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
                return true
            }
        }
    }

    /// Extensions whose files can each look different (apps, icon files, links); everything else with
    /// an extension uses its type's icon, looked up once instead of once per file (spec §15.3).
    static let perFileIconExtensions: Set<String> = ["app", "icns", "ico", "lnk", "url", "webloc", "fileloc", "inetloc"]

    func fileIcon(_ url: URL, size: CGFloat) -> NSImage {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, !Self.perFileIconExtensions.contains(ext), let type = UTType(filenameExtension: ext), !type.isDynamic {
            // A custom Finder icon (checked in the background for files on screen) wins over the type's icon.
            if let custom = CustomIcons.shared.icon(for: url) {
                return cached("custom-\(url.path)-\(size)", cost: size) {
                    let image = custom.copy() as? NSImage ?? custom
                    image.size = NSSize(width: size, height: size)
                    return image
                }
            }
            return cached("type-\(type.identifier)-\(size)", cost: size) {
                let image = NSWorkspace.shared.icon(for: type)
                image.size = NSSize(width: size, height: size)
                return image
            }
        }
        return cached("file-\(url.path)-\(size)", cost: size) {
            // Items that aren't on disk (archive members) get their type's icon instead of a blank page.
            let image = FileManager.default.fileExists(atPath: url.path) ? NSWorkspace.shared.icon(forFile: url.path)
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
            image.size = NSSize(width: size, height: size)
            return image
        }
    }

    /// `cost` is the icon's point size: an icon costs about its 2x bitmap once drawn.
    private func cached(_ key: String, cost size: CGFloat = 32, make: () -> NSImage) -> NSImage {
        if let hit = lock.withLock({ cache.value(for: key) }) { return hit }
        let image = make()
        let pixels = Int(size * 2)
        lock.withLock { cache.insert(image, for: key, cost: max(1024, pixels * pixels * 4)) }
        return image
    }

    /// Drops file icons (their type can change); folder artwork stays.
    func purgeFileIcons() { lock.withLock { cache.removeAll() } }

    /// Memory pressure (CacheRegistry).
    func trim(_ level: CacheTrimLevel) {
        lock.withLock { cache.trim(toBytes: level == .critical ? 0 : cache.byteLimit / 4) }
    }

    var cachedBytes: Int { lock.withLock { cache.totalCost } }
    var cachedCount: Int { lock.withLock { cache.count } }

    // MARK: Folder artwork

    /// A flat manila folder on a 32-unit grid: a darker back panel with a tab and a lighter front panel.
    static func drawFolder(in rect: NSRect, glyph: (symbol: String, color: UInt32)?) {
        let u = rect.width / 32
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * u, y: rect.minY + y * u, width: w * u, height: h * u)
        }
        // Back panel with tab (flipped: y grows downward).
        let back = NSBezierPath()
        let radius = 2.2 * u
        back.move(to: NSPoint(x: rect.minX + 2 * u, y: rect.minY + 7 * u))
        back.appendArc(from: NSPoint(x: rect.minX + 2 * u, y: rect.minY + 5 * u),
                       to: NSPoint(x: rect.minX + 4 * u, y: rect.minY + 5 * u), radius: radius)
        back.line(to: NSPoint(x: rect.minX + 11.5 * u, y: rect.minY + 5 * u))
        back.line(to: NSPoint(x: rect.minX + 14.5 * u, y: rect.minY + 8 * u))
        back.appendArc(from: NSPoint(x: rect.minX + 30 * u, y: rect.minY + 8 * u),
                       to: NSPoint(x: rect.minX + 30 * u, y: rect.minY + 12 * u), radius: radius)
        back.line(to: NSPoint(x: rect.minX + 30 * u, y: rect.minY + 26 * u))
        back.line(to: NSPoint(x: rect.minX + 2 * u, y: rect.minY + 26 * u))
        back.close()
        Theme.rgb(0xE0A526).setFill()
        back.fill()

        // Front panel.
        let frontRect = r(2, 10.5, 28, 16.5)
        let front = NSBezierPath(roundedRect: frontRect, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(starting: Theme.rgb(0xFFD866), ending: Theme.rgb(0xF8C33A))
        gradient?.draw(in: front, angle: 90)
        // Soft highlight along the top edge of the front panel.
        Theme.rgb(0xFFE89A).setFill()
        NSBezierPath(roundedRect: r(2.6, 10.5, 26.8, 0.9), xRadius: 0.45 * u, yRadius: 0.45 * u).fill()

        guard let glyph, rect.width >= 14 else { return }
        let glyphSize = frontRect.height * 0.55
        guard let image = NSImage.tintedSymbol(glyph.symbol, size: glyphSize, weight: .semibold, color: Theme.rgb(glyph.color)) else { return }
        let s = image.size
        let scale = min((frontRect.height * 0.72) / s.height, (frontRect.width * 0.6) / s.width, 1)
        let w = s.width * scale, h = s.height * scale
        image.drawFlippedAware(in: NSRect(x: frontRect.midX - w / 2, y: frontRect.midY - h / 2 + 0.3 * u, width: w, height: h))
    }
}

extension Location {
    /// Path without trailing slash, for dictionary keys.
    static func normalizedKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
