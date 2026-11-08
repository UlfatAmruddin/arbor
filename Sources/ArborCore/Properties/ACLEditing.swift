import Foundation
import Darwin

/// Editing an item's access list from the Security tab (FE-153): Explorer's "Edit…" permissions in
/// macOS terms. Entries are added with `chmod +a` and removed with `chmod -a#` (argument arrays,
/// never a shell), and every change keeps the access list as it was before, so the last change can be
/// undone. Undo refuses when the list changed again since (another app or Terminal).
///
/// Only the item's owner (or root) can change its access list; ownership itself can only be given
/// to another user by an administrator, which Arbor never does.
public struct ACLPrincipal: Equatable, Sendable, Hashable {
    public var kind: ACLEntry.Kind
    public var name: String

    public init(_ kind: ACLEntry.Kind, _ name: String) {
        self.kind = kind
        self.name = name
    }

    /// "user:ana" / "group:staff", the form chmod(1) takes.
    public var chmodName: String { "\(kind.rawValue):\(name)" }

    /// Whether the directory service knows this name.
    public var exists: Bool {
        switch kind {
        case .user: return getpwnam(name) != nil
        case .group: return name == "everyone" || getgrnam(name) != nil
        }
    }
}

/// Explorer's permission levels, translated to acl(3) permissions for files and folders.
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
    /// Folders: also applies to new files and subfolders created inside.
    public var inherit: Bool

    public init(principal: ACLPrincipal, allow: Bool, level: ACLPermissionLevel, inherit: Bool = false) {
        self.principal = principal
        self.allow = allow
        self.level = level
        self.inherit = inherit
    }

    /// Permissions a Deny entry never takes away: seeing the item's attributes, reading and changing
    /// the access list itself, and taking ownership. Windows' owner always keeps these implicitly; on
    /// macOS a Deny of them hides the item from `ls` and locks the owner out of fixing the list.
    public static let neverDenied: Set<String> = ["readattr", "readsecurity", "writesecurity", "chown"]

    public func permissions(isFolder: Bool) -> [String] {
        let all = level.permissions(isFolder: isFolder)
        return allow ? all : all.filter { !Self.neverDenied.contains($0) }
    }

    /// The `chmod +a` entry text: "user:ana allow read,write".
    public func chmodEntry(isFolder: Bool) -> String {
        var perms = permissions(isFolder: isFolder)
        if isFolder, inherit { perms += ["file_inherit", "directory_inherit"] }
        return "\(principal.chmodName) \(allow ? "allow" : "deny") \(perms.joined(separator: ","))"
    }

    /// "Allow ana (user) Modify, also for items inside".
    public var summary: String {
        "\(allow ? "Allow" : "Deny") \(principal.name) (\(principal.kind == .group ? "group" : "user")): \(level.title)"
            + (inherit ? ", also for new items inside" : "")
    }
}

public enum ACLEditError: Error, LocalizedError, Equatable {
    case notOwner
    case unknownPrincipal(String)
    case changedSinceEdit
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notOwner: return L10n.tr("Only the owner of this item or an administrator can change its permissions.")
        case .unknownPrincipal(let name): return L10n.format("There's no user or group named “%@” on this Mac.", "\(name)")
        case .changedSinceEdit: return L10n.tr("The permissions were changed again after your change, so undoing it could remove someone else's change.")
        case .failed(let text): return text
        }
    }
}

/// One applied change and what the list looked like before and after it.
public struct ACLChange: Equatable, Sendable {
    public var url: URL
    public var before: String?
    public var after: String?
    public var summary: String
}

public enum ACLEditor {
    public static let chmod = "/bin/chmod"

    /// The extended access list as acl_to_text(3) writes it, or nil when the item has none.
    public static func text(_ url: URL) -> String? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else { return nil }
        guard let cText = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(cText)) }
        return String(cString: cText)
    }

    public static func canEdit(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        return st.st_uid == getuid() || getuid() == 0
    }

    /// Adds an entry (at the position macOS puts it: deny entries before allow entries).
    @discardableResult
    public static func add(_ rule: ACLRule, to url: URL) throws -> ACLChange {
        guard canEdit(url) else { throw ACLEditError.notOwner }
        guard rule.principal.exists else { throw ACLEditError.unknownPrincipal(rule.principal.name) }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let before = text(url)
        try run(["+a", rule.chmodEntry(isFolder: isDirectory.boolValue), url.path])
        return ACLChange(url: url, before: before, after: text(url), summary: L10n.format("Added: %@", "\(rule.summary)"))
    }

    /// Removes the entry at `index` (0-based, in the order `ACLEntry.read` lists them).
    @discardableResult
    public static func remove(at index: Int, from url: URL) throws -> ACLChange {
        guard canEdit(url) else { throw ACLEditError.notOwner }
        let entries = ACLEntry.read(url)
        guard entries.indices.contains(index) else { throw ACLEditError.failed("That entry isn't there anymore.") }
        let before = text(url)
        try run(["-a#", "\(index)", url.path])
        let e = entries[index]
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return ACLChange(url: url, before: before, after: text(url),
                         summary: L10n.format("Removed: %@ %@ (%@): %@", "\(e.allow ? "Allow" : "Deny")", "\(e.name)", "\(e.kind == .group ? "group" : "user")", "\(e.levelTitle(isFolder: isDirectory.boolValue))"))
    }

    /// Puts the list back as it was before `change`, but only if nothing changed it since.
    public static func undo(_ change: ACLChange) throws {
        guard canEdit(change.url) else { throw ACLEditError.notOwner }
        guard text(change.url) == change.after else { throw ACLEditError.changedSinceEdit }
        try restore(change.before, to: change.url)
    }

    /// Replaces the extended list with `text` (nil = no entries).
    public static func restore(_ text: String?, to url: URL) throws {
        guard let text else {
            // No entries before: remove the whole extended list.
            return try run(["-N", url.path])
        }
        guard let acl = acl_from_text(text) else { throw ACLEditError.failed("The previous permissions couldn't be read back.") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_link_np(url.path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw ACLEditError.failed(String(cString: strerror(errno)))
        }
    }

    private static func run(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chmod)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "chmod: ", with: "")
            throw ACLEditError.failed(message.isEmpty ? "The permissions couldn't be changed." : message)
        }
    }

    // MARK: Names for the picker

    /// Local people (not system accounts), sorted.
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

    /// Groups (not system service groups), with "everyone", "staff" and "admin" first.
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

    /// The groups the current user belongs to (an owner may give the item to any of them).
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

    /// Changes the item's group (allowed for the owner when they belong to that group).
    public static func changeGroup(_ url: URL, to gid: gid_t) throws {
        guard canEdit(url) else { throw ACLEditError.notOwner }
        guard lchown(url.path, uid_t.max, gid) == 0 else { throw ACLEditError.failed(String(cString: strerror(errno))) }
    }

    /// Why the owner can't be changed here (always true for a normal user on macOS).
    public static let ownerChangeExplanation =
        "On macOS only an administrator can give an item to another user. Arbor doesn't run with administrator rights; use Finder's Get Info (Sharing & Permissions, after unlocking with an administrator password) or `sudo chown` in Terminal."

    public static var canChangeOwner: Bool { getuid() == 0 }
}


extension ACLEntry {
    /// "Modify" when the entry's permissions are exactly one of Explorer's levels (as Arbor writes
    /// them), else the list of permissions.
    public func levelTitle(isFolder: Bool) -> String {
        let mine = Set(permissions)
        // Smallest level first: a Deny of Full control and of Modify write the same entry.
        for level in ACLPermissionLevel.allCases.reversed() {
            let rule = ACLRule(principal: ACLPrincipal(kind, name), allow: allow, level: level)
            if Set(rule.permissions(isFolder: isFolder)) == mine { return level.title }
        }
        return permissionSummary
    }
}
