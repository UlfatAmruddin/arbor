import Foundation

public enum ListingError: Error, Equatable, LocalizedError {
    case notFound(path: String)
    case permissionDenied(path: String)
    case notAFolder(path: String)
    case other(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "“\(path)” doesn't exist or is no longer available."
        case .permissionDenied(let path):
            return "You don't have permission to see the contents of “\(path)”. You can grant access in System Settings → Privacy & Security."
        case .notAFolder(let path):
            return "“\(path)” is not a folder."
        case .other(_, let message):
            return message
        }
    }
}

/// Enumerates one folder level. Never recurses: disclosure arrows and folder sizes are not pre-scanned.
public enum DirectoryLister {
    public static func list(_ folder: URL, includeHidden: Bool, fileManager: FileManager = .default) throws -> [FileItem] {
        let path = folder.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ListingError.notFound(path: path)
        }
        guard isDirectory.boolValue else { throw ListingError.notAFolder(path: path) }
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            return urls.compactMap(FileItem.init(url:))
        } catch let error as NSError {
            throw map(error, path: path)
        }
    }

    /// Subfolders only, for the navigation tree.
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
