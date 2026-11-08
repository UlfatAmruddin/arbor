import Foundation
import Darwin

// MARK: - BSD flags (Read-only = Locked, Hidden)

/// The macOS file flags behind Explorer's "Read-only" and "Hidden" attributes (FE-156, FE-245).
///
/// - "Read-only" maps to the user immutable flag (`uchg`), which Finder shows as **Locked**. It blocks
///   changes, renames and deletion. It is *not* the same as lacking write permission, which the
///   Security tab shows separately (tested with access(2)).
/// - "Hidden" maps to `UF_HIDDEN` (`chflags hidden`). Names that start with "." are always hidden.
/// NTFS compression, encryption, archive and indexing attributes have no per-file macOS equivalent.
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

    /// Flags with only the two attributes changed; every other flag is preserved.
    public func with(locked: Bool? = nil, hidden: Bool? = nil) -> FileFlags {
        var copy = self
        if let locked { copy.isLocked = locked }
        if let hidden { copy.isHidden = hidden }
        return copy
    }

    /// Reads the item's own flags (a symbolic link is not followed).
    public static func read(_ url: URL) throws -> FileFlags {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError.current }
        return FileFlags(raw: st.st_flags)
    }

    /// Writes flags to the item itself (not a link's target).
    public static func write(_ flags: FileFlags, to url: URL) throws {
        guard lchflags(url.path, flags.raw) == 0 else { throw POSIXError.current }
    }

    /// Sets Locked and/or Hidden, leaving other flags as they are. Returns whether anything changed.
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

/// Read/write/execute bits for one class (owner, group, everyone else).
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

    /// Finder's wording: "Read & Write", "Read only", "Write only (Drop Box)", "No Access".
    /// For files the execute bit is added ("Read & Write, Execute").
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

/// A POSIX mode (`st_mode & 07777`) split into Explorer-like rows (FE-153).
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

    /// "0644".
    public var octal: String { String(format: "%04o", Int(mode)) }

    /// "rwxr-xr-x" (with s/S/t/T for the special bits, like ls).
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

/// One entry of an extended (macOS) ACL, as shown in the Security tab. ACLs are read-only in Arbor.
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

    /// Human labels for acl(3) permission names.
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

    /// Parses `acl_to_text` output:
    ///
    ///     !#acl 1
    ///     group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete
    ///     user:…:ana:501:allow,file_inherit,directory_inherit:read,write
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

    /// The item's extended ACL entries (empty when it has none).
    public static func read(_ url: URL) -> [ACLEntry] {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let cText = acl_to_text(acl, nil) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(cText)) }
        return parse(String(cString: cText))
    }
}

// MARK: - Ownership and effective access

/// Owner, group, mode, ACL and the current user's *tested* access to an item (FE-153, FE-245).
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

    /// Whether the current user may change the mode (owner or root).
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

    /// The user's full name ("Ana Lopez"), for "Owner: Ana Lopez (ana)".
    public static func fullName(_ uid: uid_t) -> String? {
        guard let pw = getpwuid(uid), let gecos = pw.pointee.pw_gecos else { return nil }
        let s = String(cString: gecos)
        return s.isEmpty ? nil : s
    }

    /// Changes only the mode bits. Throws when the user doesn't own the item.
    public static func setPermissions(_ permissions: PosixPermissions, on url: URL) throws {
        guard lchmod(url.path, mode_t(permissions.mode)) == 0 else { throw POSIXError.current }
    }
}

/// What the current user can actually do, tested with access(2) using effective IDs, so ACLs,
/// group membership and the Locked flag are all accounted for. Never inferred from the mode alone.
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

    /// Plain-language lines for the Security tab.
    public func lines(isFolder: Bool) -> [(label: String, allowed: Bool)] {
        if isFolder {
            return [("List contents", read), ("Add, rename and delete items inside", write && execute), ("Open the folder", execute)]
        }
        return [("Read", read), ("Modify", write), ("Run as a program", execute)]
    }
}
