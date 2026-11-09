import AppKit
import ArborCore

/// Libraries page and merged library listings (FE-076): each folder's top level as real items.
/// New/Paste go to the default save location (FE-238).
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
            completion(.failure(LibraryEditError.notFound(name)))
            return nil
        }
        let handle = LoadHandle()
        let includeHidden = context.showHidden
        DispatchQueue.global(qos: .userInitiated).async { [weak host = context.host] in
            let result = LibraryMerge.list(library, includeHidden: includeHidden, isCancelled: { handle.isCancelled })
            guard !handle.isCancelled else { return }
            let resolution = LibraryStore.resolve(library)
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                LibraryStore.remember(resolution, for: library)
                completion(.success(.items(result.items)))
                if let note = LibraryLogic.loadNote(unavailable: result.unavailable.map(\.folder), resolution: resolution) {
                    host?.showStatusMessage(note, isError: !result.unavailable.isEmpty)
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

    func limitation(of action: LocationAction, in location: Location) -> String? {
        if Self.name(location) == LibraryLogic.rootName { return action.notAFolderLimitation() }
        guard action == .newItem || action == .paste, targetFolder(for: location) == nil else { return nil }
        return L10n.tr("This library has no save location. Choose one in Manage library.")
    }

    func emptyText(for location: Location) -> String {
        guard let name = Self.name(location), let library = LibraryStore.definition(name) else { return L10n.tr("This library is empty.") }
        return library.folders.isEmpty ? L10n.tr("This library doesn't include any folders. Use Manage library to include one.") : L10n.tr("This library is empty.")
    }
}

/// Watches every folder of a library. Edits to the library itself reach open tabs through `LibraryActions`.
final class LibraryWatcher {
    private static let coalesceDelay: TimeInterval = 0.25
    private let onChange: () -> Void
    private var watchers: [DirectoryWatcher] = []
    private var pending: DispatchWorkItem?

    init(folders: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Opening a watch on an offline volume can stall, so only folders that just answered are watched.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reachable = folders.filter { LibraryMerge.folderIdentity($0) != nil }
            DispatchQueue.main.async { self?.watch(reachable) }
        }
    }

    private func watch(_ folders: [URL]) {
        for folder in folders {
            let watcher = DirectoryWatcher()
            watcher.watch(folder) { [weak self] in self?.folderChanged() }
            watchers.append(watcher)
        }
    }

    /// Up to 64 folders throttle on their own, so one reload stands in for a burst across them.
    private func folderChanged() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: work)
    }

    deinit {
        pending?.cancel()
        watchers.forEach { $0.stop() }
    }
}
