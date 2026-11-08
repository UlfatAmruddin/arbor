import AppKit
import ArborCore
import Network
import NetFS
import dnssd

// MARK: - Protocols (live implementations below, fakes in FakeNetwork.swift)

/// What can go wrong talking to a server, in Explorer's plain terms (FE-176, spec §16.1).
enum NetworkError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case authenticationFailed(String)
    case timedOut(String)
    case cancelled
    case noShares(String)
    case busy(String)
    case listingUnsupported(String)
    case localNetworkDenied
    case failed(String, code: Int)

    var errorDescription: String? {
        switch self {
        case .unreachable(let what):
            return L10n.format("Arbor can't reach %@. The computer may be turned off, asleep, or not on this network, or the name may be misspelled.", "\(what)")
        case .authenticationFailed(let what):
            return L10n.format("%@ didn't accept the user name or password. Try again with different credentials.", "\(what)")
        case .timedOut(let what):
            return L10n.format("%@ didn't respond in time. It may be busy, asleep, or on a slow connection.", "\(what)")
        case .cancelled:
            return L10n.tr("The connection was cancelled.")
        case .noShares(let what):
            return L10n.format("%@ has no shared folders you can open.", "\(what)")
        case .busy(let what):
            return L10n.format("“%@” is in use. Close any files, folders or apps that use it, then try again.", "\(what)")
        case .listingUnsupported(let what):
            return L10n.format("Arbor can't list the shared folders on %@ by itself. Use Connect… to choose a shared folder.", "\(what)")
        case .localNetworkDenied:
            return L10n.tr("Arbor isn't allowed to look for computers on your network.")
        case .failed(let message, let code):
            return code == 0 ? message : "\(message) (error \(code))"
        }
    }

    var isAuthentication: Bool { if case .authenticationFailed = self { return true }; return false }
}

/// Lets slow work be abandoned.
final class NetworkCancellable {
    private var onCancel: (() -> Void)?
    private(set) var isCancelled = false
    init(_ onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

enum DiscoveryState: Equatable {
    case idle, searching, ready
    /// Local Network privacy blocks Bonjour (macOS 15+); the user must allow it in System Settings.
    case needsPermission
    case failed(String)
}

/// Finds computers and devices with Bonjour (FE-078). Runs only while the Network page is shown.
protocol NetworkDiscovering: AnyObject {
    var services: Set<DiscoveredService> { get }
    var state: DiscoveryState { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

struct MountOptions {
    /// "Connect using different credentials": always show the sign-in prompt and start a new session.
    var differentCredentials = false
    /// Allow the system sign-in prompt. Off for silent reconnects (Keychain only).
    var allowUI = true
}

protocol NetworkServicing: AnyObject {
    /// Creates a discovery session (one per Network page).
    func makeDiscovery() -> NetworkDiscovering
    /// Finds the host name to connect to for a discovered device.
    func resolve(_ device: NetworkDevice, completion: @escaping (NetworkAddress?) -> Void)
    /// Lists a server's shared folders.
    @discardableResult
    func listShares(on server: NetworkAddress, completion: @escaping (Result<[NetworkShareInfo], NetworkError>) -> Void) -> NetworkCancellable
    /// Mounts a share (or, for a server, lets the system ask which share). Completes with the mount points.
    @discardableResult
    func mount(_ address: NetworkAddress, options: MountOptions, completion: @escaping (Result<[URL], NetworkError>) -> Void) -> NetworkCancellable
    /// Unmounts; `force` closes files that are still open.
    func unmount(_ mountPoint: URL, force: Bool, completion: @escaping (Result<Void, NetworkError>) -> Void)
    /// Mounted network shares, from the mount table only (safe on the main thread: no network I/O).
    func mountedShares() -> [MountedShare]
    /// Extra delay for listing a folder (fakes only; simulates a slow share).
    func simulatedListingDelay(for url: URL) -> TimeInterval
}

// MARK: - Live

final class LiveNetworkServices: NetworkServicing {
    func makeDiscovery() -> NetworkDiscovering { BonjourDiscovery() }

    func resolve(_ device: NetworkDevice, completion: @escaping (NetworkAddress?) -> Void) {
        guard let type = device.serviceTypes.first(where: { NetworkDiscoveryModel.fileServiceTypes.contains($0) }),
              let scheme = device.preferredScheme else { completion(nil); return }
        let preferred = device.serviceTypes.contains("_smb._tcp") ? "_smb._tcp" : type
        BonjourResolver.resolve(name: device.name, type: preferred) { host, port in
            guard let host else { completion(nil); return }
            let defaultPort = scheme == "smb" ? 445 : 548
            completion(NetworkAddress(scheme: scheme, host: host, port: port == defaultPort ? nil : port))
        }
    }

    @discardableResult
    func listShares(on server: NetworkAddress, completion: @escaping (Result<[NetworkShareInfo], NetworkError>) -> Void) -> NetworkCancellable {
        guard server.scheme == "smb" else {
            completion(.failure(.listingUnsupported(server.unc)))
            return NetworkCancellable()
        }
        // macOS's own SMB client lists shares; -N never prompts (it uses the Keychain), so this never blocks on input.
        // Arguments are passed as an array: the host name is never interpreted by a shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        var target = "//"
        if let user = server.user { target += (user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user) + "@" }
        target += server.host + (server.port.map { ":\($0)" } ?? "")
        process.arguments = ["view", "-N", target]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let token = NetworkCancellable { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { if !token.isCancelled { completion(.failure(.failed("Arbor couldn't run smbutil.", code: 0))) } }
                return
            }
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                if status == 0 {
                    let shares = SMBShareListParser.parse(output).filter { !$0.isHidden }
                    completion(.success(shares))
                } else {
                    completion(.failure(Self.smbutilError(errors, server: server)))
                }
            }
        }
        return token
    }

    static func smbutilError(_ text: String, server: NetworkAddress) -> NetworkError {
        let lower = text.lowercased()
        if lower.contains("authentication") || lower.contains("permission") || lower.contains("password") {
            return .authenticationFailed(server.unc)
        }
        if lower.contains("timed out") { return .timedOut(server.unc) }
        return .unreachable(server.unc)
    }

    @discardableResult
    func mount(_ address: NetworkAddress, options: MountOptions, completion: @escaping (Result<[URL], NetworkError>) -> Void) -> NetworkCancellable {
        let target = address.shareRoot ?? address.server.withUser(address.user)
        let open = NSMutableDictionary()
        open["UIOption"] = options.allowUI && SystemOpen.allowsSystemDialogs ? (options.differentCredentials ? "ForceUI" : "AllowUI") : "NoUI"
        if options.differentCredentials { open["ForceNewSession"] = true }
        let mountOptions = NSMutableDictionary()
        var requestID: AsyncRequestID?
        let what = target.unc
        let status = NetFSMountURLAsync(target.url as CFURL, nil, nil, nil, open as CFMutableDictionary, mountOptions as CFMutableDictionary,
                                        &requestID, DispatchQueue.main) { status, _, mountpoints in
            if status == 0 {
                let paths = (mountpoints as? [String]) ?? []
                completion(.success(paths.map { URL(fileURLWithPath: $0) }))
            } else {
                completion(.failure(Self.mountError(status, what: what)))
            }
        }
        if status != 0 {
            DispatchQueue.main.async { completion(.failure(Self.mountError(status, what: what))) }
            return NetworkCancellable()
        }
        return NetworkCancellable { if let requestID { NetFSMountURLCancel(requestID) } }
    }

    /// NetFS status codes (NetFS.h): POSIX errors, or negative OSStatus values.
    static func mountError(_ status: Int32, what: String) -> NetworkError {
        switch status {
        case -128, ECANCELED: return .cancelled
        case EAUTH, EACCES, EPERM, -5045, -5046, -5999, -6004: return .authenticationFailed(what)
        case ETIMEDOUT: return .timedOut(what)
        case EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ECONNREFUSED, ENOENT, -6602: return .unreachable(what)
        case -5998, -6003: return .noShares(what)
        default: return .failed("Arbor couldn't connect to \(what).", code: Int(status))
        }
    }

    func unmount(_ mountPoint: URL, force: Bool, completion: @escaping (Result<Void, NetworkError>) -> Void) {
        let name = mountPoint.lastPathComponent
        if force {
            let path = mountPoint.path
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Darwin.unmount(path, MNT_FORCE)
                let code = errno
                DispatchQueue.main.async {
                    completion(result == 0 ? .success(()) : .failure(code == EBUSY ? .busy(name) : .failed("Arbor couldn't disconnect “\(name)”.", code: Int(code))))
                }
            }
            return
        }
        FileManager.default.unmountVolume(at: mountPoint, options: [.withoutUI]) { error in
            DispatchQueue.main.async {
                guard let error else { completion(.success(())); return }
                completion(.failure(Self.isBusy(error) ? .busy(name) : .failed(error.localizedDescription, code: 0)))
            }
        }
    }

    static func isBusy(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EBUSY) { return true }
        if ns.localizedDescription.lowercased().contains("in use") || ns.localizedDescription.lowercased().contains("busy") { return true }
        return ns.underlyingErrors.contains { isBusy($0) }
    }

    func mountedShares() -> [MountedShare] { MountTable.networkShares() }

    func simulatedListingDelay(for url: URL) -> TimeInterval { 0 }
}

/// The kernel's mount table via getmntinfo(MNT_NOWAIT): no file system is contacted, so a hung
/// server can't block the caller.
enum MountTable {
    static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "cifs"]

    static func networkShares() -> [MountedShare] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var result: [MountedShare] = []
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let isLocal = (entry.f_flags & UInt32(MNT_LOCAL)) != 0
            guard networkTypes.contains(type) || (!isLocal && type != "autofs" && type != "devfs") else { continue }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let url = URL(fileURLWithPath: on)
            result.append(MountedShare(mountPoint: url, address: NetworkAddress.fromMountSource(from, fileSystem: type),
                                       volumeName: url.lastPathComponent, fileSystem: type))
        }
        return result
    }
}

// MARK: - Bonjour

/// Browses `_smb._tcp`, `_afpovertcp._tcp` and `_airport._tcp` with NWBrowser.
final class BonjourDiscovery: NetworkDiscovering {
    private(set) var services: Set<DiscoveredService> = []
    private(set) var state: DiscoveryState = .idle
    var onChange: (() -> Void)?
    private var browsers: [NWBrowser] = []
    private var resultsByType: [String: Set<DiscoveredService>] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        state = .searching
        for type in NetworkDiscoveryModel.fileServiceTypes + NetworkDiscoveryModel.infrastructureServiceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: NWParameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let found = results.compactMap { result -> DiscoveredService? in
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        return DiscoveredService(name: name, type: type.hasSuffix(".") ? String(type.dropLast()) : type, domain: domain)
                    }
                    return nil
                }
                self?.update(type, Set(found))
            }
            browser.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        state = .idle
    }

    deinit { browsers.forEach { $0.cancel() } }

    private func update(_ type: String, _ found: Set<DiscoveredService>) {
        resultsByType[type] = found
        services = resultsByType.values.reduce(into: Set()) { $0.formUnion($1) }
        if state == .searching { state = .ready }
        onChange?()
    }

    private func handle(_ newState: NWBrowser.State) {
        switch newState {
        case .ready:
            if state == .searching || state == .idle { state = .ready }
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied { state = .needsPermission }
            else if case .failed = newState { state = .failed(error.localizedDescription) }
        default:
            return
        }
        onChange?()
    }
}

/// Resolves a Bonjour service name to its host name (`NAS-01.local.`) with DNSServiceResolve.
enum BonjourResolver {
    private final class Box {
        let completion: (String?, Int?) -> Void
        var ref: DNSServiceRef?
        var done = false
        init(_ completion: @escaping (String?, Int?) -> Void) { self.completion = completion }
        func finish(_ host: String?, _ port: Int?) {
            guard !done else { return }
            done = true
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            completion(host, port)
        }
    }

    private static var active: [ObjectIdentifier: Box] = [:]

    static func resolve(name: String, type: String, timeout: TimeInterval = 5, completion: @escaping (String?, Int?) -> Void) {
        let box = Box(completion)
        let key = ObjectIdentifier(box)
        active[key] = box
        let context = Unmanaged.passUnretained(box).toOpaque()
        var ref: DNSServiceRef?
        let callback: DNSServiceResolveReply = { _, _, _, error, _, host, port, _, _, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            let name = (error == kDNSServiceErr_NoError && host != nil) ? String(cString: host!) : nil
            box.finish(name, Int(UInt16(bigEndian: port)))
            BonjourResolver.active[ObjectIdentifier(box)] = nil
        }
        let status = DNSServiceResolve(&ref, 0, 0, name, type, "local.", callback, context)
        guard status == kDNSServiceErr_NoError, let ref else {
            active[key] = nil
            completion(nil, nil)
            return
        }
        box.ref = ref
        DNSServiceSetDispatchQueue(ref, .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard let box = active[key] else { return }
            box.finish(nil, nil)
            active[key] = nil
        }
    }
}
