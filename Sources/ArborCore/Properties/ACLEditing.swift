import Foundation
import Darwin

/// Security tab ACL editing (FE-153) with attribute calls that refuse a link anywhere in the path. Each change
/// keeps the prior list for undo, which refuses if the list changed since. Only the owner or root may edit.
public struct ACLPrincipal: Equatable, Sendable, Hashable {
    public var kind: ACLEntry.Kind
    public var name: String

    public init(_ kind: ACLEntry.Kind, _ name: String) {
        self.kind = kind
        self.name = name
    }

    /// "user:ana" / "group:staff" for chmod(1).
    public var chmodName: String { "\(kind.rawValue):\(name)" }

    public var exists: Bool {
        switch kind {
        case .user: return getpwnam(name) != nil
        case .group: return name == "everyone" || getgrnam(name) != nil
        }
    }
}

/// Explorer's permission levels as acl(3) permissions.
public enum ACLPermissionLevel: String, CaseIterable, Sendable {
    case fullControl, modify, readAndExecute, read, write

    public var title: String {
        switch self {
        case .fullControl: return L10n.tr("Full control")
        case .modify: return L10n.tr("Modify")
        case .readAndExecute: return L10n.tr("Read & execute")
        case .read: return L10n.tr("Read")
        case .write: return L10n.tr("Write")
        }
    }

    public func permissions(isFolder: Bool) -> [String] {
        let readMeta = ["readattr", "readextattr", "readsecurity"]
        let writeMeta = ["writeattr", "writeextattr"]
        if isFolder {
            switch self {
            case .fullControl: return ["list", "add_file", "search", "add_subdirectory", "delete_child", "delete"] + readMeta + writeMeta + ["writesecurity", "chown"]
            case .modify: return ["list", "add_file", "search", "add_subdirectory", "delete_child", "delete"] + readMeta + writeMeta
            case .readAndExecute: return ["list", "search"] + readMeta
            case .read: return ["list"] + readMeta
            case .write: return ["add_file", "add_subdirectory"] + writeMeta
            }
        }
        switch self {
        case .fullControl: return ["read", "write", "append", "execute", "delete"] + readMeta + writeMeta + ["writesecurity", "chown"]
        case .modify: return ["read", "write", "append", "execute", "delete"] + readMeta + writeMeta
        case .readAndExecute: return ["read", "execute"] + readMeta
        case .read: return ["read"] + readMeta
        case .write: return ["write", "append"] + writeMeta
        }
    }
}

public struct ACLRule: Equatable, Sendable {
    public var principal: ACLPrincipal
    public var allow: Bool
    public var level: ACLPermissionLevel
    /// Folders: also applies to new items inside.
    public var inherit: Bool

    public init(principal: ACLPrincipal, allow: Bool, level: ACLPermissionLevel, inherit: Bool = false) {
        self.principal = principal
        self.allow = allow
        self.level = level
        self.inherit = inherit
    }

    /// Never denied: on macOS denying these hides the item from `ls` and locks the owner out of the list.
    public static let neverDenied: Set<String> = ["readattr", "readsecurity", "writesecurity", "chown"]

    public func permissions(isFolder: Bool) -> [String] {
        let all = level.permissions(isFolder: isFolder)
        return allow ? all : all.filter { !Self.neverDenied.contains($0) }
    }

    /// "user:ana allow read,write".
    public func chmodEntry(isFolder: Bool) -> String {
        var perms = permissions(isFolder: isFolder)
        if isFolder, inherit { perms += ["file_inherit", "directory_inherit"] }
        return "\(principal.chmodName) \(allow ? "allow" : "deny") \(perms.joined(separator: ","))"
    }

    /// acl_from_text(3) line; the name is resolved there. Folder names are aliases it doesn't accept.
    public func textEntry(isFolder: Bool) -> String {
        let aliases = ["list": "read", "search": "execute", "add_file": "write", "add_subdirectory": "append"]
        let perms = permissions(isFolder: isFolder).map { aliases[$0] ?? $0 }
        let flags = isFolder && inherit ? ",file_inherit,directory_inherit" : ""
        return "\(principal.kind.rawValue)::\(principal.name)::\(allow ? "allow" : "deny")\(flags):\(perms.joined(separator: ","))"
    }

    public var summary: String {
        "\(allow ? "Allow" : "Deny") \(principal.name) (\(principal.kind == .group ? "group" : "user")): \(level.title)"
            + (inherit ? ", also for new items inside" : "")
    }
}

public enum ACLEditError: Error, LocalizedError, Equatable {
    case notOwner
    case unknownPrincipal(String)
    case changedSinceEdit
    case itemReplaced
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notOwner: return L10n.tr("Only the owner of this item or an administrator can change its permissions.")
        case .unknownPrincipal(let name): return L10n.format("There's no user or group named “%@” on this Mac.", "\(name)")
        case .changedSinceEdit: return L10n.tr("The permissions were changed again after your change, so undoing it could remove someone else's change.")
        case .itemReplaced: return L10n.tr("The item was moved or replaced, or a folder above it became a link, so nothing was changed.")
        case .failed(let text): return text
        }
    }
}

/// The item an editor was opened on: links in the folders above it resolved then, and never followed again.
public struct ACLTarget: Equatable, Sendable {
    public let url: URL
    public let isFolder: Bool
    let path: String
    let device: Int32
    let inode: UInt64
}

public struct ACLChange: Equatable, Sendable {
    public var target: ACLTarget
    public var url: URL { target.url }
    public var before: String?
    public var after: String?
    public var summary: String
}

public enum ACLEditor {
    /// acl_to_text(3) form; nil when there are no entries.
    public static func text(_ url: URL) -> String? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else { return nil }
        guard let cText = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(cText)) }
        return String(cString: cText)
    }

    public static func canEdit(_ url: URL) -> Bool { target(url) != nil }

    /// nil unless the item exists, isn't a link, and is the user's (or the user is root).
    public static func target(_ url: URL) -> ACLTarget? {
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(parent) }
        let path = (String(cString: parent) as NSString).appendingPathComponent(url.lastPathComponent)
        guard let item = state(path), item.type != fsobj_type_t(VLNK.rawValue), item.owner == getuid() || getuid() == 0 else { return nil }
        return ACLTarget(url: url, isFolder: item.type == fsobj_type_t(VDIR.rawValue), path: path, device: item.device, inode: item.inode)
    }

    /// macOS places deny entries before allow entries.
    @discardableResult
    public static func add(_ rule: ACLRule, to target: ACLTarget) throws -> ACLChange {
        guard rule.principal.exists else { throw ACLEditError.unknownPrincipal(rule.principal.name) }
        let before = try current(target)
        var lines = entryLines(before)
        // Canonical order, as chmod +a: explicit denies, explicit allows, then inherited entries.
        let index = lines.firstIndex { line in
            guard let e = ACLEntry.parse(line).first else { return true }
            return e.isInherited || (!rule.allow && e.allow)
        } ?? lines.count
        lines.insert(rule.textEntry(isFolder: target.isFolder), at: index)
        try write(fullText(lines), to: target)
        return ACLChange(target: target, before: before, after: try? current(target), summary: L10n.format("Added: %@", "\(rule.summary)"))
    }

    /// `index` is 0-based, in `ACLEntry.read` order.
    @discardableResult
    public static func remove(at index: Int, from target: ACLTarget) throws -> ACLChange {
        let before = try current(target)
        let entries = ACLEntry.parse(before ?? "")
        var lines = entryLines(before)
        guard entries.indices.contains(index), lines.indices.contains(index) else { throw ACLEditError.failed("That entry isn't there anymore.") }
        lines.remove(at: index)
        try write(fullText(lines), to: target)
        let e = entries[index]
        return ACLChange(target: target, before: before, after: try? current(target),
                         summary: L10n.format("Removed: %@ %@ (%@): %@", "\(e.allow ? "Allow" : "Deny")", "\(e.name)", "\(e.kind == .group ? "group" : "user")", "\(e.levelTitle(isFolder: target.isFolder))"))
    }

    /// Refuses if the list changed since `change`.
    public static func undo(_ change: ACLChange) throws {
        guard try current(change.target) == change.after else { throw ACLEditError.changedSinceEdit }
        try write(change.before, to: change.target)
    }

    /// nil removes the whole extended list.
    public static func restore(_ text: String?, to target: ACLTarget) throws {
        _ = try current(target)
        try write(text, to: target)
    }

    /// The list now, refusing unless `target.path` still leads, link-free, to the same item, still the user's.
    private static func current(_ target: ACLTarget) throws -> String? {
        guard let item = state(target.path), item.device == target.device, item.inode == target.inode else {
            throw ACLEditError.itemReplaced
        }
        guard item.owner == getuid() || getuid() == 0 else { throw ACLEditError.notOwner }
        return item.acl
    }

    private struct ItemState {
        var device: Int32, type: fsobj_type_t, owner: uid_t, acl: String?, inode: UInt64
    }

    private static let noLinks = UInt32(FSOPT_NOFOLLOW | FSOPT_NOFOLLOW_ANY)

    /// getattrlist, which needs no read access (an entry may deny the owner that) and refuses a link anywhere in `path`.
    private static func state(_ path: String) -> ItemState? {
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                            commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_OWNERID | ATTR_CMN_EXTENDED_SECURITY | ATTR_CMN_FILEID),
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Unsupported attributes are packed as zero, so the offsets below hold on every file system.
        guard getattrlist(path, &list, &buffer, buffer.count, noLinks | UInt32(FSOPT_PACK_INVAL_ATTRS)) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> ItemState in
            // Packed in attribute-bit order after the length: returned set, dev, type, owner, ACL reference, file ID.
            let reference = raw.loadUnaligned(fromByteOffset: 36, as: attrreference_t.self)
            var text: String?
            if reference.attr_length > 0, let acl = acl_copy_int_native(raw.baseAddress! + 36 + Int(reference.attr_dataoffset)) {
                var entry: acl_entry_t?
                if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0, let cText = acl_to_text(acl, nil) {
                    text = String(cString: cText)
                    acl_free(UnsafeMutableRawPointer(cText))
                }
                acl_free(UnsafeMutableRawPointer(acl))
            }
            return ItemState(device: raw.loadUnaligned(fromByteOffset: 24, as: Int32.self),
                             type: raw.loadUnaligned(fromByteOffset: 28, as: fsobj_type_t.self),
                             owner: raw.loadUnaligned(fromByteOffset: 32, as: uid_t.self), acl: text,
                             inode: raw.loadUnaligned(fromByteOffset: 44, as: UInt64.self))
        }
    }

    /// nil removes the whole extended list.
    private static func write(_ text: String?, to target: ACLTarget) throws {
        guard let acl = text.map({ acl_from_text($0) }) ?? acl_init(0) else {
            throw ACLEditError.failed("The previous permissions couldn't be read back.")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let header = MemoryLayout<attrreference_t>.size
        let size = acl_size(acl)
        guard size > 0 else { throw ACLEditError.failed(String(cString: strerror(errno))) }
        var buffer = [UInt8](repeating: 0, count: header + size)
        let length = buffer.withUnsafeMutableBytes { acl_copy_ext_native($0.baseAddress! + header, acl, size) }
        guard length > 0 else { throw ACLEditError.failed(String(cString: strerror(errno))) }
        try buffer.withUnsafeMutableBytes {
            $0.storeBytes(of: attrreference_t(attr_dataoffset: Int32(header), attr_length: UInt32(length)), as: attrreference_t.self)
            try set(attrgroup_t(ATTR_CMN_EXTENDED_SECURITY), $0, on: target)
        }
    }

    /// Tests: runs between the check and the write.
    nonisolated(unsafe) static var beforeWrite: (() -> Void)?

    /// Writes to the checked item itself, so a file renamed into its place after the check is never changed.
    private static func set(_ attribute: attrgroup_t, _ bytes: UnsafeMutableRawBufferPointer, on target: ACLTarget) throws {
        beforeWrite?()
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attribute,
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var result: Int32
        let fd = open(target.path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            var info = stat()
            if fstat(fd, &info) == 0, info.st_dev == target.device, info.st_ino == target.inode {
                result = fsetattrlist(fd, &list, bytes.baseAddress, bytes.count, 0)
            } else {
                result = -1
                errno = ENOENT
            }
            let error = errno
            close(fd)
            errno = error
        } else if errno == ELOOP {
            throw ACLEditError.itemReplaced
        } else {
            // An item the owner is denied reading can't be opened; its /.vol file-ID path can't be renamed onto.
            result = setattrlist("/.vol/\(target.device)/\(target.inode)", &list, bytes.baseAddress, bytes.count, noLinks)
        }
        guard result == 0 else {
            throw errno == ELOOP || errno == ENOENT ? ACLEditError.itemReplaced : ACLEditError.failed(String(cString: strerror(errno)))
        }
    }

    private static func entryLines(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("!#") && !$0.isEmpty }
    }

    private static func fullText(_ lines: [String]) -> String? {
        lines.isEmpty ? nil : "!#acl 1\n" + lines.joined(separator: "\n") + "\n"
    }

    // MARK: Names for the picker

    /// Excludes system accounts.
    public static func localUsers() -> [String] {
        var names: Set<String> = []
        setpwent()
        while let pw = getpwent() {
            let name = String(cString: pw.pointee.pw_name)
            if pw.pointee.pw_uid >= 500, !name.hasPrefix("_") { names.insert(name) }
        }
        endpwent()
        return names.sorted()
    }

    /// Excludes system groups; "everyone", "staff", "admin" first.
    public static func localGroups() -> [String] {
        var names: Set<String> = ["everyone"]
        setgrent()
        while let gr = getgrent() {
            let name = String(cString: gr.pointee.gr_name)
            if !name.hasPrefix("_"), !name.hasPrefix("com.apple.") { names.insert(name) }
        }
        endgrent()
        let first = ["everyone", "staff", "admin"].filter(names.contains)
        return first + names.subtracting(first).sorted()
    }

    /// An owner may give the item to any of these groups.
    public static func currentUserGroups() -> [(id: gid_t, name: String)] {
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        guard let pw = getpwuid(getuid()) else { return [] }
        if getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid), &groups, &count) < 0 {
            groups = [Int32](repeating: 0, count: Int(count) + 1)
            count = Int32(groups.count)
            _ = getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid), &groups, &count)
        }
        var seen = Set<gid_t>()
        return groups.prefix(Int(count)).compactMap { raw -> (gid_t, String)? in
            let gid = gid_t(bitPattern: raw)
            guard seen.insert(gid).inserted else { return nil }
            let name = ItemSecurity.groupName(gid)
            return name.hasPrefix("_") || name.hasPrefix("com.apple.") ? nil : (gid, name)
        }.sorted { $0.1 < $1.1 }
    }

    /// Owner must belong to `gid`.
    public static func changeGroup(_ target: ACLTarget, to gid: gid_t) throws {
        _ = try current(target)
        var group = gid
        try withUnsafeMutableBytes(of: &group) { try set(attrgroup_t(ATTR_CMN_GRPID), $0, on: target) }
    }

    public static let ownerChangeExplanation =
        "On macOS only an administrator can give an item to another user. Arbor doesn't run with administrator rights; use Finder's Get Info (Sharing & Permissions, after unlocking with an administrator password) or `sudo chown` in Terminal."

    public static var canChangeOwner: Bool { getuid() == 0 }
}


extension ACLEntry {
    /// The matching Explorer level's title, else the raw permission list.
    public func levelTitle(isFolder: Bool) -> String {
        let mine = Set(permissions)
        // Smallest first: Deny of Full control and of Modify write the same entry.
        for level in ACLPermissionLevel.allCases.reversed() {
            let rule = ACLRule(principal: ACLPrincipal(kind, name), allow: allow, level: level)
            if Set(rule.permissions(isFolder: isFolder)) == mine { return level.title }
        }
        return permissionSummary
    }
}
