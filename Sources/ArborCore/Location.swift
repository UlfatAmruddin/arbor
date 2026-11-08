import Foundation

/// What a search tab is looking for. The search feature extends this; keep it a plain value.
public struct SearchRequest: Hashable, Sendable {
    public var query: String
    /// Folder the search covers. nil means "everywhere the search provider can reach".
    public var scope: URL?
    public var recursive: Bool
    /// Search options ▸ Advanced options (File contents, System files, Zipped files).
    public var options: SearchOptions = []
    /// More places the search covers besides `scope`: the other folders of a library, pinned folders
    /// outside the user folder (Home), other drives (This Mac). A file here is matched by itself.
    public var extraScopes: [URL] = []
    /// Key of the location the search was started from when that isn't the scope folder (Home, a
    /// library, This Mac): its name titles the results and Up / Close search return there.
    public var originKey: String?

    public init(query: String, scope: URL? = nil, recursive: Bool = true, options: SearchOptions = [],
                extraScopes: [URL] = [], originKey: String? = nil) {
        self.query = query
        self.scope = scope?.standardizedFileURL
        self.recursive = recursive
        self.options = options
        self.extraScopes = extraScopes.map(\.standardizedFileURL)
        self.originKey = originKey
    }

    /// The location the search was started from, if it isn't the scope folder.
    public var origin: Location? { originKey.flatMap(Location.init(key:)) }
}

/// Explorer's Advanced options for a search. Stored in the location key as `opts=csz`.
public struct SearchOptions: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Free-text words also match file contents.
    public static let contents = SearchOptions(rawValue: 1)
    /// Include hidden items and look inside packages (apps, bundles).
    public static let systemFiles = SearchOptions(rawValue: 2)
    /// Look inside .zip archives.
    public static let zipped = SearchOptions(rawValue: 4)

    static let letters: [(Character, SearchOptions)] = [("c", .contents), ("s", .systemFiles), ("z", .zipped)]
    var code: String { String(Self.letters.filter { contains($0.1) }.map { $0.0 }) }
    init(code: String) {
        var o: SearchOptions = []
        for (letter, option) in Self.letters where code.contains(letter) { o.insert(option) }
        self = o
    }
}

/// Anything a tab can show (spec §3.2): a real folder or a virtual namespace.
///
/// Equality and hashing use `key`, so `/a` and `/a/` are the same folder.
public enum Location: Hashable, Sendable, CustomStringConvertible {
    case folder(URL)
    case home
    case thisMac
    case gallery
    case network
    case trash
    case search(SearchRequest)
    /// A folder inside an archive file. `innerPath` is "" for the archive's root, otherwise "a/b".
    case archive(URL, innerPath: String)
    /// A library (a projection of several real folders), identified by name.
    case library(String)
    /// A network server (`\\NAS`), or a share or folder on it before it is mounted (FE-078, FE-176).
    case server(NetworkAddress)

    public static func == (lhs: Location, rhs: Location) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    public var description: String { key }

    /// The real folder this location shows, if it is one.
    public var folderURL: URL? {
        if case .folder(let url) = self { return url.standardizedFileURL }
        return nil
    }

    public var isFolder: Bool { folderURL != nil }

    // MARK: Names

    public var displayName: String {
        switch self {
        case .folder(let url):
            let path = url.standardizedFileURL.path
            let name = FileManager.default.displayName(atPath: path)
            return name.isEmpty ? (path == "/" ? "/" : url.lastPathComponent) : name
        case .home: return L10n.tr("Home")
        case .thisMac: return L10n.tr("This Mac")
        case .gallery: return L10n.tr("Gallery")
        case .network: return L10n.tr("Network")
        case .trash: return L10n.tr("Trash")
        case .search(let request):
            if let origin = request.origin { return L10n.format("Search Results in %@", "\(origin.displayName)") }
            let scope = request.scope.map { Location.folder($0).displayName }
            return scope.map { L10n.format("Search Results in %@", $0) } ?? L10n.tr("Search Results")
        case .archive(let url, let inner):
            let last = inner.split(separator: "/").last.map(String.init)
            return last ?? url.lastPathComponent
        case .library(let name): return name
        case .server(let address): return address.path.last ?? address.share ?? address.hostDisplayName
        }
    }

    // MARK: Persistence

    /// Stable string identity, used for equality, persistence and per-location settings.
    /// Forms: `folder:/path`, `home`, `thismac`, `gallery`, `network`, `trash`,
    /// `search?q=…&scope=/path&recursive=1`, `archive?file=/a.zip&inner=x/y`, `library?name=Documents`.
    public var key: String {
        switch self {
        case .folder(let url): return "folder:" + Self.normalizedPath(url)
        case .home: return "home"
        case .thisMac: return "thismac"
        case .gallery: return "gallery"
        case .network: return "network"
        case .trash: return "trash"
        case .search(let r):
            var items = [URLQueryItem(name: "q", value: r.query)]
            if let scope = r.scope { items.append(URLQueryItem(name: "scope", value: Self.normalizedPath(scope))) }
            items.append(URLQueryItem(name: "recursive", value: r.recursive ? "1" : "0"))
            if !r.options.isEmpty { items.append(URLQueryItem(name: "opts", value: r.options.code)) }
            for extra in r.extraScopes { items.append(URLQueryItem(name: "also", value: Self.normalizedPath(extra))) }
            if let origin = r.originKey { items.append(URLQueryItem(name: "from", value: origin)) }
            return Self.compose("search", items)
        case .archive(let url, let inner):
            return Self.compose("archive", [URLQueryItem(name: "file", value: Self.normalizedPath(url)),
                                            URLQueryItem(name: "inner", value: Self.trimSlashes(inner))])
        case .library(let name):
            return Self.compose("library", [URLQueryItem(name: "name", value: name)])
        case .server(let address):
            return Self.compose("server", [URLQueryItem(name: "url", value: address.url.absoluteString)])
        }
    }

    public init?(key: String) {
        if key.hasPrefix("folder:") {
            let path = String(key.dropFirst("folder:".count))
            guard path.hasPrefix("/") else { return nil }
            self = .folder(URL(fileURLWithPath: path))
            return
        }
        switch key {
        case "home": self = .home; return
        case "thismac": self = .thisMac; return
        case "gallery": self = .gallery; return
        case "network": self = .network; return
        case "trash": self = .trash; return
        default: break
        }
        guard let components = URLComponents(string: "arbor:" + key) else { return nil }
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch components.path {
        case "search":
            guard let q = values["q"] else { return nil }
            let extras = (components.queryItems ?? []).filter { $0.name == "also" }.compactMap(\.value)
                .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
            self = .search(SearchRequest(query: q, scope: values["scope"].map { URL(fileURLWithPath: $0) },
                                         recursive: values["recursive"] != "0",
                                         options: SearchOptions(code: values["opts"] ?? ""),
                                         extraScopes: extras, originKey: values["from"].flatMap { $0.isEmpty ? nil : $0 }))
        case "archive":
            guard let file = values["file"], file.hasPrefix("/") else { return nil }
            self = .archive(URL(fileURLWithPath: file), innerPath: values["inner"] ?? "")
        case "library":
            guard let name = values["name"], !name.isEmpty else { return nil }
            self = .library(name)
        case "server":
            guard let text = values["url"], let url = URL(string: text), let address = NetworkAddress(url: url) else { return nil }
            self = .server(address)
        default:
            return nil
        }
    }

    // MARK: Up (FE-002)

    /// The location Up goes to. A folder goes to its parent folder; a volume root goes to This Mac;
    /// a search goes to its scope; an archive folder goes to its parent inside the archive, and the
    /// archive root to the folder holding the archive; a library goes to Libraries. Home and the other
    /// top-level places have none.
    public func parent(isVolumeRoot: (URL) -> Bool = Location.isVolumeRoot) -> Location? {
        switch self {
        case .folder(let url):
            let url = url.standardizedFileURL
            if url.path == "/" || isVolumeRoot(url) { return .thisMac }
            return .folder(url.deletingLastPathComponent().standardizedFileURL)
        case .search(let request):
            if let origin = request.origin { return origin }
            return request.scope.map { .folder($0) }
        case .archive(let url, let inner):
            let parts = Self.trimSlashes(inner).split(separator: "/")
            if parts.isEmpty {
                if let outer = NestedArchives.parent(of: url) { return outer }
                return .folder(url.standardizedFileURL.deletingLastPathComponent())
            }
            return .archive(url, innerPath: parts.dropLast().joined(separator: "/"))
        case .library(let name):
            // A library's Up is the Libraries page (FE-076); the Libraries page has none.
            return name == LibraryLogic.rootName ? nil : .library(LibraryLogic.rootName)
        case .server(let address):
            if !address.path.isEmpty { var up = address; up.path.removeLast(); return .server(up) }
            return address.share == nil ? .network : .server(address.server)
        case .home, .thisMac, .gallery, .network, .trash:
            return nil
        }
    }

    /// The root of a mounted volume ("/", "/Volumes/USB", …).
    public static func isVolumeRoot(_ url: URL) -> Bool {
        // The kernel's mount table instead of a metadata read: this runs on the main thread for every
        // tab title, icon and Up button, and a read can block on a slow network volume.
        MountPoints.shared.isMountPoint(normalizedPath(url))
    }

    // MARK: Typed names

    /// Words the address bar accepts for virtual places ("Home", "This Mac", "This PC", "Recycle Bin"…).
    public static func keyword(_ text: String) -> Location? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "home": return .home
        case "this mac", "thismac", "this pc", "computer", "my computer": return .thisMac
        case "gallery": return .gallery
        case "network": return .network
        case "trash", "recycle bin", "bin": return .trash
        default: return nil
        }
    }

    // MARK: Helpers

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    static func trimSlashes(_ s: String) -> String {
        s.split(separator: "/").joined(separator: "/")
    }

    /// Values are strictly percent-encoded so "&", "=" and "+" in a query survive a round trip.
    private static func compose(_ path: String, _ items: [URLQueryItem]) -> String {
        // ASCII only: percentEncodedQueryItems traps on unencoded non-ASCII letters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        var c = URLComponents()
        c.path = path
        c.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return c.string ?? path
    }
}
