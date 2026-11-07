import Foundation

/// Decides which entries an extraction may write (FE-170). Nothing is extracted that would land
/// outside the destination, follow a link out of it, create a device or FIFO, or write through
/// another entry. Rejected entries are reported, never silently dropped.
public enum ExtractionPlanner {
    public enum Rejection: String, Sendable, Equatable {
        case unsafePath = "Its name points outside the destination folder."
        case linkOutside = "It's a link to a location outside the extracted files."
        case specialFile = "It's a device, pipe or socket."
        case insideNonFolder = "It's stored inside another item that isn't a folder."
        case notAFolder = "Other items are stored inside it, but it isn't a folder."
        case caseDuplicate = "Another item has the same name with different capitalization."
    }

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
        /// Literal patterns for bsdtar (empty = extract everything). nil = rejected entries are mixed in and the
        /// included files must be named one by one.
        public var patterns: [String]

        public var isEmpty: Bool { included.isEmpty && folders.isEmpty }
    }

    /// Plans extracting `roots` (inner paths of selected items; [""] = everything) from a listing.
    /// `base` is the folder being shown (the roots' parent), so a link may point at siblings inside it.
    public static func plan(entries: [ArchiveEntry], roots: [String], base: String = "") -> Plan {
        let baseParts = ArchivePath.components(base) ?? []
        let rootParts: [[String]] = roots.map { ArchivePath.components($0) ?? [] }
        let everything = rootParts.contains { $0.isEmpty }

        func underRoots(_ parts: [String]) -> Bool {
            everything || rootParts.contains { $0.count <= parts.count && Array(parts.prefix($0.count)) == $0 }
        }

        // Paths of entries that are not folders, to catch "file/child" and "link/child", and every
        // path that has something stored below it.
        var nonFolders = Set<String>()
        var parents = Set<String>()
        var anyUnsafe = false
        // Link targets by lowercased path (APFS is case-insensitive by default), to resolve link chains.
        var links: [String: String] = [:]
        for entry in entries {
            guard let parts = entry.components else { anyUnsafe = true; continue }
            if entry.kind == .symlink { links[parts.joined(separator: "/").lowercased()] = entry.linkTarget ?? "" }
            if entry.kind != .directory { nonFolders.insert(parts.joined(separator: "/")) }
            for i in 1..<max(parts.count, 1) { parents.insert(parts.prefix(i).joined(separator: "/")) }
        }
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
                if rawUnder(entry.rawPath) { rejected.append((entry, .unsafePath)) }
                continue
            }
            guard underRoots(parts) else { continue }
            let path = parts.joined(separator: "/")
            var reason: Rejection?
            if entry.kind == .special { reason = .specialFile }
            for i in 1..<max(parts.count, 1) where reason == nil {
                if nonFolders.contains(parts.prefix(i).joined(separator: "/")) { reason = .insideNonFolder }
            }
            if reason == nil, entry.kind == .symlink {
                if !ArchivePath.linkStaysInside(entry: parts, target: entry.linkTarget ?? "", base: baseParts,
                                                linkTarget: { links[$0.joined(separator: "/").lowercased()] }) { reason = .linkOutside }
            }
            if reason == nil, entry.kind == .hardlink {
                // A hard link must name another safe member inside the extracted tree.
                guard let target = entry.linkTarget, let t = ArchivePath.components(target),
                      t.count > baseParts.count, Array(t.prefix(baseParts.count)) == baseParts, underRoots(t) else {
                    rejected.append((entry, .linkOutside)); rejectedInScope = true; continue
                }
            }
            if reason == nil, entry.kind != .directory, parents.contains(path) { reason = .notAFolder }
            if reason == nil {
                let folded = path.lowercased()
                if let other = seenFolded[folded], other != path { reason = .caseDuplicate } else { seenFolded[folded] = path }
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
                if entry.kind == .file { total += max(entry.size ?? 0, 0) }
            }
            if entry.isEncrypted { encrypted = true }
        }

        // Fast path: no rejected entries in scope, so whole roots can be named (a pattern selects a subtree).
        let patterns: [String]
        if !rejectedInScope {
            patterns = everything ? [] : rootParts.map { $0.joined(separator: "/") }.map(BsdtarListing.literalPattern)
        } else {
            patterns = included.map { BsdtarListing.literalPattern($0.rawPath) }
        }
        return Plan(roots: roots, base: baseParts, included: included, rejected: rejected, folders: folders,
                    totalBytes: total, hasEncrypted: encrypted, patterns: patterns)
    }
}

/// Zip-bomb and disk-space guard (FE-170). Declared sizes are checked before anything is written;
/// the extraction itself is also stopped if it writes much more than declared (lying headers).
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

/// Checks what an extraction actually wrote before anything is moved into the destination
/// (defense in depth behind the plan): removes links that escape, special files and set-ID bits,
/// and copies the archive's download quarantine onto every extracted item, as Archive Utility does.
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
        // A manual walk with lstat: enumerators skip dangling links, which are exactly the ones to check.
        var pending: [(path: String, parts: [String])] = [(rootPath, [])]
        var links: [(path: String, parts: [String])] = []
        while let (folder, folderParts) = pending.popLast() {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                let parts = folderParts + [name]
                let relative = parts.joined(separator: "/")
                var info = Darwin.stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    // Judged after the walk, once every link is known (a link can escape through another).
                    links.append((path, parts))
                    continue
                case S_IFREG:
                    report.bytes += Int64(info.st_size)
                    if info.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0 { chmod(path, info.st_mode & 0o777) }
                    if info.st_mode & S_IRUSR == 0 { chmod(path, (info.st_mode & 0o777) | S_IRUSR | S_IWUSR) }
                case S_IFDIR:
                    // Folders must stay writable by their owner so the job can move and clean up.
                    let wanted = (info.st_mode & 0o777) | S_IRWXU
                    if info.st_mode & 0o7777 != wanted { chmod(path, wanted) }
                    pending.append((path, parts))
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
        func target(_ parts: [String]) -> String? {
            try? fm.destinationOfSymbolicLink(atPath: rootPath + "/" + parts.joined(separator: "/"))
        }
        var escaping: [(path: String, parts: [String])] = []
        for link in links {
            if !ArchivePath.linkStaysInside(entry: link.parts, target: target(link.parts) ?? "/", base: base, linkTarget: target) {
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
