import Foundation
import Darwin

// MARK: - BSD flags (Read-only = Locked, Hidden)

/// Explorer's "Read-only" = `uchg` (Finder's Locked; not the same as lacking write permission) and
/// "Hidden" = `UF_HIDDEN` (FE-156, FE-245).
public struct FileFlags: Equatable, Sendable {
    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public static let immutableBit = UInt32(UF_IMMUTABLE)
    public static let hiddenBit = UInt32(UF_HIDDEN)

    public var isLocked: Bool {
        get { raw & Self.immutableBit != 0 }
        set { raw = newValue ? raw | Self.immutableBit : raw & ~Self.immutableBit }
    }

    public var isHidden: Bool {
        get { raw & Self.hiddenBit != 0 }
        set { raw = newValue ? raw | Self.hiddenBit : raw & ~Self.hiddenBit }
    }

    /// Other flags are preserved.
    public func with(locked: Bool? = nil, hidden: Bool? = nil) -> FileFlags {
        var copy = self
        if let locked { copy.isLocked = locked }
        if let hidden { copy.isHidden = hidden }
        return copy
    }

    /// Does not follow symbolic links.
    public static func read(_ url: URL) throws -> FileFlags {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError.current }
        return FileFlags(raw: st.st_flags)
    }

    /// Does not follow symbolic links.
    public static func write(_ flags: FileFlags, to url: URL) throws {
        guard lchflags(url.path, flags.raw) == 0 else { throw POSIXError.current }
    }

    /// Returns whether anything changed.
    @discardableResult
    public static func update(_ url: URL, locked: Bool? = nil, hidden: Bool? = nil) throws -> Bool {
        let current = try read(url)
        let next = current.with(locked: locked, hidden: hidden)
        guard next != current else { return false }
        try write(next, to: url)
        return true
    }
}

extension POSIXError {
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

// MARK: - POSIX permissions

public struct PermissionBits: Equatable, Sendable {
    public var read: Bool
    public var write: Bool
    public var execute: Bool

    public init(read: Bool, write: Bool, execute: Bool) {
        self.read = read
        self.write = write
        self.execute = execute
    }

    init(_ value: UInt16) {
        self.init(read: value & 4 != 0, write: value & 2 != 0, execute: value & 1 != 0)
    }

    var value: UInt16 { (read ? 4 : 0) | (write ? 2 : 0) | (execute ? 1 : 0) }

    /// Finder's wording, plus ", Execute" for executable files.
    public func summary(isFolder: Bool) -> String {
        var text: String
        switch (read, write) {
        case (true, true): text = L10n.tr("Read & Write")
        case (true, false): text = L10n.tr("Read only")
        case (false, true): text = isFolder ? L10n.tr("Write only (Drop Box)") : L10n.tr("Write only")
        case (false, false): text = L10n.tr("No Access")
        }
        if isFolder {
            if !execute, read || write { text += " (can't open)" }
        } else if execute {
            text += ", Execute"
        }
        return text
    }
}

/// `st_mode & 07777` split into owner/group/everyone rows (FE-153).
public struct PosixPermissions: Equatable, Sendable {
    public var mode: UInt16

    public init(mode: UInt16) { self.mode = mode & 0o7777 }

    public enum Role: String, CaseIterable, Sendable { case owner, group, everyone }

    public subscript(role: Role) -> PermissionBits {
        get {
            switch role {
            case .owner: return PermissionBits((mode >> 6) & 7)
            case .group: return PermissionBits((mode >> 3) & 7)
            case .everyone: return PermissionBits(mode & 7)
            }
        }
        set {
            let shift: UInt16 = role == .owner ? 6 : (role == .group ? 3 : 0)
            mode = (mode & ~(7 << shift)) | (newValue.value << shift)
        }
    }

    public var setUID: Bool { mode & 0o4000 != 0 }
    public var setGID: Bool { mode & 0o2000 != 0 }
    public var sticky: Bool { mode & 0o1000 != 0 }

    public var octal: String { String(format: "%04o", Int(mode)) }

    /// "rwxr-xr-x", with s/S/t/T like ls.
    public var symbolic: String {
        func triplet(_ bits: PermissionBits, special: Bool, specialChar: Character) -> String {
            let x: Character
            switch (bits.execute, special) {
            case (true, true): x = specialChar
            case (false, true): x = Character(specialChar.uppercased())
            case (true, false): x = "x"
            case (false, false): x = "-"
            }
            return "\(bits.read ? "r" : "-")\(bits.write ? "w" : "-")\(x)"
        }
        return triplet(self[.owner], special: setUID, specialChar: "s")
            + triplet(self[.group], special: setGID, specialChar: "s")
            + triplet(self[.everyone], special: sticky, specialChar: "t")
    }
}

// MARK: - ACL entries

/// One extended ACL entry; editing lives in `ACLEditor`.
public struct ACLEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case user, group }
    public var kind: Kind
    public var name: String
    public var allow: Bool
    public var permissions: [String]
    public var flags: [String]

    public init(kind: Kind, name: String, allow: Bool, permissions: [String], flags: [String] = []) {
        self.kind = kind
        self.name = name
        self.allow = allow
        self.permissions = permissions
        self.flags = flags
    }

    public var isInherited: Bool { flags.contains("inherited") }

    public static let permissionLabels: [String: String] = [
        "read": "Read data / List folder", "write": "Write data / Create files", "execute": "Execute / Traverse folder",
        "delete": "Delete", "append": "Append data / Create folders", "delete_child": "Delete subfolders and files",
        "readattr": "Read attributes", "writeattr": "Write attributes", "readextattr": "Read extended attributes",
        "writeextattr": "Write extended attributes", "readsecurity": "Read permissions", "writesecurity": "Change permissions",
        "chown": "Take ownership", "list": "List folder", "search": "Traverse folder", "add_file": "Create files",
        "add_subdirectory": "Create folders",
    ]

    public var permissionSummary: String {
        permissions.map { Self.permissionLabels[$0] ?? $0 }.joined(separator: ", ")
    }

    /// Parses `acl_to_text` lines: `kind:uuid:name:id:allow|deny[,flags]:perms`.
    public static func parse(_ text: String) -> [ACLEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> ACLEntry? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.hasPrefix("!#"), !s.isEmpty else { return nil }
            let fields = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, let kind = Kind(rawValue: fields[0]) else { return nil }
            let rule = fields[4].split(separator: ",").map(String.init)
            guard let verdict = rule.first, verdict == "allow" || verdict == "deny" else { return nil }
            let name = fields[2].isEmpty ? (fields[3].isEmpty ? fields[1] : fields[3]) : fields[2]
            return ACLEntry(kind: kind, name: name, allow: verdict == "allow",
                            permissions: fields[5].split(separator: ",").map(String.init),
                            flags: Array(rule.dropFirst()))
        }
    }

    public static func read(_ url: URL) -> [ACLEntry] {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let cText = acl_to_text(acl, nil) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(cText)) }
        return parse(String(cString: cText))
    }
}

// MARK: - Ownership and effective access

/// Owner, group, mode, ACL and tested access (FE-153, FE-245).
public struct ItemSecurity: Equatable, Sendable {
    public var ownerName: String
    public var ownerID: UInt32
    public var groupName: String
    public var groupID: UInt32
    public var permissions: PosixPermissions
    public var acl: [ACLEntry]
    public var isFolder: Bool
    public var flags: FileFlags
    public var access: EffectiveAccess

    public var currentUserCanChangePermissions: Bool { ownerID == getuid() || getuid() == 0 }

    public static func read(_ url: URL) throws -> ItemSecurity {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError.current }
        let isLink = (st.st_mode & S_IFMT) == S_IFLNK
        var isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if isLink { var t = stat(); if stat(url.path, &t) == 0 { isDir = (t.st_mode & S_IFMT) == S_IFDIR } }
        return ItemSecurity(ownerName: userName(st.st_uid), ownerID: st.st_uid,
                            groupName: groupName(st.st_gid), groupID: st.st_gid,
                            permissions: PosixPermissions(mode: UInt16(st.st_mode & 0o7777)),
                            acl: ACLEntry.read(url), isFolder: isDir, flags: FileFlags(raw: st.st_flags),
                            access: EffectiveAccess.test(url))
    }

    public static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return "\(uid)" }
        return String(cString: pw.pointee.pw_name)
    }

    public static func groupName(_ gid: gid_t) -> String {
        guard let gr = getgrgid(gid) else { return "\(gid)" }
        return String(cString: gr.pointee.gr_name)
    }

    /// From the GECOS field.
    public static func fullName(_ uid: uid_t) -> String? {
        guard let pw = getpwuid(uid), let gecos = pw.pointee.pw_gecos else { return nil }
        let s = String(cString: gecos)
        return s.isEmpty ? nil : s
    }

    /// Throws unless the user owns the item.
    public static func setPermissions(_ permissions: PosixPermissions, on url: URL) throws {
        guard lchmod(url.path, mode_t(permissions.mode)) == 0 else { throw POSIXError.current }
    }
}

/// Tested with access(2) on effective IDs, so ACLs, groups and Locked count; never inferred from the mode.
public struct EffectiveAccess: Equatable, Sendable {
    public var read: Bool
    public var write: Bool
    public var execute: Bool
    public var exists: Bool

    public init(read: Bool, write: Bool, execute: Bool, exists: Bool = true) {
        self.read = read
        self.write = write
        self.execute = execute
        self.exists = exists
    }

    public static func test(_ url: URL) -> EffectiveAccess {
        let path = url.path
        func ok(_ mode: Int32) -> Bool { faccessat(AT_FDCWD, path, mode, AT_EACCESS) == 0 }
        return EffectiveAccess(read: ok(R_OK), write: ok(W_OK), execute: ok(X_OK), exists: ok(F_OK))
    }

    public func lines(isFolder: Bool) -> [(label: String, allowed: Bool)] {
        if isFolder {
            return [("List contents", read), ("Add, rename and delete items inside", write && execute), ("Open the folder", execute)]
        }
        return [("Read", read), ("Modify", write), ("Run as a program", execute)]
    }
}
