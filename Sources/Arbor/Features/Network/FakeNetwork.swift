import AppKit
import ArborCore

/// Test network for scripted runs (`ARBOR_FAKE_NETWORK`); servers and shares are local folders:
///     <root>/<server>/<share>/…            folder = server, subfolder = share
///     <root>/<server>/.arbor-fake.json     optional: type, listDelay, mountDelay, offline, requiresCredentials, slowListing
///     <root>/<server>/<share>/.arbor-busy  refuses to unmount unless forced
/// `=1` builds a temporary sample root; any other value is the root. Mounts post the real NSWorkspace notifications.
final class FakeNetworkServices: NetworkServicing {
    struct Behaviour: Decodable {
        var type: String?
        var listDelay: Double?
        var mountDelay: Double?
        var offline: Bool?
        var requiresCredentials: Bool?
        /// Seconds every folder listing inside this server's shares takes (FE-179).
        var slowListing: Double?
    }

    let root: URL
    private var mounted: [MountedShare] = []

    init(root: URL) { self.root = root.standardizedFileURL }

    static func fromEnvironment(_ value: String) -> FakeNetworkServices {
        if value == "1" || value.lowercased() == "true" {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arbor-fake-network-\(ProcessInfo.processInfo.processIdentifier)")
            makeSampleRoot(root)
            FakeNetworkCleanup.path = root.path
            atexit { if let path = FakeNetworkCleanup.path { try? FileManager.default.removeItem(atPath: path) } }
            return FakeNetworkServices(root: root)
        }
        return FakeNetworkServices(root: URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
    }

    /// NAS-01 and OFFICE-PC both export "Public" (FE-187); the rest cover slow, offline, locked, AFP and router cases.
    static func makeSampleRoot(_ root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        func dir(_ path: String) { try? fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        func file(_ path: String, _ text: String = "sample\n") { try? text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        dir("NAS-01/Media/Movies"); dir("NAS-01/Media/Music"); file("NAS-01/Media/readme.txt")
        dir("NAS-01/Backups/2026"); dir("NAS-01/Public"); file("NAS-01/Public/from-nas.txt")
        dir("OFFICE-PC/Projects/Arbor"); file("OFFICE-PC/Projects/plan.txt"); dir("OFFICE-PC/Public"); file("OFFICE-PC/Public/from-office.txt")
        dir("SLOW-NAS/Archive/Old"); file("SLOW-NAS/Archive/big.log")
        file("SLOW-NAS/.arbor-fake.json", #"{"slowListing": 4}"#)
        dir("OFFLINE-PC/Data")
        file("OFFLINE-PC/.arbor-fake.json", #"{"offline": true, "listDelay": 60}"#)
        dir("LOCKED-NAS/Private")
        file("LOCKED-NAS/.arbor-fake.json", #"{"requiresCredentials": true}"#)
        dir("OLD-MAC/Shared")
        file("OLD-MAC/.arbor-fake.json", #"{"type": "_afpovertcp._tcp"}"#)
        dir("Base Station")
        file("Base Station/.arbor-fake.json", #"{"type": "_airport._tcp"}"#)
    }

    private func serverFolders() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func folder(for host: String) -> URL? {
        serverFolders().first { $0.lastPathComponent.lowercased() == host.lowercased() }
    }

    func behaviour(of host: String) -> Behaviour {
        guard let folder = folder(for: host),
              let data = try? Data(contentsOf: folder.appendingPathComponent(".arbor-fake.json")),
              let b = try? JSONDecoder().decode(Behaviour.self, from: data) else { return Behaviour() }
        return b
    }

    // MARK: NetworkServicing

    func makeDiscovery() -> NetworkDiscovering { FakeDiscovery(services: self) }

    func discoveredServices() -> Set<DiscoveredService> {
        Set(serverFolders().map { DiscoveredService(name: $0.lastPathComponent, type: behaviour(of: $0.lastPathComponent).type ?? "_smb._tcp") })
    }

    func resolve(_ device: NetworkDevice, completion: @escaping (NetworkAddress?) -> Void) {
        let scheme = device.preferredScheme
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            completion(scheme.map { NetworkAddress(scheme: $0, host: device.name) })
        }
    }

    @discardableResult
    func listShares(on server: NetworkAddress, completion: @escaping (Result<[NetworkShareInfo], NetworkError>) -> Void) -> NetworkCancellable {
        let token = NetworkCancellable()
        let b = behaviour(of: server.host)
        let delay = b.listDelay ?? 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !token.isCancelled else { return }
            guard let folder = self.folder(for: server.host), b.offline != true else { completion(.failure(.unreachable(server.unc))); return }
            if (b.type ?? "_smb._tcp") != "_smb._tcp" { completion(.failure(.listingUnsupported(server.unc))); return }
            let shares = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.hasDirectoryPath }
                .map { NetworkShareInfo(name: $0.lastPathComponent) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            completion(shares.isEmpty ? .failure(.noShares(server.unc)) : .success(shares))
        }
        return token
    }

    @discardableResult
    func mount(_ address: NetworkAddress, options: MountOptions, completion: @escaping (Result<[URL], NetworkError>) -> Void) -> NetworkCancellable {
        let token = NetworkCancellable()
        let b = behaviour(of: address.host)
        let delay = b.offline == true ? 60 : (b.mountDelay ?? 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !token.isCancelled else { return }
            guard let serverFolder = self.folder(for: address.host) else { completion(.failure(.unreachable(address.server.unc))); return }
            if b.requiresCredentials == true, !options.differentCredentials {
                completion(.failure(.authenticationFailed(address.server.unc)))
                return
            }
            // Server address: the fake picks the first share.
            let shareName = address.share ?? ((try? FileManager.default.contentsOfDirectory(atPath: serverFolder.path))?
                .filter { !$0.hasPrefix(".") }.sorted().first)
            guard let shareName, let share = self.shareFolder(serverFolder, shareName) else {
                completion(.failure(.failed("The shared folder “\(address.share ?? "")” doesn't exist on \(address.server.unc).", code: Int(ENOENT))))
                return
            }
            let user = options.differentCredentials ? (address.user ?? "otheruser") : address.user
            let addr = NetworkAddress(scheme: address.scheme, host: serverFolder.lastPathComponent, port: address.port, user: user, share: share.lastPathComponent)
            if !self.mounted.contains(where: { $0.mountPoint == share.standardizedFileURL }) {
                self.mounted.append(MountedShare(mountPoint: share, address: addr, volumeName: share.lastPathComponent, fileSystem: "smbfs"))
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared,
                                                           userInfo: [NSWorkspace.volumeURLUserInfoKey: share])
            }
            completion(.success([share]))
        }
        return token
    }

    private func shareFolder(_ server: URL, _ name: String) -> URL? {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: server, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return candidates.first { $0.lastPathComponent.lowercased() == name.lowercased() && $0.hasDirectoryPath }?.standardizedFileURL
    }

    func unmount(_ mountPoint: URL, force: Bool, completion: @escaping (Result<Void, NetworkError>) -> Void) {
        let point = mountPoint.standardizedFileURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if !force, FileManager.default.fileExists(atPath: point.appendingPathComponent(".arbor-busy").path) {
                completion(.failure(.busy(point.lastPathComponent)))
                return
            }
            self.mounted.removeAll { $0.mountPoint == point }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: NSWorkspace.shared,
                                                       userInfo: [NSWorkspace.volumeURLUserInfoKey: point])
            completion(.success(()))
        }
    }

    /// Simulates the server going away without the user disconnecting (FE-179 / FE-177 reconnect).
    func dropConnection(_ mountPoint: URL) {
        let point = mountPoint.standardizedFileURL
        mounted.removeAll { $0.mountPoint == point }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: NSWorkspace.shared,
                                                   userInfo: [NSWorkspace.volumeURLUserInfoKey: point])
    }

    func mountedShares() -> [MountedShare] { mounted }

    func simulatedListingDelay(for url: URL) -> TimeInterval {
        guard let share = mounted.first(where: { $0.contains(url) }), let host = share.address?.host else { return 0 }
        return behaviour(of: host).slowListing ?? 0
    }
}

enum FakeNetworkCleanup {
    nonisolated(unsafe) static var path: String?
}

final class FakeDiscovery: NetworkDiscovering {
    private(set) var services: Set<DiscoveredService> = []
    private(set) var state: DiscoveryState = .idle
    var onChange: (() -> Void)?
    private weak var source: FakeNetworkServices?

    init(services: FakeNetworkServices) { source = services }

    func start() {
        state = .searching
        if Automation.environment["ARBOR_FAKE_NETWORK_DENIED"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.state = .needsPermission
                self?.onChange?()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.state == .searching else { return }
            self.services = self.source?.discoveredServices() ?? []
            self.state = .ready
            self.onChange?()
        }
    }

    func stop() { state = .idle }
}
