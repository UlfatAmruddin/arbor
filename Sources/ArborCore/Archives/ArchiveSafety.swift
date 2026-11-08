import Foundation

/// Decides which entries an extraction may write (FE-170): nothing outside the destination, through links,
/// devices, FIFOs or other entries. Rejected entries are reported, never silently dropped.
public enum ExtractionPlanner {
    public enum Rejection: Sendable, Equatable, CaseIterable {
        case unsafePath, linkOutside, specialFile, unknownType, insideNonFolder, notAFolder, caseDuplicate, unreadable

        /// The reason as shown to the user; literal keys so extract-strings.sh lists them.
        public var text: String {
            switch self {
            case .unsafePath: L10n.tr("Its name points outside the destination folder.")
            case .linkOutside: L10n.tr("It's a link to a location outside the extracted files.")
            case .specialFile: L10n.tr("It's a device, pipe or socket.")
            case .unknownType: L10n.tr("Arbor doesn't know what kind of item it is.")
            case .insideNonFolder: L10n.tr("It's stored inside another item that isn't a folder.")
            case .notAFolder: L10n.tr("Other items are stored inside it, but it isn't a folder.")
            case .caseDuplicate: L10n.tr("Another item has the same name with different capitalization.")
            case .unreadable: L10n.tr("Arbor couldn't read its line in the archive's listing.")
            }
        }
    }

    /// Shown for an item whose listing row couldn't be read (its stand-in has no name).
    public static var unreadableName: String { L10n.tr("(an item Arbor couldn't read)") }

    /// Unicode case folding, which (unlike `lowercased`) also matches "ſ" with "s" and "ß" with "ss" as APFS does.
    static func folded<S: StringProtocol>(_ name: S) -> String { name.folding(options: [.caseInsensitive], locale: nil) }

    public struct Plan: Sendable {
        /// Folders (inner paths, "" = archive root) whose contents are extracted.
        public var roots: [String]
        /// Inner folder the roots sit in; links must resolve inside it.
        public var base: [String]
        /// Safe entries to extract.
        public var included: [ArchiveEntry]
        public var rejected: [(entry: ArchiveEntry, reason: Rejection)]
        /// Folders to create even if empty (inner paths).
        public var folders: [String]
        public var totalBytes: Int64
        public var hasEncrypted: Bool
        /// Literal bsdtar patterns (empty = everything). nil = rejected entries are mixed in; files are named one by one.
        public var patterns: [String]

        public var isEmpty: Bool { included.isEmpty && folders.isEmpty }
    }

    /// Plans extracting `roots` (inner paths; [""] = everything). `base` is the shown folder, so links may reach siblings.
    public static func plan(entries: [ArchiveEntry], roots: [String], base: String = "") -> Plan {
        let baseParts = ArchivePath.components(base) ?? []
        let rootParts: [[String]] = roots.map { ArchivePath.components($0) ?? [] }
        let everything = rootParts.contains { $0.isEmpty }

        func underRoots(_ parts: [String]) -> Bool {
            everything || rootParts.contains { $0.count <= parts.count && Array(parts.prefix($0.count)) == $0 }
        }

        // Non-folder entries (to catch "file/child", "link/child") and every path with something below it.
        var tree = PathTree()
        var anyUnsafe = false
        // Every link, to resolve link chains (case-insensitively, like APFS by default).
        var links: [(parts: [String], target: String)] = []
        for entry in entries {
            guard let parts = entry.components else { anyUnsafe = true; continue }
            if entry.kind == .symlink { links.append((parts, entry.linkTarget ?? "")) }
            let node = tree.insert(parts)
            if entry.kind != .directory { tree.markNonFolder(node) }
        }
        var resolver = LinkResolver(links: links, base: baseParts, foldCase: true)
        func rawUnder(_ raw: String) -> Bool {
            everything || rootParts.contains { root in raw.hasPrefix(root.joined(separator: "/") + "/") }
        }

        var included: [ArchiveEntry] = []
        var rejected: [(ArchiveEntry, Rejection)] = []
        var folders: [String] = []
        var total: Int64 = 0
        var encrypted = false
        var seenFolded: [String: String] = [:]
        // An unsafe name could still match a folder pattern, so name included files one by one.
        var rejectedInScope = anyUnsafe

        for entry in entries {
            guard let parts = entry.components else {
                if rawUnder(entry.rawPath) { rejected.append((entry, entry.rawPath.isEmpty ? .unreadable : .unsafePath)) }
                continue
            }
            guard underRoots(parts) else { continue }
            let path = parts.joined(separator: "/")
            var reason: Rejection?
            if entry.kind == .special { reason = .specialFile }
            if entry.kind == .unknown { reason = .unknownType }
            let nodes = tree.nodes(along: parts)
            if reason == nil, nodes.dropLast().contains(where: tree.isNonFolder) { reason = .insideNonFolder }
            if reason == nil, entry.kind == .symlink {
                if !resolver.staysInside(parts, target: entry.linkTarget ?? "") { reason = .linkOutside }
            }
            if reason == nil, entry.kind == .hardlink {
                // A hard link must name another safe member inside the extracted tree.
                guard let target = entry.linkTarget, let t = ArchivePath.components(target),
                      t.count > baseParts.count, Array(t.prefix(baseParts.count)) == baseParts, underRoots(t) else {
                    rejected.append((entry, .linkOutside)); rejectedInScope = true; continue
                }
            }
            if reason == nil, entry.kind != .directory, let node = nodes.last, tree.hasChildren(node) { reason = .notAFolder }
            if reason == nil {
                let key = folded(path)
                if let other = seenFolded[key], other != path { reason = .caseDuplicate } else { seenFolded[key] = path }
            }
            if let reason {
                rejected.append((entry, reason))
                rejectedInScope = true
                continue
            }
            if entry.kind == .directory {
                folders.append(path)
            } else {
                included.append(entry)
                if entry.kind == .file { total = total.saturatingAdd(max(entry.size ?? 0, 0)) }
            }
            if entry.isEncrypted { encrypted = true }
        }

        // Fast path: no rejected entries in scope, so whole roots can be named (a pattern selects a subtree).
        let patterns: [String]
        // Members known to bsdtar under another name (rewritten on extraction) must be named one by one.
        let renamed = entries.contains { $0.storedPath != nil }
        if !rejectedInScope, !renamed {
            patterns = everything ? [] : rootParts.map { $0.joined(separator: "/") }.map(BsdtarListing.literalPattern)
        } else {
            patterns = included.map { BsdtarListing.literalPattern($0.storedPath ?? $0.rawPath) }
        }
        return Plan(roots: roots, base: baseParts, included: included, rejected: rejected, folders: folders,
                    totalBytes: total, hasEncrypted: encrypted, patterns: patterns)
    }
}

/// Member paths as a tree of components, so deep names cost linear time and memory (not a string per prefix).
struct PathTree {
    private var children: [[String: Int]] = [[:]]
    private var nonFolder: [Bool] = [false]

    var nodeCount: Int { children.count }

    /// Adds `parts` (and every prefix) and returns its node.
    @discardableResult mutating func insert(_ parts: [String]) -> Int {
        var node = 0
        for part in parts {
            if let next = children[node][part] { node = next; continue }
            children.append([:])
            nonFolder.append(false)
            children[node][part] = children.count - 1
            node = children.count - 1
        }
        return node
    }

    mutating func markNonFolder(_ node: Int) { nonFolder[node] = true }
    func isNonFolder(_ node: Int) -> Bool { nonFolder[node] }
    func hasChildren(_ node: Int) -> Bool { !children[node].isEmpty }

    /// The nodes for each prefix of `parts`, stopping at the first one not in the tree.
    func nodes(along parts: [String]) -> [Int] {
        var node = 0
        var out: [Int] = []
        for part in parts {
            guard let next = children[node][part] else { break }
            out.append(next)
            node = next
        }
        return out
    }
}

/// Resolves links once each (chains over 32 or loops escape), following links before `..` like the file system.
struct LinkResolver {
    /// A resolved path: a node of the link tree plus components below it that lead to no link.
    private struct Position { var node: Int; var off: Int }

    private var children: [[String: Int]] = [[:]]
    private var parent: [Int] = [0]
    private var depth: [Int] = [0]
    private var targets: [Int: String] = [:]
    private var memo: [Int: Position?] = [:]
    private var active: Set<Int> = []
    private let base: [String]
    private let foldCase: Bool
    /// Deeper than any member name can be (past PATH_MAX), so a path this deep counts as escaping.
    private let maxDepth: Int

    init(links: [(parts: [String], target: String)], base: [String], foldCase: Bool) {
        self.base = base
        self.foldCase = foldCase
        maxDepth = base.count + ArchivePath.maxPathBytes / 2
        for link in links {
            var node = 0
            for part in link.parts {
                let key = self.key(part)
                if let next = children[node][key] { node = next; continue }
                children.append([:])
                parent.append(node)
                depth.append(depth[node] + 1)
                children[node][key] = children.count - 1
                node = children.count - 1
            }
            targets[node] = link.target
        }
    }

    private func key<S: StringProtocol>(_ part: S) -> String { foldCase ? ExtractionPlanner.folded(part) : String(part) }

    /// Whether a link at `parts` with `target` resolves inside `base`; `parts` must be one of the links.
    mutating func staysInside(_ parts: [String], target: String) -> Bool {
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return false }
        var folder = 0
        for part in parts.dropLast() {
            guard let next = children[folder][key(part)] else { return false }
            folder = next
        }
        return resolve(from: Position(node: folder, off: 0), target, nesting: 0) != nil
    }

    private mutating func resolve(from start: Position, _ target: String, nesting: Int) -> Position? {
        guard target.utf8.count <= ArchivePath.maxPathBytes, !target.isEmpty, !target.hasPrefix("/"),
              !target.contains("\u{0}") else { return nil }
        var at = start
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard depth[at.node] + at.off > base.count else { return nil }
                if at.off > 0 { at.off -= 1 } else { at.node = parent[at.node] }
            default:
                guard depth[at.node] + at.off < maxDepth else { return nil }
                guard at.off == 0, let next = children[at.node][key(part)] else { at.off += 1; continue }
                at.node = next
                if targets[next] != nil {
                    guard let expanded = expand(next, nesting: nesting + 1) else { return nil }
                    at = expanded
                }
            }
        }
        return at
    }

    /// Where the link at `node` leads, worked out once.
    private mutating func expand(_ node: Int, nesting: Int) -> Position? {
        if let known = memo[node] { return known }
        guard nesting <= 32, !active.contains(node), let target = targets[node] else { return nil }
        active.insert(node)
        let result = resolve(from: Position(node: parent[node], off: 0), target, nesting: nesting)
        active.remove(node)
        memo[node] = .some(result)
        return result
    }
}

/// `LinkResolver` over extracted files: each name is looked up on disk so the file system's own folding decides.
struct DiskLinkResolver {
    private struct Position { var node: Int; var off: Int }
    private struct FileID: Hashable { var dev: dev_t; var ino: ino_t }
    /// A link by the folder holding it (its target is relative to that folder) and its inode.
    private struct Link: Hashable { var folder: Int; var id: FileID }
    private enum Child { case folder(Int), link(Link), other, unknown }

    private let base: [String]
    private let maxDepth: Int
    /// Folders found by the walk (node 0 = staging root).
    private var names: [String] = [""]
    private var parent: [Int] = [0]
    private var depth: [Int] = [0]
    private var folderByID: [FileID: Int] = [:]
    /// Keyed by the exact bytes: String equality would merge spellings a normalization-sensitive volume keeps apart.
    private var lookups: [Int: [[UInt8]: Child]] = [:]
    private var targets: [Link: String] = [:]
    private var memo: [Link: Position?] = [:]
    private var active: Set<Link> = []
    private var rootFD: Int32
    private var fds: [Int: Int32] = [:]

    init(root: String, base: [String]) {
        self.base = base
        maxDepth = base.count + ArchivePath.maxPathBytes / 2
        rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        var info = Darwin.stat()
        if rootFD >= 0, fstat(rootFD, &info) == 0 { folderByID[FileID(dev: info.st_dev, ino: info.st_ino)] = 0 }
    }

    mutating func close() {
        for fd in fds.values { Darwin.close(fd) }
        fds = [:]
        if rootFD >= 0 { Darwin.close(rootFD) }
        rootFD = -1
    }

    /// Registers a real folder `name` (lstat `info`) inside folder `parent`; returns its node.
    mutating func addFolder(_ name: String, parent folder: Int, _ info: Darwin.stat) -> Int {
        names.append(name)
        parent.append(folder)
        depth.append(depth[folder] + 1)
        folderByID[FileID(dev: info.st_dev, ino: info.st_ino)] = names.count - 1
        return names.count - 1
    }

    /// Whether the link at `parts` (directly inside walked folder `folder`) resolves inside `base`.
    mutating func staysInside(_ parts: [String], folder: Int) -> Bool {
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base, let name = parts.last,
              case .link(let link) = lookup(name, in: folder) else { return false }
        return expand(link, nesting: 0) != nil
    }

    private mutating func resolve(from start: Position, _ target: String, nesting: Int) -> Position? {
        guard target.utf8.count <= ArchivePath.maxPathBytes, !target.isEmpty, !target.hasPrefix("/"),
              !target.contains("\u{0}") else { return nil }
        var at = start
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard depth[at.node] + at.off > base.count else { return nil }
                if at.off > 0 { at.off -= 1 } else { at.node = parent[at.node] }
            default:
                guard depth[at.node] + at.off < maxDepth else { return nil }
                guard at.off == 0 else { at.off += 1; continue }
                switch lookup(String(part), in: at.node) {
                case .folder(let next): at.node = next
                case .link(let link):
                    guard let expanded = expand(link, nesting: nesting + 1) else { return nil }
                    at = expanded
                case .other: at.off += 1
                case .unknown: return nil
                }
            }
        }
        return at
    }

    private mutating func expand(_ link: Link, nesting: Int) -> Position? {
        if let known = memo[link] { return known }
        guard nesting <= 32, !active.contains(link), let target = targets[link] else { return nil }
        active.insert(link)
        let result = resolve(from: Position(node: link.folder, off: 0), target, nesting: nesting)
        active.remove(link)
        memo[link] = .some(result)
        return result
    }

    /// What `name` is inside `folder` on disk, looked up once per spelling.
    private mutating func lookup(_ name: String, in folder: Int) -> Child {
        let bytes = Array(name.utf8)
        if let known = lookups[folder]?[bytes] { return known }
        let child = stat(name, in: folder)
        lookups[folder, default: [:]][bytes] = child
        return child
    }

    private mutating func stat(_ name: String, in folder: Int) -> Child {
        guard let fd = descriptor(folder) else { return .unknown }
        var info = Darwin.stat()
        // Missing or not a folder: the rest of the path is followed by name only, like the planner.
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .other : .unknown }
        let id = FileID(dev: info.st_dev, ino: info.st_ino)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return folderByID[id].map(Child.folder) ?? .unknown
        case S_IFLNK:
            let link = Link(folder: folder, id: id)
            if targets[link] == nil {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = readlinkat(fd, name, &buffer, buffer.count - 1)
                guard count > 0, count < buffer.count - 1,
                      let target = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { return .unknown }
                targets[link] = target
            }
            return .link(link)
        default:
            return .other
        }
    }

    /// An open descriptor for a walked folder, reached from the root without following any link.
    private mutating func descriptor(_ folder: Int) -> Int32? {
        guard rootFD >= 0 else { return nil }
        if folder == 0 { return rootFD }
        if let fd = fds[folder] { return fd }
        if fds.count >= 32 { for fd in fds.values { Darwin.close(fd) }; fds = [:] }
        var chain: [String] = []
        var node = folder
        while node != 0 { chain.append(names[node]); node = parent[node] }
        var fd = openat(rootFD, chain.reversed().joined(separator: "/"), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if fd < 0, errno == ENAMETOOLONG {
            // Past PATH_MAX: one component at a time.
            fd = rootFD
            for name in chain.reversed() {
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd != rootFD { Darwin.close(fd) }
                fd = next
                if fd < 0 { break }
            }
        }
        guard fd >= 0 else { return nil }
        fds[folder] = fd
        return fd
    }
}

/// Zip-bomb and disk-space guard (FE-170): checks declared sizes up front and stops extractions that write far more.
public struct ExpansionPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        case ok
        /// High ratio: allowed only after the user confirms.
        case suspicious(ratio: Double)
        /// Not enough free space.
        case noSpace(needed: Int64, available: Int64)
        /// Over the hard limit; never extracted.
        case tooLarge(total: Int64)
    }

    /// Ratio above which a large archive is treated as a possible zip bomb.
    public var suspiciousRatio: Double = 200
    /// Ratios only matter above this expanded size (small archives of zeros are harmless).
    public var ratioFloor: Int64 = 512 * 1_048_576
    /// Never expand beyond this, whatever the ratio.
    public var hardLimit: Int64 = 1 << 40   // 1 TiB
    /// Free space to leave on the destination volume.
    public var reserve: Int64 = 256 * 1_048_576

    public init() {}

    public func check(archiveSize: Int64, totalBytes: Int64, freeSpace: Int64?) -> Verdict {
        if totalBytes > hardLimit { return .tooLarge(total: totalBytes) }
        if let free = freeSpace, totalBytes + reserve > free { return .noSpace(needed: totalBytes, available: free) }
        let ratio = Double(totalBytes) / Double(max(archiveSize, 1))
        if totalBytes >= ratioFloor, ratio >= suspiciousRatio { return .suspicious(ratio: ratio) }
        return .ok
    }

    /// While extracting: how many bytes may be written before the job is stopped.
    public func writeLimit(declared: Int64) -> Int64 {
        declared + max(declared / 10, 64 * 1_048_576)
    }
}

/// Post-extraction check before moving into the destination (defense in depth): removes escaping links,
/// special files and set-ID bits, and copies the archive's quarantine to every item like Archive Utility.
public enum ExtractionVerifier {
    public struct Report: Sendable {
        public var removed: [String] = []
        public var bytes: Int64 = 0
        public var items = 0
    }

    public static func verify(staging: URL, base: [String], quarantine: Data?) -> Report {
        var report = Report()
        let rootPath = staging.standardizedFileURL.path
        let fm = FileManager.default
        var disk = DiskLinkResolver(root: rootPath, base: base)
        defer { disk.close() }
        // A manual walk with lstat: enumerators skip dangling links, which are exactly the ones to check.
        var pending: [(path: String, parts: [String], node: Int)] = [(rootPath, [], 0)]
        var links: [(path: String, parts: [String], folder: Int)] = []
        while let (folder, folderParts, folderNode) = pending.popLast() {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                let parts = folderParts + [name]
                let relative = parts.joined(separator: "/")
                var info = Darwin.stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    // Judged after the walk, once every link is known (a link can escape through another).
                    links.append((path, parts, folderNode))
                    continue
                case S_IFREG:
                    report.bytes = report.bytes.saturatingAdd(Int64(info.st_size))
                    if info.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0 { chmod(path, info.st_mode & 0o777) }
                    if info.st_mode & S_IRUSR == 0 { chmod(path, (info.st_mode & 0o777) | S_IRUSR | S_IWUSR) }
                case S_IFDIR:
                    // Folders must stay writable by their owner so the job can move and clean up.
                    let wanted = (info.st_mode & 0o777) | S_IRWXU
                    if info.st_mode & 0o7777 != wanted { chmod(path, wanted) }
                    pending.append((path, parts, disk.addFolder(name, parent: folderNode, info)))
                default:
                    try? fm.removeItem(atPath: path)
                    report.removed.append(relative)
                    continue
                }
                report.items += 1
                if let quarantine {
                    _ = quarantine.withUnsafeBytes { raw in
                        setxattr(path, quarantineName, raw.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW)
                    }
                }
            }
        }
        // Resolve each link through the links on disk; remove every escaping one only after all are judged.
        var escaping: [(path: String, parts: [String], folder: Int)] = []
        for link in links {
            if !disk.staysInside(link.parts, folder: link.folder) {
                escaping.append(link)
            } else {
                report.items += 1
                if let quarantine {
                    _ = quarantine.withUnsafeBytes { raw in
                        setxattr(link.path, quarantineName, raw.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW)
                    }
                }
            }
        }
        for link in escaping {
            try? fm.removeItem(atPath: link.path)
            report.removed.append(link.parts.joined(separator: "/"))
        }
        return report
    }

    public static let quarantineName = "com.apple.quarantine"

    /// The archive's quarantine attribute, if it was downloaded.
    public static func quarantine(of url: URL) -> Data? {
        let size = getxattr(url.path, quarantineName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, quarantineName, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }
}
