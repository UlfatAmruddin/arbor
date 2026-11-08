import Foundation

public enum RenameError: Error, Equatable, LocalizedError {
    case invalid(NameValidationError)
    case alreadyExists(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason.errorDescription
        case .alreadyExists(let name): return L10n.format("An item named “%@” already exists in this folder.", "\(name)")
        case .failed(let message): return message
        }
    }
}

public enum Renamer {
    /// Renames in place. Never overwrites another item. Supports case-only renames on
    /// case-insensitive volumes (FE-224) by going through a temporary name.
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        if let problem = NameRules.validate(newName) { throw RenameError.invalid(problem) }
        let oldName = url.lastPathComponent
        if newName == oldName { return url }
        let folder = url.deletingLastPathComponent()
        let destination = folder.appendingPathComponent(newName)

        if FileOps.exists(destination) {
            // Same object reached by a differently-cased (or normalized) name?
            guard FileOps.isSameObject(url, destination) else { throw RenameError.alreadyExists(newName) }
            let temp = folder.appendingPathComponent(".arbor-rename-\(UUID().uuidString)")
            do { try fileManager.moveItem(at: url, to: temp) } catch {
                throw RenameError.failed(error.localizedDescription)
            }
            do { try fileManager.moveItem(at: temp, to: destination) } catch {
                try? fileManager.moveItem(at: temp, to: url)
                throw RenameError.failed(error.localizedDescription)
            }
            return destination
        }

        do { try fileManager.moveItem(at: url, to: destination) } catch {
            throw RenameError.failed(error.localizedDescription)
        }
        return destination
    }
}

/// Small filesystem helpers that do not follow symbolic links.
public enum FileOps {
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public static func isSameObject(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// True for real folders (not packages, not symlinks).
    public static func isPlainFolder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { return false }
        return (v.isDirectory ?? false) && !(v.isPackage ?? false) && !(v.isSymbolicLink ?? false)
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    /// True if `folder` is `item` or lies inside it.
    public static func isSameOrInside(_ folder: URL, _ item: URL) -> Bool {
        let f = folder.standardizedFileURL.path
        let i = item.standardizedFileURL.path
        return f == i || f.hasPrefix(i.hasSuffix("/") ? i : i + "/")
    }

    /// The path as the file system stores it: symbolic links in the parent folders resolved and the
    /// last component spelled as on disk (letter case, Unicode normalization). The last component
    /// itself is not followed. For comparing locations that may be typed or reached differently
    /// (`~/desktop` vs `~/Desktop`, `/tmp` vs `/private/tmp`). Touches the disk.
    public static func canonicalPath(_ url: URL) -> String {
        let url = url.standardizedFileURL
        guard url.path != "/" else { return "/" }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.nameKey]).name) ?? url.lastPathComponent
        return parent.appendingPathComponent(name).path
    }

    /// True if `a` and `b` are the same directory entry reached through different spellings.
    /// (Two hard links to one file are different entries.)
    public static func isSameEntry(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL == b.standardizedFileURL { return exists(a) }
        return isSameObject(a, b) && canonicalPath(a) == canonicalPath(b)
    }

    /// `isSameOrInside` after resolving how both are spelled: `folder` fully (it is written into),
    /// `item` without following its last component. Touches the disk.
    public static func isSameOrInsideOnDisk(_ folder: URL, _ item: URL) -> Bool {
        if isSameOrInside(folder, item) { return true }
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let i = canonicalPath(item)
        return f == i || f.hasPrefix(i.hasSuffix("/") ? i : i + "/")
    }

    /// Folder contents ignoring Finder's view-settings file.
    public static func isEffectivelyEmpty(_ folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }
}
