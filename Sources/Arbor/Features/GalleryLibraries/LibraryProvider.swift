import AppKit
import ArborCore

/// Saved library definitions (FE-076). Editing them never touches files (FE-239).
enum LibraryStore {
    static let changed = Notification.Name("ArborLibrariesChanged")
    private static let key = "libraries.v1"
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var all: [LibraryDefinition] {
        get {
            if let data = Prefs.store.data(forKey: key), let value = try? JSONDecoder().decode([LibraryDefinition].self, from: data) {
                return value
            }
            return LibraryLogic.defaults(home: home)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { Prefs.store.set(data, forKey: key) }
            resolvedSaveLocations = [:]
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func definition(_ name: String) -> LibraryDefinition? { all.first { $0.name == name } }

    static func update(_ library: LibraryDefinition) {
        var list = all
        if let index = list.firstIndex(where: { $0.name == library.name }) { list[index] = library } else { list.append(library) }
        all = list
    }

    /// "Restore defaults": the library's original single folder.
    static func restoreDefaults(_ name: String) {
        guard let original = LibraryLogic.defaultDefinition(named: name, home: home) else { return }
        update(original)
    }

    // MARK: Save location (FE-238)

    /// Resolved off-main on load so `targetFolder` never touches a possibly slow or offline disk.
    private(set) static var resolvedSaveLocations: [String: SaveLocationResolution] = [:]

    static func isUsableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Call off the main thread.
    static func resolve(_ library: LibraryDefinition) -> SaveLocationResolution {
        LibraryLogic.resolveSaveLocation(library, isUsable: isUsableFolder)
    }

    static func remember(_ resolution: SaveLocationResolution, for name: String) { resolvedSaveLocations[name] = resolution }

    static func icon(for name: String, size: CGFloat) -> NSImage {
        switch name {
        case LibraryLogic.rootName: return IconProvider.shared.symbolIcon("books.vertical.fill", color: 0x8A5A2B, size: size)
        case "Documents": return IconProvider.shared.symbolIcon("doc.on.doc.fill", color: 0x4F6D8F, size: size)
        case "Music": return IconProvider.shared.symbolIcon("music.note.list", color: 0xD2561E, size: size)
        case "Pictures": return IconProvider.shared.symbolIcon("photo.on.rectangle", color: 0x2A8FBD, size: size)
        case "Videos": return IconProvider.shared.symbolIcon("film.stack", color: 0x7A4FC1, size: size)
        default: return IconProvider.shared.folderIcon(.library, size: size)
        }
    }
}

struct LibraryNotFound: LocalizedError {
    let name: String
    var errorDescription: String? { "The “\(name)” library doesn't exist. It may have been removed." }
}

/// Libraries page and merged library listings (FE-076): each folder's top level as real items, plus a
/// "Folder" column in Details. New/Paste go to the default save location (FE-238).
final class LibraryProvider: LocationProvider {
    func handles(_ location: Location) -> Bool {
        if case .library = location { return true }
        return false
    }

    private static func name(_ location: Location) -> String? {
        if case .library(let name) = location { return name }
        return nil
    }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard let name = Self.name(location) else { return nil }
        if name == LibraryLogic.rootName {
            completion(.success(.custom(LibrariesPageController(host: context.host))))
            return nil
        }
        guard let library = LibraryStore.definition(name) else {
            completion(.failure(LibraryNotFound(name: name)))
            return nil
        }
        let handle = LoadHandle()
        let includeHidden = context.showHidden
        DispatchQueue.global(qos: .userInitiated).async { [weak host = context.host] in
            let result = LibraryMerge.list(library, includeHidden: includeHidden)
            let resolution = LibraryStore.resolve(library)
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                LibraryStore.remember(resolution, for: name)
                completion(.success(.items(result.items)))
                if !result.unavailable.isEmpty {
                    let list = DisplayPath.quotedList(result.unavailable.map(\.folder))
                    host?.showStatusMessage(L10n.format("Some folders in this library aren't available, so it may be incomplete: %@", "\(list)"), isError: true)
                }
            }
        }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        guard let name = Self.name(location) else { return nil }
        return LibraryWatcher(folders: LibraryStore.definition(name)?.folderURLs ?? [], onChange: onChange)
    }

    func title(for location: Location) -> String { location.displayName }

    func icon(for location: Location, size: CGFloat) -> NSImage { LibraryStore.icon(for: Self.name(location) ?? "", size: size) }

    /// Default save location, or nil (New/Paste then explain why, FE-238).
    func targetFolder(for location: Location) -> URL? {
        guard let name = Self.name(location), name != LibraryLogic.rootName else { return nil }
        return LibraryStore.resolvedSaveLocations[name]?.url
    }

    func allowsItemEditing(in location: Location) -> Bool { Self.name(location) != LibraryLogic.rootName }

    func emptyText(for location: Location) -> String {
        guard let name = Self.name(location), let library = LibraryStore.definition(name) else { return L10n.tr("This library is empty.") }
        return library.folders.isEmpty ? L10n.tr("This library doesn't include any folders. Use Manage library to include one.") : L10n.tr("This library is empty.")
    }
}

/// Watches every folder of a library (and the library's definition) and coalesces changes.
final class LibraryWatcher {
    private var watchers: [DirectoryWatcher] = []
    private var observer: NSObjectProtocol?

    init(folders: [URL], onChange: @escaping () -> Void) {
        for folder in folders {
            let watcher = DirectoryWatcher()
            watcher.watch(folder, onChange: onChange)
            watchers.append(watcher)
        }
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.changed, object: nil, queue: .main) { _ in onChange() }
    }

    deinit {
        watchers.forEach { $0.stop() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - Libraries page

/// "Libraries": one tile per library, like Explorer's Libraries folder.
final class LibrariesPageController: NSViewController, LocationPageStatus {
    weak var host: LocationHost?
    private let grid = NSStackView()
    private var observer: NSObjectProtocol?
    /// Search text: only libraries whose names contain it are shown.
    var filterText = "" { didSet { if filterText != oldValue, isViewLoaded { rebuild() } } }

    init(host: LocationHost?) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var statusSummary: String { StatusText.items(LibraryStore.all.filter { PageFilter.matches($0.name, filterText) }.count) + "  |" }

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        grid.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
        ])
        view = root
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    private func rebuild() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let libraries = LibraryStore.all.filter { PageFilter.matches($0.name, filterText) }
        let perRow = 4
        for start in stride(from: 0, to: libraries.count, by: perRow) {
            let row = NSStackView(views: libraries[start..<min(start + perRow, libraries.count)].map(tile))
            row.orientation = .horizontal
            row.spacing = 4
            grid.addArrangedSubview(row)
        }
    }

    private func tile(_ library: LibraryDefinition) -> NSView {
        let tile = TileButton(icon: LibraryStore.icon(for: library.name, size: 40), title: library.name, subtitle: L10n.tr("Library"))
        tile.toolTip = library.folders.joined(separator: "\n")
        let location = Location.library(library.name)
        tile.onClick = { [weak self] in self?.host?.navigate(to: location, select: []) }
        tile.onMiddleClick = { [weak self] in self?.host?.openInNewTab(location) }
        return tile
    }
}
