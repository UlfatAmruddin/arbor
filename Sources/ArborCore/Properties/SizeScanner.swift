import Foundation

/// Logical size, allocated size ("Size on disk") and item counts of a selection, computed on demand
/// (spec §15.3: never pre-scanned). Runs on the caller's queue; report progress and cancel.
public struct SizeTotals: Equatable, Sendable {
    /// Sum of logical file sizes (bytes of content).
    public var size: Int64 = 0
    /// Sum of allocated sizes: blocks actually used, including resource forks and metadata.
    public var sizeOnDisk: Int64 = 0
    /// Files (and symbolic links, which are counted, not followed) found inside folders.
    public var files = 0
    /// Folders found inside folders (packages count as folders: they are folders on disk).
    public var folders = 0
    /// Folders that couldn't be read (no permission); their contents are missing from the totals.
    public var unreadable = 0

    public init() {}

    public static func + (a: SizeTotals, b: SizeTotals) -> SizeTotals {
        var r = a
        r.size += b.size
        r.sizeOnDisk += b.sizeOnDisk
        r.files += b.files
        r.folders += b.folders
        r.unreadable += b.unreadable
        return r
    }
}

/// A cancellation flag shared between the UI and a background scan.
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

    /// Size of one item without descending (a file, link, or an empty folder entry itself).
    public static func entrySizes(_ url: URL) -> (size: Int64, onDisk: Int64, isDirectory: Bool, isLink: Bool) {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isLink = v?.isSymbolicLink ?? false
        let isDir = !isLink && (v?.isDirectory ?? false)
        let size = Int64(v?.fileSize ?? v?.totalFileSize ?? 0)
        let onDisk = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        return (isDir ? 0 : size, isDir ? 0 : onDisk, isDir, isLink)
    }

    /// Totals for a selection. Folders (and packages) are walked recursively; symbolic links are never
    /// followed. `progress` is called at most every `interval` seconds with running totals.
    /// The top-level items themselves are not counted in `files`/`folders` (Explorer's "Contains").
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
            totals.size += top.size
            totals.sizeOnDisk += top.onDisk
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
                    totals.size += entry.size
                    totals.sizeOnDisk += entry.onDisk
                }
                tick()
            }
            totals.unreadable += unreadable
        }
        return totals
    }
}
