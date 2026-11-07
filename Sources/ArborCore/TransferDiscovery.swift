import Foundation

/// Item and byte totals for the "Discovering items…" phase (FE-114, spec §9.2).
/// Only counts are kept, never the item list, so memory stays flat for huge trees.
/// Symbolic links are counted as one item and never followed. Package contents count.
public struct TransferTotals: Sendable, Equatable {
    public var items: Int
    public var bytes: Int64

    public init(items: Int = 0, bytes: Int64 = 0) {
        self.items = items
        self.bytes = bytes
    }

    public static func + (a: TransferTotals, b: TransferTotals) -> TransferTotals {
        TransferTotals(items: a.items + b.items, bytes: a.bytes + b.bytes)
    }
}

public enum TransferDiscovery {
    /// Counts `url` and everything under it. Returns nil if cancelled. Unreadable subfolders
    /// count as what could be read; the copy reports them properly later.
    public static func measure(_ url: URL, control: TransferControl? = nil,
                               onProgress: ((TransferTotals) -> Void)? = nil) -> TransferTotals? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return TransferTotals() }
        var totals = TransferTotals(items: 1, bytes: (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0)
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return totals }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in true }) else { return totals }
        var tick = 0
        for case let child as URL in walker {
            tick += 1
            if tick % 256 == 0 {
                if control?.checkpoint() == false { return nil }
                onProgress?(totals)
            }
            totals.items += 1
            if let v = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true {
                totals.bytes += Int64(v.fileSize ?? 0)
            }
        }
        if control?.isCancelled == true { return nil }
        return totals
    }
}

/// Size, date and identity of one directory entry at one moment, read with lstat.
public struct FileStamp: Sendable, Equatable, Codable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modified: Date
    public let isFolder: Bool

    public init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        isFolder = (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Same object, same size, same modification time.
    public func sameState(as other: FileStamp?) -> Bool {
        guard let other else { return false }
        return device == other.device && inode == other.inode && size == other.size && modified == other.modified
    }
}

/// Enough to tell later whether a copy is still exactly what this app made (FE-129):
/// identity (device + inode), size and modification time of the item, plus, for folders,
/// an order-independent hash over every entry's relative path, inode, size and date.
/// ".DS_Store" files are ignored because Finder writes them just by looking.
public struct ItemFingerprint: Sendable, Equatable, Codable {
    public let stamp: FileStamp
    public let entries: Int
    public let treeHash: UInt64

    public static func of(_ url: URL) -> ItemFingerprint? {
        guard let stamp = FileStamp(url) else { return nil }
        guard stamp.isFolder else { return ItemFingerprint(stamp: stamp, entries: 1, treeHash: 0) }
        var entries = 0
        var hash: UInt64 = 0
        let base = url.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(atPath: base) else { return nil }
        while let relative = walker.nextObject() as? String {
            if (relative as NSString).lastPathComponent == ".DS_Store" { continue }
            guard let s = FileStamp(URL(fileURLWithPath: base + "/" + relative)) else { continue }
            entries += 1
            var h = fnv(relative)
            h = mix(h, s.inode)
            if !s.isFolder {
                h = mix(h, UInt64(bitPattern: s.size))
                h = mix(h, UInt64(bitPattern: Int64(s.modified.timeIntervalSince1970 * 1e6)))
            }
            hash &+= h
        }
        // The folder's own date changes when Finder adds .DS_Store, so only its identity counts.
        return ItemFingerprint(stamp: stamp, entries: entries, treeHash: hash)
    }

    public func matches(_ other: ItemFingerprint?) -> Bool {
        guard let other else { return false }
        guard stamp.device == other.stamp.device, stamp.inode == other.stamp.inode,
              stamp.isFolder == other.stamp.isFolder, entries == other.entries, treeHash == other.treeHash else { return false }
        return stamp.isFolder || (stamp.size == other.stamp.size && stamp.modified == other.stamp.modified)
    }

    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return h
    }

    private static func mix(_ h: UInt64, _ v: UInt64) -> UInt64 {
        var x = h ^ (v &+ 0x9e3779b97f4a7c15 &+ (h << 6) &+ (h >> 2))
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        return x ^ (x >> 31)
    }
}

/// Undo of a copy (FE-129): a copy is removed only if it is unchanged since it was made.
public enum CopyUndo {
    public struct Plan: Sendable, Equatable {
        public var unchanged: [URL] = []
        /// Edited, replaced or renamed since the copy: left alone.
        public var changed: [URL] = []
        /// Already gone.
        public var missing: [URL] = []
    }

    public static func plan(_ copies: [(url: URL, fingerprint: ItemFingerprint)]) -> Plan {
        var plan = Plan()
        for copy in copies {
            guard FileOps.exists(copy.url) else { plan.missing.append(copy.url); continue }
            if copy.fingerprint.matches(ItemFingerprint.of(copy.url)) {
                plan.unchanged.append(copy.url)
            } else {
                plan.changed.append(copy.url)
            }
        }
        return plan
    }
}
