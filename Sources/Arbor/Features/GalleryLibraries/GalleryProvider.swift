import AppKit
import ArborCore
import CoreServices

/// The Gallery location (FE-075). One page per window: a reload (Refresh, after Trash or rename, or
/// a change in a source folder) reuses the page on screen so scroll position and selection survive.
final class GalleryProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .gallery }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        if let window = context.host as? BrowserWindowController, window.activeTab.displayedLocation == .gallery,
           let page = window.activeTab.page as? GalleryPageController {
            page.refresh()
            completion(.success(.custom(page)))
            return nil
        }
        completion(.success(.custom(GalleryPageController(host: context.host))))
        return nil
    }

    /// FSEvents on the collection's folders (recursive, coalesced): new, renamed or removed photos
    /// show up without a manual refresh.
    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        GalleryWatch(onChange: onChange)
    }

    func title(for location: Location) -> String { "Gallery" }
    /// Items are real files: rename and Trash act on them. New/Paste have no meaning here (no target folder).
    func allowsItemEditing(in location: Location) -> Bool { true }
    func targetFolder(for location: Location) -> URL? { nil }
}

/// Watches the collection's current folders, following changes to the collection.
final class GalleryWatch {
    private var watcher: TreeWatcher?
    private var observer: NSObjectProtocol?
    private var roots: [URL] = []

    init(onChange: @escaping () -> Void) {
        restart(onChange)
        observer = NotificationCenter.default.addObserver(forName: GalleryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            self?.restart(onChange)
        }
    }

    private func restart(_ onChange: @escaping () -> Void) {
        let now = GalleryPrefs.collection.scanRoots
        guard now != roots || watcher == nil else { return }
        roots = now
        watcher = TreeWatcher(roots: now, latency: 1.5, onChange: onChange)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// A recursive, coalescing file-system watcher (FSEvents). Calls back on the main queue.
final class TreeWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(roots: [URL], latency: TimeInterval, onChange: @escaping () -> Void) {
        guard !roots.isEmpty else { return nil }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
