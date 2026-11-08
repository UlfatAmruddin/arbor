import AppKit
import ArborCore

/// App-wide network state: mounts, mapped drives, (re)connecting (FE-176, FE-177, FE-187).
/// Main thread only and no network file system I/O: mount state comes from the mount table.
final class NetworkCenter {
    static let shared = NetworkCenter()
    /// Posted when mapped drives, their status, or mounted shares change.
    static let changed = Notification.Name("ArborNetworkChanged")

    enum DriveStatus: Equatable {
        case connected(MountedShare)
        case connecting
        case disconnected(String?)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    let services: NetworkServicing
    let isFake: Bool
    /// Connection timeout before offering Retry.
    let mountTimeout: TimeInterval
    /// Listing timeout before the "not responding" page (FE-179).
    let listingTimeout: TimeInterval

    private(set) var drives: MappedDriveList
    private var connecting: [UUID: NetworkCancellable] = [:]
    private var lastErrors: [UUID: String] = [:]
    /// Mount points the user disconnected on purpose; never auto-reconnect them.
    private var userDisconnected: Set<String> = []
    private var policy = ReconnectPolicy()
    /// Network mount points seen this session, so a vanished one shows "disconnected" + Reconnect.
    private(set) var remembered: [String: MountedShare] = [:]
    private var observers: [NSObjectProtocol] = []
    private static let storeKey = "network.mappedDrives"

    init(services: NetworkServicing? = nil) {
        let env = Automation.environment
        if let services {
            self.services = services
            isFake = services is FakeNetworkServices
        } else if let fake = env["ARBOR_FAKE_NETWORK"], !fake.isEmpty {
            self.services = FakeNetworkServices.fromEnvironment(fake)
            isFake = true
        } else {
            self.services = LiveNetworkServices()
            isFake = false
        }
        mountTimeout = env["ARBOR_NETWORK_MOUNT_TIMEOUT"].flatMap(Double.init) ?? 45
        listingTimeout = env["ARBOR_NETWORK_TIMEOUT"].flatMap(Double.init) ?? 15
        drives = MappedDriveList.decode(Prefs.store.data(forKey: Self.storeKey))
        drives.dropSessionOnly()
        save()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            self?.volumeMounted(note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            self?.volumeUnmounted(note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
        })
    }

    // MARK: Mount state (no I/O)

    /// Cached briefly: providers ask for every folder they might handle.
    private var cachedShares: (time: Date, shares: [MountedShare])?

    func mountedShares() -> [MountedShare] {
        if let cached = cachedShares, Date().timeIntervalSince(cached.time) < 0.25 { return cached.shares }
        let shares = services.mountedShares()
        for share in shares { remembered[share.mountPoint.path] = share }
        cachedShares = (Date(), shares)
        return shares
    }

    func invalidateMounts() { cachedShares = nil }

    func share(containing url: URL) -> MountedShare? {
        mountedShares().filter { $0.contains(url) }.max { $0.mountPoint.path.count < $1.mountPoint.path.count }
    }

    /// A share seen this session (or mapped) that holds `url` but is gone now.
    func disconnectedShare(containing url: URL) -> MountedShare? {
        guard share(containing: url) == nil else { return nil }
        var candidate = remembered.values.filter { $0.contains(url) }.max { $0.mountPoint.path.count < $1.mountPoint.path.count }
        if candidate == nil {
            for drive in drives.drives {
                guard let root = drive.address.shareRoot else { continue }
                let share = MountedShare(mountPoint: NetworkThisMac.placeholder(for: drive), address: root, volumeName: root.share ?? "", fileSystem: "smbfs")
                if share.contains(url) { candidate = share; break }
            }
        }
        // Something local may be mounted there now; cheap to check.
        if candidate != nil, !isFake, FileManager.default.fileExists(atPath: url.path) { return nil }
        return candidate
    }

    func existingMount(for address: NetworkAddress) -> MountedShare? {
        guard let root = address.shareRoot else { return nil }
        let shares = mountedShares()
        if let mapped = drives.drives.first(where: { $0.address.shareRoot.map { $0.sameShare(as: root) } ?? false }),
           let hit = drives.match(shares)[mapped.id] { return hit }
        return shares.first { $0.address.map(root.sameShare(as:)) ?? false }
    }

    func status(of drive: MappedDrive) -> DriveStatus {
        if let share = drives.match(mountedShares())[drive.id] { return .connected(share) }
        if connecting[drive.id] != nil { return .connecting }
        return .disconnected(lastErrors[drive.id])
    }

    func mappedDrive(for share: MountedShare) -> MappedDrive? {
        let match = drives.match(mountedShares())
        return drives.drives.first { match[$0.id]?.mountPoint == share.mountPoint }
    }

    // MARK: Connecting

    /// Connects (reusing a mount); returns mount point + address subfolders. Cancellable, times out after `mountTimeout`.
    @discardableResult
    func connect(_ address: NetworkAddress, options: MountOptions = MountOptions(),
                 completion: @escaping (Result<URL, NetworkError>) -> Void) -> NetworkCancellable {
        if !options.differentCredentials, let existing = existingMount(for: address) {
            let folder = Self.folder(existing.mountPoint, address.path)
            DispatchQueue.main.async { completion(.success(folder)) }
            return NetworkCancellable()
        }
        var finished = false
        var timeout: DispatchWorkItem?
        let mount = services.mount(address, options: options) { [weak self] result in
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let points):
                let root = self?.existingMount(for: address)?.mountPoint ?? points.first
                guard let root else { completion(.failure(.noShares(address.server.unc))); return }
                self?.userDisconnected.remove(root.path)
                self?.invalidateMounts()
                _ = self?.mountedShares()
                NotificationCenter.default.post(name: Self.changed, object: nil)
                completion(.success(Self.folder(root, address.path)))
            }
        }
        let work = DispatchWorkItem {
            guard !finished else { return }
            finished = true
            mount.cancel()
            completion(.failure(.timedOut(address.shareRoot?.unc ?? address.unc)))
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + mountTimeout, execute: work)
        return NetworkCancellable {
            guard !finished else { return }
            finished = true
            work.cancel()
            mount.cancel()
        }
    }

    static func folder(_ root: URL, _ path: [String]) -> URL {
        path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
    }

    // MARK: Mapped drives (FE-177)

    /// "Map network drive" → Finish: connect, then save the mapping with its identity.
    func map(_ address: NetworkAddress, reconnectAtSignIn: Bool, differentCredentials: Bool,
             completion: @escaping (Result<(MappedDrive, URL), NetworkError>) -> Void) -> NetworkCancellable {
        connect(address, options: MountOptions(differentCredentials: differentCredentials)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let folder):
                let mounted = self.share(containing: folder)
                // The account actually used (from the mount table) is part of the identity.
                var identity = address
                if let user = mounted?.address?.user, address.user == nil { identity = identity.withUser(user) }
                let drive = self.drives.add(MappedDrive(address: identity, reconnectAtSignIn: reconnectAtSignIn,
                                                        usesDifferentCredentials: differentCredentials,
                                                        lastMountPoint: mounted?.mountPoint.path))
                self.lastErrors[drive.id] = nil
                self.save()
                if let mounted { self.captureVolumeUUID(drive.id, mounted.mountPoint) }
                NotificationCenter.default.post(name: Self.changed, object: nil)
                completion(.success((drive, folder)))
            }
        }
    }

    /// Reconnects a mapped drive (This Mac, launch, or after it vanished).
    @discardableResult
    func reconnect(_ drive: MappedDrive, allowUI: Bool, completion: ((Result<URL, NetworkError>) -> Void)? = nil) -> NetworkCancellable {
        if let running = connecting[drive.id] { return running }
        let token = connect(drive.address, options: MountOptions(differentCredentials: allowUI && drive.usesDifferentCredentials, allowUI: allowUI)) { [weak self] result in
            guard let self else { return }
            self.connecting[drive.id] = nil
            switch result {
            case .success(let folder):
                self.lastErrors[drive.id] = nil
                if let share = self.share(containing: folder) {
                    self.drives.update(id: drive.id) { $0.lastMountPoint = share.mountPoint.path }
                    self.save()
                    self.captureVolumeUUID(drive.id, share.mountPoint)
                }
            case .failure(let error):
                self.lastErrors[drive.id] = error == .cancelled ? nil : error.localizedDescription
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
            completion?(result)
        }
        connecting[drive.id] = token
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return token
    }

    /// "Reconnect at sign-in" drives, silently at launch (Keychain only).
    func reconnectAtLaunch() {
        for drive in policy.atLaunch(drives, mounted: mountedShares()) {
            reconnect(drive, allowUI: false)
        }
    }

    func removeMapping(_ id: UUID) {
        connecting.removeValue(forKey: id)?.cancel()
        drives.remove(id: id)
        lastErrors[id] = nil
        save()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Disconnecting

    /// Unmounts; a mapped drive's mapping is removed too, like Explorer.
    func disconnect(_ share: MountedShare, force: Bool, completion: @escaping (Result<Void, NetworkError>) -> Void) {
        let mapped = mappedDrive(for: share)
        userDisconnected.insert(share.mountPoint.path)
        services.unmount(share.mountPoint, force: force) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if let mapped { self.removeMapping(mapped.id) }
                self.remembered[share.mountPoint.path] = nil
            case .failure:
                self.userDisconnected.remove(share.mountPoint.path)
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
            completion(result)
        }
    }

    /// Forget a mapping whose drive isn't connected.
    func disconnect(_ drive: MappedDrive) { removeMapping(drive.id) }

    func wasDisconnectedByUser(_ mountPoint: URL) -> Bool { userDisconnected.contains(mountPoint.standardizedFileURL.path) }

    // MARK: Volume events

    private func volumeMounted(_ url: URL?) {
        invalidateMounts()
        let shares = mountedShares()
        let match = drives.match(shares)
        var changed = false
        for drive in drives.drives {
            guard let share = match[drive.id], drive.lastMountPoint != share.mountPoint.path else { continue }
            drives.update(id: drive.id) { $0.lastMountPoint = share.mountPoint.path }
            changed = true
        }
        if changed { save() }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func volumeUnmounted(_ url: URL?) {
        invalidateMounts()
        guard let url = url?.standardizedFileURL else { return }
        let byUser = userDisconnected.contains(url.path)
        // A mapped drive vanished on its own (server restart, Wi-Fi): retry once, silently.
        if !byUser, let drive = drives.drives.first(where: { $0.lastMountPoint == url.path }),
           policy.shouldReconnect(drive, userDisconnected: false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (isFake ? 0.5 : 3)) { [weak self] in
                guard let self, let current = self.drives.drive(id: drive.id), !self.status(of: current).isConnected else { return }
                self.reconnect(current, allowUI: false)
            }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Storage (no secrets: FE-178)

    private func save() {
        Prefs.store.set(drives.encoded(), forKey: Self.storeKey)
    }

    /// Off the main thread: a network volume may be slow to answer.
    private func captureVolumeUUID(_ id: UUID, _ mountPoint: URL) {
        guard !isFake else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let uuid = (try? mountPoint.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            DispatchQueue.main.async {
                guard let self, let uuid else { return }
                self.drives.update(id: id) { $0.volumeUUID = uuid }
                self.save()
            }
        }
    }

    // MARK: Capacity (read off the main thread, cached)

    private var capacities: [String: (time: Date, free: Int64, total: Int64)] = [:]
    private var capacityRequests: Set<String> = []

    /// Free/total bytes if known; otherwise starts reading and posts `changed` when done.
    func capacity(of share: MountedShare) -> (free: Int64, total: Int64)? {
        let key = share.mountPoint.path
        if let hit = capacities[key], Date().timeIntervalSince(hit.time) < 60 { return (hit.free, hit.total) }
        if !capacityRequests.contains(key) {
            capacityRequests.insert(key)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let values = try? share.mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.capacityRequests.remove(key)
                    if let free = values?.volumeAvailableCapacity, let total = values?.volumeTotalCapacity, total > 0 {
                        self.capacities[key] = (Date(), Int64(free), Int64(total))
                        NotificationCenter.default.post(name: Self.changed, object: nil)
                    }
                }
            }
        }
        return capacities[key].map { ($0.free, $0.total) }
    }

    // MARK: File system capabilities (FE-188)

    /// Read off the main thread; `completion` runs on main.
    static func capabilities(of url: URL, completion: @escaping (FileSystemCapabilities?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let values = try? url.resourceValues(forKeys: [.volumeTypeNameKey, .volumeIsReadOnlyKey, .volumeSupportsCaseSensitiveNamesKey])
            let caps = values.flatMap { v in v.volumeTypeName.map {
                FileSystemCapabilities(typeName: $0, isReadOnly: v.volumeIsReadOnly ?? false, isCaseSensitive: v.volumeSupportsCaseSensitiveNames)
            } }
            DispatchQueue.main.async { completion(caps) }
        }
    }
}
