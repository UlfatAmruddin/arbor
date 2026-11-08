import Foundation
import UniformTypeIdentifiers

/// One member of an archive, as listed (never extracted to produce the listing).
public struct ArchiveEntry: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case file, directory, symlink, hardlink
        /// Device, FIFO or socket: never extracted.
        case special
    }

    /// The name exactly as the archive tool reports it. Extraction patterns are built from this.
    public var rawPath: String
    public var kind: Kind
    /// Uncompressed size; nil when unknown.
    public var size: Int64?
    /// Stored (compressed) size, known for ZIP.
    public var compressedSize: Int64?
    public var modified: Date?
    /// Symlink or hard-link target, as stored.
    public var linkTarget: String?
    public var isEncrypted: Bool
    /// The name bsdtar knows the member by, when Arbor reads it differently (a ZIP made on Windows, see
    /// `ZipNames`). Extraction patterns use this; nil = `rawPath`.
    public var storedPath: String?

    public init(rawPath: String, kind: Kind, size: Int64? = nil, compressedSize: Int64? = nil,
                modified: Date? = nil, linkTarget: String? = nil, isEncrypted: Bool = false) {
        self.rawPath = rawPath
        self.kind = kind
        self.size = size
        self.compressedSize = compressedSize
        self.modified = modified
        self.linkTarget = linkTarget
        self.isEncrypted = isEncrypted
    }

    /// Path components after sanitizing, or nil if the name is unsafe (FE-170).
    public var components: [String]? { ArchivePath.components(rawPath) }
    /// "a/b/c" for safe names.
    public var path: String? { components?.joined(separator: "/") }
}

/// Entry-path sanitizer (FE-170). An entry is extracted only if its name stays inside the destination.
public enum ArchivePath {
    public enum Problem: String, Sendable, Equatable {
        case empty, absolute, parentReference, invalidCharacter, tooLong
    }

    /// Why a raw entry name is unsafe, or nil if it is fine.
    public static func problem(_ raw: String) -> Problem? {
        if raw.contains("\u{0}") { return .invalidCharacter }
        if raw.hasPrefix("/") { return .absolute }
        // "C:\x" or "C:/x": a drive-letter path from Windows tools is absolute too.
        let scalars = Array(raw.unicodeScalars.prefix(3))
        if scalars.count == 3, scalars[1] == ":", scalars[2] == "/" || scalars[2] == "\\",
           CharacterSet.letters.contains(scalars[0]) { return .absolute }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") { return .parentReference }
        let kept = parts.filter { $0 != "." }
        if kept.isEmpty { return .empty }
        if kept.contains(where: { $0.utf8.count > 255 }) { return .tooLong }
        return nil
    }

    /// Clean components ("./a//b/" → ["a", "b"]), or nil if the name is unsafe.
    public static func components(_ raw: String) -> [String]? {
        guard problem(raw) == nil else { return nil }
        return raw.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.map(String.init)
    }

    /// Whether a symlink stored at `entry` (components) with `target` resolves inside the tree rooted at
    /// `base` (components). Absolute targets are never safe.
    public static func linkStaysInside(entry: [String], target: String, base: [String] = []) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\u{0}") else { return false }
        guard entry.count > base.count, Array(entry.prefix(base.count)) == base else { return false }
        var resolved = Array(entry.dropLast())
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard resolved.count > base.count else { return false }
                resolved.removeLast()
            default: resolved.append(String(part))
            }
        }
        return resolved.count >= base.count
    }

    /// Like `linkStaysInside(entry:target:base:)`, but resolves the way the file system will: a component
    /// naming another link is replaced by that link's target before `..` is applied, so "self → ." makes
    /// "self/../x" point above the tree. `linkTarget` returns the target of the link at a path (components),
    /// or nil if that path isn't a link. Loops and long chains count as escaping.
    public static func linkStaysInside(entry: [String], target: String, base: [String] = [],
                                       linkTarget: ([String]) -> String?) -> Bool {
        guard entry.count > base.count, Array(entry.prefix(base.count)) == base else { return false }
        var expansions = 0
        func resolve(from folder: [String], _ target: String) -> [String]? {
            guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\u{0}") else { return nil }
            var resolved = folder
            for part in target.split(separator: "/", omittingEmptySubsequences: true) {
                switch part {
                case ".": continue
                case "..":
                    guard resolved.count > base.count else { return nil }
                    resolved.removeLast()
                default:
                    resolved.append(String(part))
                    if let next = linkTarget(resolved) {
                        expansions += 1
                        guard expansions <= 32 else { return nil }
                        resolved.removeLast()
                        guard let expanded = resolve(from: resolved, next) else { return nil }
                        resolved = expanded
                    }
                }
            }
            return resolved
        }
        guard let resolved = resolve(from: Array(entry.dropLast()), target) else { return false }
        return resolved.count >= base.count && Array(resolved.prefix(base.count)) == base
    }
}

/// A browsable tree built from a flat listing. Folders that only appear inside other entries'
/// paths ("a/b.txt" with no "a/" entry) are synthesized. Entries with unsafe names are kept out of
/// the tree and counted, so the UI can say they exist but won't be extracted.
public struct ArchiveIndex: Sendable {
    public struct Node: Sendable {
        public var name: String
        public var isDirectory: Bool
        /// The listed entry; nil for synthesized folders.
        public var entry: ArchiveEntry?
    }

    /// Children by folder path ("" = root), keyed by name.
    public private(set) var folders: [String: [String: Node]] = ["": [:]]
    public private(set) var unsafeCount = 0
    public private(set) var encryptedCount = 0
    public private(set) var entryCount = 0
    public private(set) var totalSize: Int64 = 0

    public init(entries: [ArchiveEntry]) {
        for entry in entries { add(entry) }
    }

    private mutating func add(_ entry: ArchiveEntry) {
        guard let parts = entry.components else { unsafeCount += 1; return }
        entryCount += 1
        if entry.isEncrypted { encryptedCount += 1 }
        if entry.kind == .file, let size = entry.size { totalSize += size }
        var folder = ""
        for (i, name) in parts.enumerated() {
            let isLast = i == parts.count - 1
            let path = folder.isEmpty ? name : folder + "/" + name
            if isLast {
                let isDirectory = entry.kind == .directory || folders[path] != nil
                folders[folder, default: [:]][name] = Node(name: name, isDirectory: isDirectory,
                                                          entry: isDirectory && entry.kind != .directory ? nil : entry)
                if isDirectory, folders[path] == nil { folders[path] = [:] }
            } else {
                if folders[folder]?[name]?.isDirectory != true {
                    // A synthesized folder; it also wins over a same-named file entry (malformed archive).
                    let existing = folders[folder]?[name]?.entry
                    folders[folder, default: [:]][name] = Node(name: name, isDirectory: true,
                                                              entry: existing?.kind == .directory ? existing : nil)
                }
                if folders[path] == nil { folders[path] = [:] }
            }
            folder = path
        }
    }

    /// The children of a folder inside the archive, or nil if there is no such folder.
    public func children(of path: String) -> [Node]? {
        let key = path.isEmpty ? "" : (ArchivePath.components(path)?.joined(separator: "/") ?? path)
        return folders[key].map { Array($0.values) }
    }

    public func node(at path: String) -> Node? {
        guard let parts = ArchivePath.components(path), let name = parts.last else { return nil }
        return folders[parts.dropLast().joined(separator: "/")]?[name]
    }

    /// Listing rows for a folder inside `archive`. Item URLs are `archive/inner/path`, which don't exist
    /// on disk; `ArchiveItemRef` maps them back.
    public func items(in path: String, archive: URL, includeHidden: Bool) -> [FileItem]? {
        guard let nodes = children(of: path) else { return nil }
        let folderPath = path.isEmpty ? "" : (ArchivePath.components(path)?.joined(separator: "/") ?? path)
        return nodes.compactMap { node in
            let hidden = node.name.hasPrefix(".")
            if hidden && !includeHidden { return nil }
            let inner = folderPath.isEmpty ? node.name : folderPath + "/" + node.name
            return FileItem(url: archive.appendingPathComponent(inner, isDirectory: node.isDirectory),
                            name: node.name, isFolder: node.isDirectory, isHidden: hidden,
                            isSymbolicLink: node.entry?.kind == .symlink,
                            size: node.isDirectory ? nil : node.entry?.size,
                            modified: node.entry?.modified,
                            typeDescription: ArchiveIndex.typeDescription(name: node.name, isDirectory: node.isDirectory))
        }
    }

    /// The system's kind name for a file extension (the same source the folder listing uses).
    public static func typeDescription(name: String, isDirectory: Bool) -> String {
        // System descriptions can be lower-case ("folder", "text"); the Type column capitalizes like Explorer.
        func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        if isDirectory { return capitalized(UTType.folder.localizedDescription ?? "Folder") }
        let ext = NameRules.splitExtension(name, treatAsFolder: false).ext ?? ""
        if let format = ArchiveFormat.detect(name: name) { return format.typeName }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let text = type.localizedDescription { return capitalized(text) }
        return ext.isEmpty ? L10n.tr("File") : L10n.format("%@ File", "\(ext.uppercased())")
    }

    /// Every entry at or below `path` ("" = all), safe names only.
    public static func entries(under path: String, from all: [ArchiveEntry]) -> [ArchiveEntry] {
        guard let prefix = path.isEmpty ? [] : ArchivePath.components(path) else { return [] }
        return all.filter { entry in
            guard let parts = entry.components, parts.count >= prefix.count else { return false }
            return Array(parts.prefix(prefix.count)) == prefix
        }
    }
}

/// Maps a listing row's URL (`/x/Archive.zip/inner/path`) back to its archive and inner path.
public struct ArchiveItemRef: Hashable, Sendable {
    public let archive: URL
    public let innerPath: String

    public init(archive: URL, innerPath: String) {
        self.archive = archive.standardizedFileURL
        self.innerPath = innerPath
    }

    /// Finds the archive by walking up to the first existing ancestor, which must be an archive file.
    public init?(url: URL, fileExists: (String) -> (exists: Bool, isDirectory: Bool) = ArchiveItemRef.stat) {
        var current = url.standardizedFileURL
        var inner: [String] = []
        while current.path != "/" {
            let state = fileExists(current.path)
            if state.exists {
                guard !state.isDirectory, !inner.isEmpty, ArchiveFormat.detect(current) != nil else { return nil }
                self.init(archive: current, innerPath: inner.reversed().joined(separator: "/"))
                return
            }
            inner.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    public static func stat(_ path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    public var name: String { innerPath.split(separator: "/").last.map(String.init) ?? archive.lastPathComponent }
    /// The folder inside the archive that holds this item.
    public var parentPath: String { innerPath.split(separator: "/").dropLast().joined(separator: "/") }
}
