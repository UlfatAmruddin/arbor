import AppKit
import ArborCore

/// `.network`: the Network page.
final class NetworkPageProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .network }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        completion(.success(.custom(NetworkPageController(host: context.host))))
        return nil
    }

    func allowsItemEditing(in location: Location) -> Bool { false }
    func targetFolder(for location: Location) -> URL? { nil }
}

/// `.server(address)`: a server shows its shared folders; a share (or folder in it) is connected
/// first and the tab then shows the mounted folder. The `.server` share entry itself never enters
/// history, so Back never re-runs a connection.
final class ServerProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { if case .server = location { return true }; return false }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard case .server(let address) = location else { return nil }
        if address.isServer {
            completion(.success(.custom(ServerPageController(server: address, host: context.host))))
            return nil
        }
        let handle = LoadHandle()
        // Find the requesting tab once `request` has stored this handle (after we return).
        DispatchQueue.main.async { [weak host = context.host] in
            guard !handle.isCancelled, let window = host as? BrowserWindowController,
                  let tab = window.tabs.first(where: { $0.pendingLoad === handle }) else { return }
            let attempt = NetworkConnectFlow.open(address, in: window, tab: tab) { _ in }
            handle.onCancel = { attempt.cancel() }
        }
        return handle
    }

    func title(for location: Location) -> String {
        guard case .server(let address) = location else { return location.displayName }
        return address.isServer ? address.hostDisplayName : location.displayName
    }

    func icon(for location: Location, size: CGFloat) -> NSImage {
        guard case .server(let address) = location else { return IconProvider.shared.icon(for: location, size: size) }
        return address.isServer ? NetworkIcons.computer(size) : NetworkIcons.share(size)
    }

    func allowsItemEditing(in location: Location) -> Bool { false }
    func targetFolder(for location: Location) -> URL? { nil }
}

/// Folders on network shares (FE-179): listed off the main thread with a deadline. A share that
/// doesn't answer gets a "not responding" page with Retry while other tabs keep working; a share that
/// went away gets a "disconnected" page with Reconnect that keeps the server/share identity.
final class NetworkFolderProvider: LocationProvider {
    private let queue = SlowWorkQueue<Result<[FileItem], Error>>(label: "arbor.network.listing")
    /// Results that arrived after the deadline, served once on the next load of that folder.
    private var lateResults: [String: (Date, Result<[FileItem], Error>)] = [:]
    private let folders = FolderProvider()

    func handles(_ location: Location) -> Bool {
        guard let url = location.folderURL else { return false }
        let center = NetworkCenter.shared
        return center.share(containing: url) != nil || center.disconnectedShare(containing: url) != nil
    }

    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        guard let url = location.folderURL else { return nil }
        let center = NetworkCenter.shared
        if center.share(containing: url) == nil, let gone = center.disconnectedShare(containing: url) {
            completion(.success(.custom(disconnectedPage(url, share: gone, host: context.host))))
            return nil
        }
        if let (time, result) = lateResults.removeValue(forKey: url.path), Date().timeIntervalSince(time) < 30 {
            completion(result.map { .items($0) })
            return nil
        }
        let handle = LoadHandle()
        let includeHidden = context.showHidden
        let delay = center.services.simulatedListingDelay(for: url)
        weak var timeoutPage: NetworkMessagePage?
        let token = queue.run(key: url.path + (includeHidden ? "#h" : ""), timeout: center.listingTimeout, work: {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return Result { try DirectoryLister.list(url, includeHidden: includeHidden) }
        }, late: { [weak self, weak host = context.host] result in
            // The share answered after all: keep the result and refresh if its page is still up.
            self?.lateResults[url.path] = (Date(), result)
            if timeoutPage?.view.window != nil { host?.reloadLocation() }
        }) { [weak self] outcome in
            guard let self, !handle.isCancelled else { return }
            switch outcome {
            case .finished(let result):
                completion(result.map { .items($0) })
            case .timedOut:
                let page = self.notRespondingPage(url, host: context.host)
                timeoutPage = page
                completion(.success(.custom(page)))
            }
        }
        handle.onCancel = { [weak self] in self?.queue.cancel(token) }
        return handle
    }

    func watch(_ location: Location, onChange: @escaping () -> Void) -> AnyObject? {
        guard let url = location.folderURL else { return nil }
        if NetworkCenter.shared.share(containing: url) == nil {
            // Disconnected: come back by itself once the share is reconnected (here, in another tab, or automatically).
            return NetworkChangeWatcher {
                NetworkCenter.shared.invalidateMounts()
                if NetworkCenter.shared.share(containing: url) != nil { onChange() }
            }
        }
        // Opening the watch descriptor touches the share; do it off the main thread.
        let watcher = DirectoryWatcher()
        DispatchQueue.global(qos: .utility).async { [weak watcher] in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            close(fd)
            DispatchQueue.main.async { watcher?.watch(url, onChange: onChange) }
        }
        return watcher
    }

    func title(for location: Location) -> String {
        guard let url = location.folderURL else { return location.displayName }
        let center = NetworkCenter.shared
        if let share = center.share(containing: url) ?? center.disconnectedShare(containing: url),
           Location.normalizedKey(share.mountPoint) == Location.normalizedKey(url) {
            return center.mappedDrive(for: share)?.label ?? share.address?.share ?? share.volumeName
        }
        return url.lastPathComponent
    }

    func icon(for location: Location, size: CGFloat) -> NSImage {
        guard let url = location.folderURL else { return IconProvider.shared.icon(for: location, size: size) }
        let center = NetworkCenter.shared
        if let share = center.share(containing: url), Location.normalizedKey(share.mountPoint) == Location.normalizedKey(url) {
            return NetworkIcons.drive(size)
        }
        if let gone = center.disconnectedShare(containing: url), Location.normalizedKey(gone.mountPoint) == Location.normalizedKey(url) {
            return NetworkIcons.drive(size, disconnected: true)
        }
        return IconProvider.shared.folderIcon(.plain, size: size)
    }

    func targetFolder(for location: Location) -> URL? {
        guard let url = location.folderURL, NetworkCenter.shared.share(containing: url) != nil else { return nil }
        return url
    }

    func allowsItemEditing(in location: Location) -> Bool { targetFolder(for: location) != nil }

    private func notRespondingPage(_ url: URL, host: LocationHost?) -> NetworkMessagePage {
        let share = NetworkCenter.shared.share(containing: url)
        let name = share?.address(of: url)?.unc ?? url.path
        return NetworkMessagePage(
            icon: NetworkIcons.drive(48), title: "\(name) isn't responding",
            message: "The network share is taking too long to answer. Other tabs keep working. Arbor shows the folder as soon as it answers.",
            actions: [.init(title: "Retry", primary: true) { [weak host] in host?.reloadLocation() },
                      .init(title: "Go to This Mac", primary: false) { [weak host] in host?.navigate(to: .thisMac, select: []) }],
            spinner: true)
    }

    private func disconnectedPage(_ url: URL, share: MountedShare, host: LocationHost?) -> NetworkMessagePage {
        let address = share.address(of: url) ?? share.address
        let name = address?.unc ?? url.path
        var actions: [NetworkMessagePage.Action] = []
        if let address {
            actions.append(.init(title: "Reconnect", primary: true) { [weak host] in
                guard let window = host as? BrowserWindowController else { return }
                let tab = window.activeTab
                _ = NetworkConnectFlow.open(address, in: window, tab: tab) { ok in if ok { window.reload() } }
            })
        }
        actions.append(.init(title: "Go to This Mac", primary: false) { [weak host] in host?.navigate(to: .thisMac, select: []) })
        let page = NetworkMessagePage(
            icon: NetworkIcons.drive(48, disconnected: true), title: "\(name) is disconnected",
            message: "The network share isn't connected any more. Reconnect to keep browsing this folder.", actions: actions)
        page.onNetworkChange = { [weak page, weak host] in
            NetworkCenter.shared.invalidateMounts()
            guard page?.view.window != nil, NetworkCenter.shared.share(containing: url) != nil else { return }
            host?.reloadLocation()
        }
        return page
    }
}

/// Reloads a location when mapped drives change.
final class NetworkChangeWatcher {
    var inner: AnyObject?
    private var observer: NSObjectProtocol?
    init(onChange: @escaping () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: NetworkCenter.changed, object: nil, queue: .main) { _ in onChange() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
