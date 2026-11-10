import Foundation
import Darwin

/// What a destination volume can store besides contents, for Windows' "copy without its properties?" (spec §9.5).
/// - Extended attributes (tags, comments, resource forks, Finder info): `VOL_CAP_INT_EXTENDED_ATTR`. FAT32, exFAT
///   and SMB without named streams lack it; macOS then uses "._" files that other systems ignore or delete.
/// - ACLs: `_PC_EXTENDED_SECURITY_NP` / `volumeSupportsExtendedSecurity`.
public struct VolumeCapabilities: Equatable, Sendable {
    public var nativeExtendedAttributes: Bool
    public var accessControlLists: Bool
    /// "ExFAT", "MS-DOS (FAT32)", "SMB (Network)"…
    public var formatName: String
    public var volumeName: String?

    public init(nativeExtendedAttributes: Bool, accessControlLists: Bool, formatName: String = "", volumeName: String? = nil) {
        self.nativeExtendedAttributes = nativeExtendedAttributes
        self.accessControlLists = accessControlLists
        self.formatName = formatName
        self.volumeName = volumeName
    }

    public static let full = VolumeCapabilities(nativeExtendedAttributes: true, accessControlLists: true)

    public var keepsEverything: Bool { nativeExtendedAttributes && accessControlLists }

    /// Capabilities of `url`'s volume (nearest existing ancestor). Unknown means full support: no needless prompt.
    public static func of(_ url: URL) -> VolumeCapabilities {
        var path = url.standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: path), path != "/" {
            path = (path as NSString).deletingLastPathComponent
        }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return .full }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let values = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey, .volumeLocalizedNameKey,
                                                                              .volumeSupportsExtendedSecurityKey])
        let xattrs = interfaceCapability(mount, UInt32(VOL_CAP_INT_EXTENDED_ATTR)) ?? true
        var acls = values?.volumeSupportsExtendedSecurity ?? true
        let pc = pathconf(mount, _PC_EXTENDED_SECURITY_NP)
        if pc >= 0 { acls = pc == 1 }
        return VolumeCapabilities(nativeExtendedAttributes: xattrs, accessControlLists: acls,
                                  formatName: values?.volumeLocalizedFormatDescription ?? type,
                                  volumeName: values?.volumeLocalizedName)
    }

    /// Reads one bit of the volume's "interfaces" capabilities with getattrlist; nil when unknown.
    static func interfaceCapability(_ mountPoint: String, _ bit: UInt32) -> Bool? {
        struct Buffer {
            var length: UInt32 = 0
            var caps = vol_capabilities_attr_t()
        }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var buffer = Buffer()
        let status = withUnsafeMutablePointer(to: &buffer) {
            getattrlist(mountPoint, &list, $0, MemoryLayout<Buffer>.size, 0)
        }
        guard status == 0 else { return nil }
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        let valid = withUnsafeBytes(of: buffer.caps.valid) { $0.bindMemory(to: UInt32.self)[index] }
        let caps = withUnsafeBytes(of: buffer.caps.capabilities) { $0.bindMemory(to: UInt32.self)[index] }
        guard valid & bit != 0 else { return nil }
        return caps & bit != 0
    }

    /// What of `inventory` this volume can't keep.
    public func losses(_ inventory: MetadataInventory) -> MetadataInventory {
        var lost: MetadataInventory = []
        if !nativeExtendedAttributes { lost.formUnion(inventory.subtracting(.accessList)) }
        if !accessControlLists, inventory.contains(.accessList) { lost.insert(.accessList) }
        return lost
    }
}

/// The kinds of Mac metadata an item carries beyond its contents, permissions and dates.
public struct MetadataInventory: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let tags = MetadataInventory(rawValue: 1)
    public static let comment = MetadataInventory(rawValue: 2)
    public static let resourceFork = MetadataInventory(rawValue: 4)
    public static let finderInfo = MetadataInventory(rawValue: 8)
    public static let otherAttributes = MetadataInventory(rawValue: 16)
    public static let accessList = MetadataInventory(rawValue: 32)

    /// macOS-managed attributes users never see as properties (not asked about).
    public static let systemAttributes: Set<String> = [
        "com.apple.provenance", "com.apple.quarantine", "com.apple.macl", "com.apple.lastuseddate#PS",
        "com.apple.rootless", "com.apple.decmpfs", "com.apple.TextEncoding", "com.apple.metadata:kMDItemDownloadedDate",
    ]

    /// Lists the item's own attributes (links are not followed) and access list.
    public static func of(_ url: URL) -> MetadataInventory {
        var result: MetadataInventory = []
        let path = url.path
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
            if read > 0 {
                let names = buffer.prefix(read).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                for name in names { result.formUnion(classify(name, path: path)) }
            }
        }
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            var entry: acl_entry_t?
            if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 { result.insert(.accessList) }
            acl_free(UnsafeMutableRawPointer(acl))
        }
        return result
    }

    static func classify(_ name: String, path: String) -> MetadataInventory {
        if systemAttributes.contains(name) { return [] }
        switch name {
        case "com.apple.metadata:_kMDItemUserTags": return .tags
        case "com.apple.metadata:kMDItemFinderComment": return .comment
        case "com.apple.ResourceFork": return .resourceFork
        case "com.apple.FinderInfo":
            // Often present but all zero: nothing to lose then.
            var info = [UInt8](repeating: 0, count: 32)
            let n = getxattr(path, name, &info, 32, 0, XATTR_NOFOLLOW)
            return n > 0 && info.prefix(n).contains(where: { $0 != 0 }) ? .finderInfo : []
        default: return .otherAttributes
        }
    }

    /// "Finder tags, comments and an access list", for the dialog.
    public var description: String {
        var parts: [String] = []
        if contains(.tags) { parts.append(L10n.tr("Finder tags")) }
        if contains(.comment) { parts.append(L10n.tr("comments")) }
        if contains(.resourceFork) { parts.append(L10n.tr("a resource fork")) }
        if contains(.finderInfo) { parts.append(L10n.tr("Finder information")) }
        if contains(.otherAttributes) { parts.append(L10n.tr("extended attributes")) }
        if contains(.accessList) { parts.append(L10n.tr("access-list permissions")) }
        return parts.isEmpty ? L10n.tr("properties") : ListFormatter.localizedString(byJoining: parts)
    }
}

/// One item whose properties the destination can't hold.
public struct MetadataLoss: Sendable, Equatable {
    public let source: URL
    public let destination: URL
    public let lost: MetadataInventory
    public let capabilities: VolumeCapabilities

    public init(source: URL, destination: URL, lost: MetadataInventory, capabilities: VolumeCapabilities) {
        self.source = source
        self.destination = destination
        self.lost = lost
        self.capabilities = capabilities
    }
}

/// Yes (copy without them) · Skip · Cancel, with "Do this for all current items".
public enum MetadataLossChoice: Sendable, Equatable { case copyWithout, skip, cancel }

public struct MetadataLossDecision: Sendable, Equatable {
    public var choice: MetadataLossChoice
    public var applyToRemaining: Bool
    public init(_ choice: MetadataLossChoice, applyToRemaining: Bool = false) {
        self.choice = choice
        self.applyToRemaining = applyToRemaining
    }
}
