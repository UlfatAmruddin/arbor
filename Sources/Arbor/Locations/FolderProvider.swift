import AppKit
import ArborCore

/// Real folders: one-level listing off the main thread, plus a change watcher (FE-229).
final class FolderProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location.isFolder }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard let url = location.folderURL else { return nil }
        let handle = LoadHandle()
        let includeHidden = context.showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try DirectoryLister.list(url, includeHidden: includeHidden) }
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                completion(result.map { .items($0) })
            }
        }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        guard let url = location.folderURL else { return nil }
        let watcher = DirectoryWatcher()
        watcher.watch(url, onChange: onChange)
        return watcher
    }

    func title(for location: Location) -> String {
        guard let url = location.folderURL else { return location.displayName }
        if Location.isVolumeRoot(url), let name = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName {
            return name
        }
        return location.displayName
    }
}
