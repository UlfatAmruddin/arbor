import AppKit
import ArborCore

/// The saved libraries (FE-076), on the main thread. Editing them never touches files (FE-239).
enum LibraryStore {
    static let changed = Notification.Name("ArborLibrariesChanged")
    private static let key = "libraries.v1"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Decoded once; every change goes through `edit`.
    private(set) static var catalog = LibraryCatalog(data: Prefs.store.data(forKey: key), home: home)

    static var all: [LibraryDefinition] { catalog.libraries }

    static func definition(_ name: String) -> LibraryDefinition? { catalog.definition(name) }

    /// `beforeNotifying` runs before anything reloads, so no reload can see a renamed library's old name.
    static func edit(beforeNotifying: () -> Void = {}, _ change: (inout LibraryCatalog) throws -> Void) throws {
        var next = catalog
        try change(&next)
        guard next != catalog else { return }
        Prefs.store.set(try next.encoded(), forKey: key)
        resolvedSaveLocations = resolvedSaveLocations.filter { next.definition($0.key) == catalog.definition($0.key) }
        catalog = next
        beforeNotifying()
        NotificationCenter.default.post(name: changed, object: nil)
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

    /// Dropped if the library changed while it was being resolved.
    static func remember(_ resolution: SaveLocationResolution, for library: LibraryDefinition) {
        if definition(library.name) == library { resolvedSaveLocations[library.name] = resolution }
    }

    // MARK: Icons

    /// By the library's type, so a renamed library keeps its icon.
    static func icon(for name: String, size: CGFloat) -> NSImage {
        if name == LibraryLogic.rootName { return IconProvider.shared.symbolIcon("books.vertical.fill", color: 0x8A5A2B, size: size) }
        switch definition(name)?.template {
        case .documents: return IconProvider.shared.symbolIcon("doc.on.doc.fill", color: 0x4F6D8F, size: size)
        case .music: return IconProvider.shared.symbolIcon("music.note.list", color: 0xD2561E, size: size)
        case .pictures: return IconProvider.shared.symbolIcon("photo.on.rectangle", color: 0x2A8FBD, size: size)
        case .videos: return IconProvider.shared.symbolIcon("film.stack", color: 0x7A4FC1, size: size)
        case .generalItems, nil: return IconProvider.shared.folderIcon(.library, size: size)
        }
    }
}
