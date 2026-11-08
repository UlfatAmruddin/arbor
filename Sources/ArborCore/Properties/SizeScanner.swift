import Foundation

/// Selection size and counts, computed on demand, never pre-scanned (spec §15.3).
public struct SizeTotals: Equatable, Sendable {
    public var size: Int64 = 0
    /// Allocated blocks, including resource forks and metadata.
    public var sizeOnDisk: Int64 = 0
    /// Includes symbolic links (counted, not followed).
    public var files = 0
    /// Includes packages.
    public var folders = 0
    /// Folders without read permission; their contents are missing from the totals.
    public var unreadable = 0

    public init() {}

    public static func + (a: SizeTotals, b: SizeTotals) -> SizeTotals {
        var r = a
        r.size = r.size.saturatingAdd(b.size)
        r.sizeOnDisk = r.sizeOnDisk.saturatingAdd(b.sizeOnDisk)
        r.files += b.files
        r.folders += b.folders
        r.unreadable += b.unreadable
        return r
    }
}

public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

public enum SizeScanner {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileSizeKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// One item without descending; folders report 0.
    public static func entrySizes(_ url: URL) -> (size: Int64, onDisk: Int64, isDirectory: Bool, isLink: Bool) {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isLink = v?.isSymbolicLink ?? false
        let isDir = !isLink && (v?.isDirectory ?? false)
        let size = Int64(v?.fileSize ?? v?.totalFileSize ?? 0)
        let onDisk = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        return (isDir ? 0 : size, isDir ? 0 : onDisk, isDir, isLink)
    }

    /// Runs on the caller's queue and never follows links. Top-level items are not counted in
    /// `files`/`folders` (Explorer's "Contains"); `progress` fires at most every `interval`.
    public static func scan(_ urls: [URL], cancel: ScanCancellation, interval: TimeInterval = 0.1,
                            progress: ((SizeTotals) -> Void)? = nil) -> SizeTotals {
        var totals = SizeTotals()
        var last = Date()
        func tick() {
            guard let progress, Date().timeIntervalSince(last) >= interval else { return }
            last = Date()
            progress(totals)
        }
        let fm = FileManager.default
        for url in urls {
            if cancel.isCancelled { break }
            let top = entrySizes(url)
            totals.size = totals.size.saturatingAdd(top.size)
            totals.sizeOnDisk = totals.sizeOnDisk.saturatingAdd(top.onDisk)
            guard top.isDirectory else { continue }
            var unreadable = 0
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) { _, _ in
                unreadable += 1
                return true
            }
            while let next = enumerator?.nextObject() as? URL {
                if cancel.isCancelled { break }
                let entry = entrySizes(next)
                if entry.isDirectory {
                    totals.folders += 1
                } else {
                    totals.files += 1
                    totals.size = totals.size.saturatingAdd(entry.size)
                    totals.sizeOnDisk = totals.sizeOnDisk.saturatingAdd(entry.onDisk)
                }
                tick()
            }
            totals.unreadable += unreadable
        }
        return totals
    }
}
