import AppKit
import ArborCore

/// One Trash folder: the user's (~/.Trash), a volume's (.Trashes/<uid>), or the headless test folder.
struct TrashFolder: Equatable {
    let url: URL
    let volumeName: String
    let volumeURL: URL?
}

/// One item in the Trash with what Arbor knows about it.
struct TrashEntry {
    let item: FileItem
    let folder: TrashFolder
    /// Present when Arbor trashed the item (original location and date are known).
    let record: TrashRecord?
    /// Journal date, else the date the item entered the Trash folder (`addedToDirectoryDate`), else nil.
    let dateDeleted: Date?
}

enum TrashListing {
    /// `total` counts every item, hidden ones included (for the empty/full icon).
    case items([TrashEntry], unreadable: [TrashFolder], total: Int)
    /// macOS refused to list the user's Trash (Full Disk Access is required on recent macOS).
    case denied(URL)
}

/// Reads the Trash folders (off the main thread) and keeps the latest listing for the views (main thread).
enum TrashStore {
    static let changed = Notification.Name("ArborTrashChanged")

    /// The latest listing, keyed by item path. Main thread only.
    private(set) static var entries: [String: TrashEntry] = [:]
    /// Whether the Trash holds anything (nil = unknown, e.g. access denied). Main thread only.
    private(set) static var isFull: Bool?
    private(set) static var lastListingDenied = false

    static func entry(for url: URL) -> TrashEntry? { entries[url.standardizedFileURL.path] }

    // MARK: Folders

    /// Headless runs show only the test Trash (`SystemTrash.testDirectory`), never the real one.
    static func folders(fileManager fm: FileManager = .default) -> [TrashFolder] {
        if let test = SystemTrash.testDirectory {
            return [TrashFolder(url: test.standardizedFileURL, volumeName: "Test Trash", volumeURL: nil)]
        }
        let homeTrash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").standardizedFileURL
        let bootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
        var result = [TrashFolder(url: homeTrash, volumeName: bootName, volumeURL: URL(fileURLWithPath: "/"))]
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let v = try? volume.resourceValues(forKeys: Set(keys))
            // Network volumes are skipped: no usable per-user Trash, and asking can stall (spec §13.2).
            guard volume.standardizedFileURL.path != "/", v?.volumeIsLocal != false, v?.volumeIsReadOnly != true else { continue }
            guard let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volume, create: false)
                .standardizedFileURL, trash != homeTrash, !result.contains(where: { $0.url == trash }) else { continue }
            result.append(TrashFolder(url: trash, volumeName: v?.volumeLocalizedName ?? volume.lastPathComponent, volumeURL: volume))
        }
        return result
    }

    // MARK: Listing (background)

    private static let ignoredNames: Set<String> = [".DS_Store", ".localized"]

    static func list(includeHidden: Bool) -> TrashListing {
        let fm = FileManager.default
        let folders = folders()
        if ProcessInfo.processInfo.environment["ARBOR_TEST_TRASH_DENIED"] != nil, let first = folders.first {
            return .denied(first.url)
        }
        var raw: [(url: URL, folder: TrashFolder, record: TrashRecord?, added: Date?)] = []
        var unreadable: [TrashFolder] = []
        let keys = FileItem.resourceKeys + [.addedToDirectoryDateKey]
        for (index, folder) in folders.enumerated() {
            guard fm.fileExists(atPath: folder.url.path) else { continue }
            do {
                // Hidden items are always read so the journal isn't pruned of them; the filter comes later.
                let urls = try fm.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: keys, options: [])
                    .filter { !ignoredNames.contains($0.lastPathComponent) }
                TrashJournal.shared.prune(folder: folder.url, existing: Set(urls.map { $0.standardizedFileURL.path }))
                for url in urls {
                    let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
                    raw.append((url.standardizedFileURL, folder, TrashJournal.shared.lookup(url), added))
                }
            } catch let error as NSError {
                if isPermissionError(error) {
                    if index == 0 { return .denied(folder.url) }
                    unreadable.append(folder)
                } else if !(error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) {
                    unreadable.append(folder)
                }
            }
        }
        let names = TrashNaming.displayNames(raw.map {
            TrashNaming.Entry(onDisk: $0.url.lastPathComponent, original: $0.record?.originalName, group: $0.folder.volumeName)
        })
        var entries: [TrashEntry] = []
        for (i, r) in raw.enumerated() {
            guard let base = FileItem(url: r.url) else { continue }
            if !includeHidden, base.isHidden { continue }
            let item = FileItem(url: base.url, name: names[i], isFolder: base.isFolder, isPackage: base.isPackage,
                                isHidden: base.isHidden, isSymbolicLink: base.isSymbolicLink, size: base.size,
                                modified: base.modified, typeDescription: base.typeDescription)
            entries.append(TrashEntry(item: item, folder: r.folder, record: r.record, dateDeleted: r.record?.dateDeleted ?? r.added))
        }
        return .items(entries, unreadable: unreadable, total: raw.count)
    }

    static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    // MARK: Main-thread state

    static func adopt(_ listing: TrashListing) {
        switch listing {
        case .items(let list, _, let total):
            entries = Dictionary(list.map { ($0.item.url.path, $0) }, uniquingKeysWith: { a, _ in a })
            setFull(total > 0)
            lastListingDenied = false
        case .denied:
            entries = [:]
            lastListingDenied = true
            setFull(nil)
        }
    }

    private static func setFull(_ value: Bool?) {
        guard value != isFull else { return }
        isFull = value
        NavigationPaneExtras.refreshAll()
    }

    /// Re-reads fullness in the background (launch, after changes made outside a Trash view).
    static func refreshState() {
        DispatchQueue.global(qos: .utility).async {
            let listing = list(includeHidden: true)
            DispatchQueue.main.async { adopt(listing) }
        }
    }

    /// Tells Trash views and icons that the Trash changed (coalesced).
    static func noteChanged() {
        DispatchQueue.main.async {
            pendingChange?.cancel()
            let work = DispatchWorkItem {
                NotificationCenter.default.post(name: changed, object: nil)
                refreshState()
            }
            pendingChange = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private static var pendingChange: DispatchWorkItem?
}

/// The Trash location (FE-077): items from every Trash folder in the standard views, with
/// Original Location and Date Deleted columns.
final class TrashProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .trash }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        let handle = LoadHandle()
        let includeHidden = context.showHidden
        DispatchQueue.global(qos: .userInitiated).async { [weak host = context.host] in
            let listing = TrashStore.list(includeHidden: includeHidden)
            DispatchQueue.main.async {
                guard !handle.isCancelled else { return }
                TrashStore.adopt(listing)
                switch listing {
                case .items(let entries, let unreadable, _):
                    completion(.success(.items(entries.map(\.item))))
                    if !unreadable.isEmpty {
                        host?.showStatusMessage("The Trash on \(unreadable.map { "“\($0.volumeName)”" }.joined(separator: ", ")) couldn't be read.", isError: true)
                    }
                case .denied(let url):
                    completion(.success(.custom(TrashAccessPage(trashURL: url, host: host))))
                }
            }
        }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? { TrashWatcher(onChange: onChange) }
    func title(for location: Location) -> String { "Trash" }
    func icon(for location: Location, size: CGFloat) -> NSImage { TrashIcon.image(full: TrashStore.isFull == true, size: size) }
    func targetFolder(for location: Location) -> URL? { nil }
    func allowsItemEditing(in location: Location) -> Bool { false }
}

/// Refreshes the Trash view when a Trash folder changes on disk or Arbor changes the Trash.
final class TrashWatcher {
    private var watchers: [DirectoryWatcher] = []
    private var observer: NSObjectProtocol?

    init(onChange: @escaping () -> Void) {
        for folder in TrashStore.folders() {
            let watcher = DirectoryWatcher()
            watcher.watch(folder.url, onChange: onChange)
            watchers.append(watcher)
        }
        observer = NotificationCenter.default.addObserver(forName: TrashStore.changed, object: nil, queue: .main) { _ in onChange() }
    }

    deinit {
        watchers.forEach { $0.stop() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Shown when macOS won't let Arbor read the Trash (spec §16.1 "Denied": the actual reason and the way to grant access).
final class TrashAccessPage: NSViewController, LocationPageStatus {
    let trashURL: URL
    weak var host: LocationHost?

    init(trashURL: URL, host: LocationHost?) {
        self.trashURL = trashURL
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var statusSummary: String { "" }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    override func loadView() {
        let root = ThemeBackgroundView(Theme.contentBackground)
        let icon = NSImageView(image: TrashIcon.image(full: false, size: 64))
        let title = NSTextField(labelWithString: "Arbor needs permission to show the Trash")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.primaryText
        let detail = NSTextField(wrappingLabelWithString:
            "macOS protects the Trash folder. To see, restore and empty items here, turn on Arbor in System Settings → Privacy & Security → Full Disk Access, then come back and select Try Again.")
        detail.font = Theme.bodyFont
        detail.textColor = Theme.secondaryText
        detail.alignment = .center
        let open = NSButton(title: "Open Full Disk Access Settings", target: self, action: #selector(openSettings))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        let retry = NSButton(title: "Try Again", target: self, action: #selector(retry))
        retry.bezelStyle = .rounded
        let finder = NSButton(title: "Show the Trash in Finder", target: self, action: #selector(showInFinder))
        finder.bezelStyle = .rounded
        let buttons = NSStackView(views: [open, retry, finder])
        buttons.spacing = 8
        let stack = NSStackView(views: [icon, title, detail, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -30),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
        ])
        root.setAccessibilityLabel("Arbor needs permission to show the Trash")
        view = root
    }

    @objc private func openSettings() { SystemOpen.open(Self.settingsURL) }
    @objc private func retry() { host?.reloadLocation() }
    @objc private func showInFinder() { SystemOpen.open(trashURL) }
}
