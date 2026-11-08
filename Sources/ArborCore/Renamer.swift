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
    /// Never overwrites; case-only renames go through a temp name (FE-224).
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        if let problem = NameRules.validate(newName) { throw RenameError.invalid(problem) }
        let oldName = url.lastPathComponent
        if newName == oldName { return url }
        let folder = url.deletingLastPathComponent()
        let destination = folder.appendingPathComponent(newName)

        if FileOps.exists(destination) {
            // Same object under a different case or normalization?
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

/// Filesystem helpers that do not follow symbolic links.
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

    /// Not packages or symlinks.
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

    /// Parent links resolved and last component spelled as on disk (not followed), for comparing
    /// `~/desktop` vs `~/Desktop` or `/tmp` vs `/private/tmp`. Touches the disk.
    public static func canonicalPath(_ url: URL) -> String {
        let url = url.standardizedFileURL
        guard url.path != "/" else { return "/" }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.nameKey]).name) ?? url.lastPathComponent
        return parent.appendingPathComponent(name).path
    }

    /// Same directory entry under different spellings; hard links are different entries.
    public static func isSameEntry(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL == b.standardizedFileURL { return exists(a) }
        return isSameObject(a, b) && canonicalPath(a) == canonicalPath(b)
    }

    /// Resolves `folder` fully (it is written into) and `item` without its last component. Touches the disk.
    public static func isSameOrInsideOnDisk(_ folder: URL, _ item: URL) -> Bool {
        if isSameOrInside(folder, item) { return true }
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let i = canonicalPath(item)
        return f == i || f.hasPrefix(i.hasSuffix("/") ? i : i + "/")
    }

    /// Ignores .DS_Store.
    public static func isEffectivelyEmpty(_ folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    /// Deletes `name` recursively relative to each folder's descriptor, never following links; 0 or an errno.
    public static func removeTree(_ name: String, in parent: Int32) -> Int32 {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return unlinkat(parent, name, 0) == 0 ? 0 : errno }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        guard let children = entryNames(of: fd) else { return errno }
        for child in children {
            let error = removeTree(child, in: fd)
            if error != 0 { return error }
        }
        return unlinkat(parent, name, AT_REMOVEDIR) == 0 ? 0 : errno
    }

    /// The names in the folder `fd` refers to, without "." and ".."; nil with errno set. `fd` stays open.
    public static func entryNames(of fd: Int32) -> [String]? {
        // A fresh open of "." has its own read position, so `fd` can be listed again.
        let own = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard own >= 0 else { return nil }
        guard let dir = fdopendir(own) else { let error = errno; close(own); errno = error; return nil }
        var names: [String] = []
        var error: Int32 = 0
        while true {
            errno = 0
            guard let entry = readdir(dir) else { error = errno; break }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        closedir(dir)
        errno = error
        return error == 0 ? names : nil
    }
}
