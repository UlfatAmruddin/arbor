import Foundation
import Testing
@testable import ArborCore

@Suite("Network addresses (FE-014, FE-187)")
struct NetworkAddressTests {
    @Test func uncAndSMBAgree() throws {
        let unc = try #require(NetworkAddress.parse(#"\\NAS-01\Media\Movies 2026"#))
        let smb = try #require(NetworkAddress.parse("smb://NAS-01/Media/Movies%202026"))
        #expect(unc == smb)
        #expect(unc.host == "NAS-01")
        #expect(unc.share == "Media")
        #expect(unc.path == ["Movies 2026"])
        #expect(unc.unc == #"\\NAS-01\Media\Movies 2026"#)
        #expect(unc.url.absoluteString == "smb://NAS-01/Media/Movies%202026")
    }

    @Test func serverAlone() throws {
        let a = try #require(NetworkAddress.parse(#"\\nas"#))
        #expect(a.isServer)
        #expect(a.url.absoluteString == "smb://nas")
        #expect(NetworkAddress.parse(#"\\nas\"#)?.isServer == true)
        #expect(NetworkAddress.parse("smb://nas")?.isServer == true)
        #expect(NetworkAddress.parse("//nas/share")?.share == "share")
    }

    @Test func pathResolverAcceptsServerOnlyUNC() {
        #expect(PathResolver().resolve(#"\\nas"#, relativeTo: nil) == .success(.network(URL(string: "smb://nas")!)))
        #expect(PathResolver().resolve(#"\\"#, relativeTo: nil) == .failure(.invalidAddress(#"\\"#)))
        #expect(PathResolver().resolve(#"\\bad host\x"#, relativeTo: nil) == .failure(.invalidAddress(#"\\bad host\x"#)))
    }

    @Test func passwordsAreNeverKept() throws {
        let a = try #require(NetworkAddress.parse("smb://alice:s3cret@nas/share"))
        #expect(a.user == "alice")
        #expect(!a.url.absoluteString.contains("s3cret"))
        let data = try JSONEncoder().encode(a)
        #expect(!String(decoding: data, as: UTF8.self).contains("s3cret"))
    }

    @Test func otherSchemes() {
        #expect(NetworkAddress.parse("afp://oldmac/Shared")?.scheme == "afp")
        #expect(NetworkAddress.parse("cifs://pc/share")?.scheme == "smb")
        #expect(NetworkAddress.parse("http://example.com") == nil)
        #expect(NetworkAddress.parse("/Users") == nil)
    }

    @Test func driveLabelHasNoLetter() {
        let a = NetworkAddress(host: "nas.local", share: "Media")
        #expect(a.driveLabel == #"Media (\\nas)"#)
    }

    @Test func identityIgnoresCaseNotServer() {
        let a = NetworkAddress(host: "NAS", share: "Public")
        #expect(a.sameShare(as: NetworkAddress(host: "nas.", share: "public")))
        #expect(!a.sameShare(as: NetworkAddress(host: "office-pc", share: "Public")))
        #expect(!a.sameShare(as: NetworkAddress(host: "NAS", share: "Public2")))
        #expect(!a.sameShare(as: NetworkAddress(host: "NAS", port: 1445, share: "Public")))
        #expect(!a.sameShare(as: NetworkAddress(scheme: "afp", host: "NAS", share: "Public")))
    }

    @Test func accountsMustMatchWhenBothKnown() {
        let alice = NetworkAddress(host: "nas", user: "alice", share: "Home")
        #expect(alice.sameShare(as: NetworkAddress(host: "nas", user: "WORKGROUP;Alice", share: "home")))
        #expect(!alice.sameShare(as: NetworkAddress(host: "nas", user: "bob", share: "Home")))
        #expect(alice.sameShare(as: NetworkAddress(host: "nas", share: "Home")))
    }

    @Test func mountTableSources() {
        let smb = NetworkAddress.fromMountSource("//alice@NAS-01._smb._tcp.local/Media%20Files", fileSystem: "smbfs")
        #expect(smb?.host == "NAS-01._smb._tcp.local")
        #expect(smb?.user == "alice")
        #expect(smb?.share == "Media Files")
        #expect(NetworkAddress.fromMountSource("//nas:1445/share", fileSystem: "smbfs")?.port == 1445)
        #expect(NetworkAddress.fromMountSource("//GUEST:@nas/Public", fileSystem: "smbfs")?.share == "Public")
        #expect(NetworkAddress.fromMountSource("files:/export/home", fileSystem: "nfs")?.share == "export")
        #expect(NetworkAddress.fromMountSource("/dev/disk3s1", fileSystem: "apfs") == nil)
    }

    @Test func mountedShareAddressesFolders() {
        let share = MountedShare(mountPoint: URL(fileURLWithPath: "/Volumes/Media"), address: NetworkAddress(host: "nas", share: "Media"),
                                 volumeName: "Media", fileSystem: "smbfs")
        #expect(share.contains(URL(fileURLWithPath: "/Volumes/Media")))
        #expect(share.contains(URL(fileURLWithPath: "/Volumes/Media/a/b")))
        #expect(!share.contains(URL(fileURLWithPath: "/Volumes/Media-1")))
        #expect(share.address(of: URL(fileURLWithPath: "/Volumes/Media/a/b"))?.unc == #"\\nas\Media\a\b"#)
    }
}

@Suite("Server locations (FE-078)")
struct ServerLocationTests {
    @Test func keysRoundTrip() {
        let locations: [Location] = [.server(NetworkAddress(host: "nas")), .server(NetworkAddress(host: "nas", share: "Media", path: ["a b", "c&d"])),
                                     .server(NetworkAddress(scheme: "afp", host: "oldmac.local", user: "bob", share: "Shared"))]
        for location in locations {
            #expect(Location(key: location.key) == location)
        }
    }

    @Test func parentsWalkUpToNetwork() {
        let folder = Location.server(NetworkAddress(host: "nas", share: "Media", path: ["Movies"]))
        #expect(folder.parent() == .server(NetworkAddress(host: "nas", share: "Media")))
        #expect(Location.server(NetworkAddress(host: "nas", user: "a", share: "Media")).parent() == .server(NetworkAddress(host: "nas")))
        #expect(Location.server(NetworkAddress(host: "nas")).parent() == .network)
    }

    @Test func displayNames() {
        #expect(Location.server(NetworkAddress(host: "nas.local")).displayName == "nas")
        #expect(Location.server(NetworkAddress(host: "nas", share: "Media")).displayName == "Media")
        #expect(Location.server(NetworkAddress(host: "nas", share: "Media", path: ["Movies"])).displayName == "Movies")
    }
}

@Suite("Mapped drives (FE-177, FE-187)")
struct MappedDriveTests {
    func mounted(_ host: String, _ share: String, at path: String, user: String? = nil, uuid: String? = nil) -> MountedShare {
        MountedShare(mountPoint: URL(fileURLWithPath: path), address: NetworkAddress(host: host, user: user, share: share),
                     volumeName: share, fileSystem: "smbfs", volumeUUID: uuid)
    }

    @Test func sameShareNameOnTwoServersNeverCrosses() {
        var list = MappedDriveList()
        let nas = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Public")))
        let pc = list.add(MappedDrive(address: NetworkAddress(host: "office-pc", share: "Public")))
        // The system named the second mount "Public-1"; the names say nothing about which is which.
        let shares = [mounted("office-pc", "Public", at: "/Volumes/Public"), mounted("nas", "Public", at: "/Volumes/Public-1")]
        let match = list.match(shares)
        #expect(match[nas.id]?.mountPoint.path == "/Volumes/Public-1")
        #expect(match[pc.id]?.mountPoint.path == "/Volumes/Public")
    }

    @Test func displayNameAloneIsNotAMatch() {
        var list = MappedDriveList()
        let drive = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Media")))
        let lookalike = MountedShare(mountPoint: URL(fileURLWithPath: "/Volumes/Media"), address: nil, volumeName: "Media", fileSystem: "smbfs")
        #expect(list.match([lookalike])[drive.id] == nil)
        #expect(list.match([mounted("other", "Media", at: "/Volumes/Media")])[drive.id] == nil)
    }

    @Test func volumeUUIDWinsWhenBothKnown() {
        var list = MappedDriveList()
        let drive = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Media"), volumeUUID: "AAAA"))
        #expect(list.match([mounted("nas", "Media", at: "/Volumes/Media", uuid: "BBBB")])[drive.id] == nil)
        #expect(list.match([mounted("nas-renamed", "Media", at: "/Volumes/Media", uuid: "AAAA")])[drive.id] != nil)
        #expect(list.match([mounted("nas", "Media", at: "/Volumes/Media")])[drive.id] != nil)
    }

    @Test func accountIsPartOfIdentity() {
        var list = MappedDriveList()
        let alice = list.add(MappedDrive(address: NetworkAddress(host: "nas", user: "alice", share: "Home")))
        let bob = list.add(MappedDrive(address: NetworkAddress(host: "nas", user: "bob", share: "Home")))
        #expect(alice.id != bob.id)
        let match = list.match([mounted("nas", "Home", at: "/Volumes/Home", user: "bob")])
        #expect(match[alice.id] == nil)
        #expect(match[bob.id] != nil)
    }

    @Test func addingTheSameShareUpdates() {
        var list = MappedDriveList()
        let first = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Media"), reconnectAtSignIn: true))
        let again = list.add(MappedDrive(address: NetworkAddress(host: "NAS", share: "media"), reconnectAtSignIn: false))
        #expect(list.drives.count == 1)
        #expect(again.id == first.id)
        #expect(list.drives[0].reconnectAtSignIn == false)
    }

    @Test func persistenceRoundTripsAndDropsSessionMappings() {
        var list = MappedDriveList()
        list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Media"), reconnectAtSignIn: true, lastMountPoint: "/Volumes/Media"))
        list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Temp"), reconnectAtSignIn: false))
        var decoded = MappedDriveList.decode(list.encoded())
        #expect(decoded == list)
        decoded.dropSessionOnly()
        #expect(decoded.drives.map(\.address.share) == ["Media"])
        #expect(MappedDriveList.decode(Data("garbage".utf8)).drives.isEmpty)
        #expect(MappedDriveList.decode(nil).drives.isEmpty)
    }

    @Test func reconnectPolicy() {
        var list = MappedDriveList()
        let media = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Media")))
        let temp = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Temp"), reconnectAtSignIn: false))
        let backups = list.add(MappedDrive(address: NetworkAddress(host: "nas", share: "Backups")))
        var policy = ReconnectPolicy(minimumInterval: 60)
        let launch = policy.atLaunch(list, mounted: [mounted("nas", "Backups", at: "/Volumes/Backups")])
        #expect(launch.map(\.id) == [media.id])
        let t0 = Date()
        let first = policy.shouldReconnect(media, userDisconnected: false, now: t0)
        let tooSoon = policy.shouldReconnect(media, userDisconnected: false, now: t0.addingTimeInterval(5))
        let later = policy.shouldReconnect(media, userDisconnected: false, now: t0.addingTimeInterval(61))
        let userChoice = policy.shouldReconnect(backups, userDisconnected: true, now: t0)
        let sessionOnly = policy.shouldReconnect(temp, userDisconnected: false, now: t0)
        #expect(first && !tooSoon && later)
        #expect(!userChoice)
        #expect(!sessionOnly)
    }
}

@Suite("Network discovery and shares (FE-078, FE-176)")
struct NetworkDiscoveryTests {
    @Test func smbutilViewOutput() {
        let output = """
        Share                                           Type    Comments
        -------------------------------
        Media Files                                     Disk    Films and music
        IPC$                                            Pipe    Remote IPC
        C$                                              Disk    Default share
        Laser                                           Printer
        backups                                         Disk

        4 shares listed
        """
        let shares = SMBShareListParser.parse(output)
        #expect(shares.map(\.name) == ["backups", "C$", "Media Files"])
        #expect(shares.first { $0.name == "Media Files" }?.comment == "Films and music")
        #expect(shares.first { $0.name == "C$" }?.isHidden == true)
        #expect(SMBShareListParser.parse("smbutil: server rejected the connection: Authentication error").isEmpty)
    }

    @Test func devicesMergeByNameAndGroup() {
        let services: Set<DiscoveredService> = [
            DiscoveredService(name: "NAS-01", type: "_smb._tcp"),
            DiscoveredService(name: "nas-01", type: "_afpovertcp._tcp"),
            DiscoveredService(name: "Office PC 10", type: "_smb._tcp"),
            DiscoveredService(name: "Office PC 9", type: "_smb._tcp"),
            DiscoveredService(name: "Base Station", type: "_airport._tcp"),
        ]
        let devices = NetworkDiscoveryModel.devices(from: services)
        #expect(devices.map(\.name) == ["NAS-01", "Office PC 9", "Office PC 10", "Base Station"])
        #expect(devices[0].protocols == ["AFP", "SMB"])
        #expect(devices[0].preferredScheme == "smb")
        #expect(devices[3].category == .infrastructure)
        #expect(devices[3].preferredScheme == nil)
    }

    @Test func fileSystemCapabilities() {
        #expect(FileSystemCapabilities(typeName: "msdos", isReadOnly: false).maximumFileSize == 4_294_967_295)
        #expect(FileSystemCapabilities(typeName: "ntfs", isReadOnly: true).notes.first == "macOS can read NTFS drives but can't write to them.")
        #expect(FileSystemCapabilities(typeName: "apfs", isReadOnly: false).notes.isEmpty)
        #expect(FileSystemCapabilities(typeName: "smbfs", isReadOnly: false).isNetwork)
        #expect(FileSystemCapabilities(typeName: "hfs", isReadOnly: false).displayName == "Mac OS Extended")
        #expect(!FileSystemCapabilities(typeName: "exfat", isReadOnly: true).canWrite)
    }
}

@Suite("Slow network work (FE-179)")
struct SlowWorkTests {
    @Test func timesOutWithoutWaitingForTheWork() async {
        let queue = SlowWorkQueue<Int>(label: "test.slow", callbackQueue: DispatchQueue(label: "test.callbacks"))
        let workDone = NetworkCallCounter()
        let result: (outcome: String, workFinishedFirst: Bool) = await withCheckedContinuation { continuation in
            queue.run(key: "a", timeout: 0.2, work: { Thread.sleep(forTimeInterval: 4.0); workDone.bump(); return 1 }) { outcome in
                let finished = workDone.value > 0
                if case .timedOut = outcome { continuation.resume(returning: ("timeout", finished)) }
                else { continuation.resume(returning: ("done", finished)) }
            }
        }
        // The caller must hear "timed out" before the slow work ends. Ordering, not wall-clock time,
        // is checked: on a loaded CI machine parallel tests can delay any callback by seconds.
        #expect(result.outcome == "timeout")
        #expect(!result.workFinishedFirst)
    }

    @Test func lateResultAndSharedJob() async {
        let queue = SlowWorkQueue<Int>(label: "test.slow2", callbackQueue: DispatchQueue(label: "test.callbacks2"))
        let counter = NetworkCallCounter()
        let late: Int = await withCheckedContinuation { continuation in
            queue.run(key: "share", timeout: 0.1, work: { counter.bump(); Thread.sleep(forTimeInterval: 0.5); return 7 },
                      late: { continuation.resume(returning: $0) }) { _ in }
            // A retry while the first is still hung joins it instead of starting a second read.
            queue.run(key: "share", timeout: 5, work: { counter.bump(); return 9 }) { _ in }
        }
        #expect(late == 7)
        #expect(counter.value == 1)
    }

    @Test func fastWorkFinishes() async {
        let queue = SlowWorkQueue<Int>(label: "test.fast", callbackQueue: DispatchQueue(label: "test.callbacks3"))
        let value: Int = await withCheckedContinuation { continuation in
            queue.run(key: "a", timeout: 5, work: { 42 }) { outcome in
                if case .finished(let v) = outcome { continuation.resume(returning: v) } else { continuation.resume(returning: -1) }
            }
        }
        #expect(value == 42)
    }
}

final class NetworkCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
