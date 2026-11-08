import Foundation

/// A mounted network share from the mount table (no network I/O).
public struct MountedShare: Hashable, Sendable {
    public var mountPoint: URL
    /// Server, share and account, when the file system reports it.
    public var address: NetworkAddress?
    /// "Media", "Media-1"… Never used as identity.
    public var volumeName: String
    /// `smbfs`, `afpfs`, `nfs`, `webdav`…
    public var fileSystem: String
    /// Stable identity when the file system has one (FE-187).
    public var volumeUUID: String?

    public init(mountPoint: URL, address: NetworkAddress?, volumeName: String, fileSystem: String, volumeUUID: String? = nil) {
        self.mountPoint = mountPoint.standardizedFileURL
        self.address = address
        self.volumeName = volumeName
        self.fileSystem = fileSystem
        self.volumeUUID = volumeUUID
    }

    public func contains(_ url: URL) -> Bool {
        let root = Self.normalized(mountPoint.path)
        let path = Self.normalized(url.standardizedFileURL.path)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// `\\host\share\a\b` for a folder inside this mount.
    public func address(of url: URL) -> NetworkAddress? {
        guard var address, contains(url) else { return nil }
        let root = Self.normalized(mountPoint.path)
        let rest = Self.normalized(url.standardizedFileURL.path).dropFirst(root.count)
        address.path += rest.split(separator: "/").map(String.init)
        return address
    }

    static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// A "Map network drive" record (FE-177). Passwords live in the Keychain, never here (FE-178).
public struct MappedDrive: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// May include folders below the share, like `\\server\share\folder`.
    public var address: NetworkAddress
    /// Off means the mapping lasts for this session only.
    public var reconnectAtSignIn: Bool
    /// Always show the sign-in prompt.
    public var usesDifferentCredentials: Bool
    /// From the last successful mount.
    public var volumeUUID: String?
    /// Keeps tabs on it while disconnected. Not an identity.
    public var lastMountPoint: String?
    public var created: Date

    public init(id: UUID = UUID(), address: NetworkAddress, reconnectAtSignIn: Bool = true, usesDifferentCredentials: Bool = false,
                volumeUUID: String? = nil, lastMountPoint: String? = nil, created: Date = Date()) {
        self.id = id
        self.address = address
        self.reconnectAtSignIn = reconnectAtSignIn
        self.usesDifferentCredentials = usesDifferentCredentials
        self.volumeUUID = volumeUUID
        self.lastMountPoint = lastMountPoint
        self.created = created
    }

    public var label: String { address.driveLabel }

    /// FE-187: volume UUID when both have one, else server + share (+ account). Never the volume name.
    public func matches(_ share: MountedShare) -> Bool {
        if let mine = volumeUUID, let theirs = share.volumeUUID { return mine == theirs }
        guard let mounted = share.address, let root = address.shareRoot else { return false }
        return root.sameShare(as: mounted)
    }
}

/// The saved list of mapped drives, independent of storage.
public struct MappedDriveList: Codable, Equatable, Sendable {
    public private(set) var drives: [MappedDrive]

    public init(drives: [MappedDrive] = []) { self.drives = drives }

    /// Updates the existing mapping for the same share and account instead of duplicating it.
    @discardableResult
    public mutating func add(_ drive: MappedDrive) -> MappedDrive {
        if let index = drives.firstIndex(where: { $0.address.identityKey == drive.address.identityKey && $0.address.path == drive.address.path }) {
            var updated = drive
            updated.id = drives[index].id
            updated.created = drives[index].created
            updated.volumeUUID = drive.volumeUUID ?? drives[index].volumeUUID
            updated.lastMountPoint = drive.lastMountPoint ?? drives[index].lastMountPoint
            drives[index] = updated
            return updated
        }
        drives.append(drive)
        return drive
    }

    public mutating func remove(id: UUID) { drives.removeAll { $0.id == id } }

    public mutating func update(id: UUID, _ change: (inout MappedDrive) -> Void) {
        guard let index = drives.firstIndex(where: { $0.id == id }) else { return }
        change(&drives[index])
    }

    public func drive(id: UUID) -> MappedDrive? { drives.first { $0.id == id } }

    /// Called at launch: session-only mappings don't survive a restart.
    public mutating func dropSessionOnly() { drives.removeAll { !$0.reconnectAtSignIn } }

    /// Each share goes to at most one drive, so two servers exporting "Public" never cross (FE-187).
    public func match(_ mounted: [MountedShare]) -> [UUID: MountedShare] {
        var result: [UUID: MountedShare] = [:]
        var taken = Set<String>()
        // UUID matches first, then address matches.
        for pass in 0..<2 {
            for drive in drives where result[drive.id] == nil {
                for share in mounted where !taken.contains(share.mountPoint.path) {
                    let byUUID = drive.volumeUUID != nil && share.volumeUUID != nil
                    guard (pass == 0) == byUUID, drive.matches(share) else { continue }
                    result[drive.id] = share
                    taken.insert(share.mountPoint.path)
                    break
                }
            }
        }
        return result
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data?) -> MappedDriveList {
        guard let data, let list = try? JSONDecoder().decode(MappedDriveList.self, from: data) else { return MappedDriveList() }
        return list
    }
}

/// Automatic reconnects (FE-177): at launch, and once after a drive vanishes on its own. Never in a loop.
public struct ReconnectPolicy: Sendable {
    public var minimumInterval: TimeInterval
    private var lastAttempt: [UUID: Date] = [:]

    public init(minimumInterval: TimeInterval = 60) { self.minimumInterval = minimumInterval }

    public func atLaunch(_ list: MappedDriveList, mounted: [MountedShare]) -> [MappedDrive] {
        let connected = list.match(mounted)
        return list.drives.filter { $0.reconnectAtSignIn && connected[$0.id] == nil }
    }

    /// At most once per `minimumInterval`; drives the user disconnected are left alone.
    public mutating func shouldReconnect(_ drive: MappedDrive, userDisconnected: Bool, now: Date = Date()) -> Bool {
        guard drive.reconnectAtSignIn, !userDisconnected else { return false }
        if let last = lastAttempt[drive.id], now.timeIntervalSince(last) < minimumInterval { return false }
        lastAttempt[drive.id] = now
        return true
    }
}
