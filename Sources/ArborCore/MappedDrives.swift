import Foundation

/// A mounted network share as the mount table reports it (no network I/O to obtain).
public struct MountedShare: Hashable, Sendable {
    /// Where the share is mounted (`/Volumes/Media`).
    public var mountPoint: URL
    /// Who it came from (server, share, account), when the file system reports it.
    public var address: NetworkAddress?
    /// Volume name shown by the system ("Media", "Media-1"…). Never used as identity.
    public var volumeName: String
    /// `smbfs`, `afpfs`, `nfs`, `webdav`…
    public var fileSystem: String
    /// The volume's UUID, when the file system has one (FE-187 stable identity).
    public var volumeUUID: String?

    public init(mountPoint: URL, address: NetworkAddress?, volumeName: String, fileSystem: String, volumeUUID: String? = nil) {
        self.mountPoint = mountPoint.standardizedFileURL
        self.address = address
        self.volumeName = volumeName
        self.fileSystem = fileSystem
        self.volumeUUID = volumeUUID
    }

    /// True when `url` is the mount point or inside it.
    public func contains(_ url: URL) -> Bool {
        let root = Self.normalized(mountPoint.path)
        let path = Self.normalized(url.standardizedFileURL.path)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// The share address of a folder inside this mount (`\\host\share\a\b`).
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

/// A "Map network drive" record (FE-177). It holds the share's identity and reconnect intent only:
/// passwords live in the Keychain, never here (FE-178).
public struct MappedDrive: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Server + share (+ account). Folders below the share are allowed, like `\\server\share\folder`.
    public var address: NetworkAddress
    /// "Reconnect at sign-in": reconnect when Arbor starts. Off means the mapping lasts for this session.
    public var reconnectAtSignIn: Bool
    /// The user chose "Connect using different credentials" (always show the sign-in prompt).
    public var usesDifferentCredentials: Bool
    /// Volume UUID captured at the last successful mount, when the file system reports one.
    public var volumeUUID: String?
    /// Where it was last mounted; used to keep tabs on it while disconnected. Not an identity.
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

    /// Whether `share` is this drive (FE-187). A volume UUID decides when both sides have one;
    /// otherwise server + share (+ account when both name one). The volume name is never consulted.
    public func matches(_ share: MountedShare) -> Bool {
        if let mine = volumeUUID, let theirs = share.volumeUUID { return mine == theirs }
        guard let mounted = share.address, let root = address.shareRoot else { return false }
        return root.sameShare(as: mounted)
    }
}

/// The saved list of mapped drives, independent of storage (unit-tested).
public struct MappedDriveList: Codable, Equatable, Sendable {
    public private(set) var drives: [MappedDrive]

    public init(drives: [MappedDrive] = []) { self.drives = drives }

    /// Adds a mapping, or updates the existing one for the same share and account (no duplicates).
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

    /// Session-only mappings (Reconnect at sign-in off) are dropped when the app starts again.
    public mutating func dropSessionOnly() { drives.removeAll { !$0.reconnectAtSignIn } }

    /// Pairs each drive with the mounted share that is it, if any. A mounted share is assigned to at
    /// most one drive, so two servers exporting "Public" never cross (FE-187).
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

/// Decides when to reconnect a mapped drive by itself (FE-177): at launch for "Reconnect at sign-in"
/// drives, and once after a drive disappears without the user disconnecting it. Never in a loop.
public struct ReconnectPolicy: Sendable {
    public var minimumInterval: TimeInterval
    private var lastAttempt: [UUID: Date] = [:]

    public init(minimumInterval: TimeInterval = 60) { self.minimumInterval = minimumInterval }

    /// Drives to reconnect when the app starts.
    public func atLaunch(_ list: MappedDriveList, mounted: [MountedShare]) -> [MappedDrive] {
        let connected = list.match(mounted)
        return list.drives.filter { $0.reconnectAtSignIn && connected[$0.id] == nil }
    }

    /// Whether to try again after `drive` vanished. `userDisconnected` drives are left alone.
    public mutating func shouldReconnect(_ drive: MappedDrive, userDisconnected: Bool, now: Date = Date()) -> Bool {
        guard drive.reconnectAtSignIn, !userDisconnected else { return false }
        if let last = lastAttempt[drive.id], now.timeIntervalSince(last) < minimumInterval { return false }
        lastAttempt[drive.id] = now
        return true
    }
}
