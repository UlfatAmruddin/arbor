import Foundation

public enum ListingError: Error, Equatable, LocalizedError {
    case notFound(path: String)
    case permissionDenied(path: String)
    case notAFolder(path: String)
    case other(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return L10n.format("“%@” doesn't exist or is no longer available.", "\(path)")
        case .permissionDenied(let path):
            return L10n.format("You don't have permission to see the contents of “%@”. You can grant access in System Settings → Privacy & Security.", "\(path)")
        case .notAFolder(let path):
            return L10n.format("“%@” is not a folder.", "\(path)")
        case .other(_, let message):
            return message
        }
    }
}

/// One folder level only: disclosure arrows and folder sizes are never pre-scanned.
public enum DirectoryLister {
    public static func list(_ folder: URL, includeHidden: Bool, fileManager: FileManager = .default) throws -> [FileItem] {
        let path = folder.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ListingError.notFound(path: path)
        }
        guard isDirectory.boolValue else { throw ListingError.notAFolder(path: path) }
        // Batched, not `contentsOfDirectory`, which holds every URL at once (~120 MB per 100k entries) and
        // never returns the memory (FE-228).
        var failure: NSError?
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: FileItem.resourceKeys, options: options,
                                                      errorHandler: { _, error in
                                                          if failure == nil { failure = error as NSError }
                                                          return false
                                                      }) else {
            throw ListingError.other(path: path, message: L10n.format("“%@” couldn't be read.", "\(path)"))
        }
        var items: [FileItem] = []
        var done = false
        while !done {
            autoreleasepool {
                var batch: [URL] = []
                batch.reserveCapacity(4_096)
                while batch.count < 4_096 {
                    guard let url = enumerator.nextObject() as? URL else { done = true; break }
                    batch.append(url)
                }
                items += makeItems(batch)
            }
        }
        if let failure, items.isEmpty { throw map(failure, path: path) }
        return items
    }

    /// Large folders in parallel chunks (reading values is about half the listing time); keeps order.
    static func makeItems(_ urls: [URL]) -> [FileItem] {
        guard urls.count >= 4_000 else { return urls.compactMap(FileItem.init(url:)) }
        let chunks = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let size = (urls.count + chunks - 1) / chunks
        final class Parts: @unchecked Sendable {
            var lists: [[FileItem]]
            let lock = NSLock()
            init(_ n: Int) { lists = Array(repeating: [], count: n) }
        }
        let parts = Parts(chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let range = min(urls.count, c * size)..<min(urls.count, (c + 1) * size)
            let made = urls[range].compactMap(FileItem.init(url:))
            parts.lock.withLock { parts.lists[c] = made }
        }
        return parts.lists.flatMap { $0 }
    }

    /// For the navigation tree.
    public static func subfolders(of folder: URL, includeHidden: Bool) throws -> [FileItem] {
        try list(folder, includeHidden: includeHidden)
            .filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func map(_ error: NSError, path: String) -> ListingError {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError: return .permissionDenied(path: path)
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound(path: path)
            default: break
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EACCES) || underlying.code == Int(EPERM) {
            return .permissionDenied(path: path)
        }
        return .other(path: path, message: error.localizedDescription)
    }
}
