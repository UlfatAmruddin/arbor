import Foundation
import UniformTypeIdentifiers

/// One member of an archive, as listed (never extracted to produce the listing).
public struct ArchiveEntry: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case file, directory, symlink, hardlink
        /// Device, FIFO or socket: never extracted.
        case special
        /// A type the listing doesn't name ("?" and others): never extracted.
        case unknown
    }

    /// Name exactly as the archive tool reports it; extraction patterns use this.
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
    /// bsdtar's name when Arbor reads it differently (Windows ZIPs, `ZipNames`); used by extraction. nil = `rawPath`.
    public var storedPath: String?

    /// Declared sizes are capped so sums over a listing can't overflow (2M entries × 2 TiB < Int64.max).
    public static let maxDeclaredSize: Int64 = 1 << 41

    public init(rawPath: String, kind: Kind, size: Int64? = nil, compressedSize: Int64? = nil,
                modified: Date? = nil, linkTarget: String? = nil, isEncrypted: Bool = false) {
        self.rawPath = rawPath
        self.kind = kind
        self.size = size.map { min(max($0, 0), Self.maxDeclaredSize) }
        self.compressedSize = compressedSize.map { min(max($0, 0), Self.maxDeclaredSize) }
        self.modified = modified
        self.linkTarget = linkTarget
        self.isEncrypted = isEncrypted
    }

    /// Path components after sanitizing, or nil if the name is unsafe (FE-170).
    public var components: [String]? { ArchivePath.components(rawPath) }
    /// "a/b/c" for safe names.
    public var path: String? { components?.joined(separator: "/") }

    /// Space saved as a whole percent (the Ratio column); nil when either size is unknown.
    public var savedPercent: Int? {
        guard let size, let packed = compressedSize else { return nil }
        guard size > 0 else { return 0 }
        // Clamped in Double first: an out-of-range value would trap in Int().
        return Int(min(max(100 - Double(packed) * 100 / Double(size), 0), 100).rounded())
    }
}

/// Entry-path sanitizer (FE-170). An entry is extracted only if its name stays inside the destination.
public enum ArchivePath {
    public enum Problem: String, Sendable, Equatable {
        case empty, absolute, parentReference, invalidCharacter, tooLong
    }

    /// PATH_MAX: longer names or link targets can't be used on disk, and would make per-prefix work costly.
    public static let maxPathBytes = 1024

    /// Why a raw entry name is unsafe, or nil if it is fine.
    public static func problem(_ raw: String) -> Problem? {
        if raw.utf8.count > maxPathBytes { return .tooLong }
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

    /// Whether a symlink at `entry` with `target` resolves inside `base` (all components); absolute targets never do.
    public static func linkStaysInside(entry: [String], target: String, base: [String] = []) -> Bool {
        guard target.utf8.count <= maxPathBytes, !target.isEmpty, !target.hasPrefix("/"), !target.contains("\u{0}") else { return false }
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
}

/// A browsable tree from a flat listing. Implied folders are synthesized; unsafe names are kept out
/// and counted so the UI can say they won't be extracted.
public struct ArchiveIndex: Sendable {
    public struct Node: Sendable {
        public var name: String
        public var isDirectory: Bool
        /// The listed entry; nil for synthesized folders.
        public var entry: ArchiveEntry?
    }

    /// Folders form a tree (id 0 = root), not full-path keys, so deep names cost linear memory.
    private struct Folder: Sendable {
        var nodes: [String: Node] = [:]
        var subfolders: [String: Int] = [:]
    }
    private var tree: [Folder] = [Folder()]
    /// Names that point outside the archive (absolute, `..`, invalid characters).
    public private(set) var unsafeCount = 0
    /// Names too long to extract.
    public private(set) var tooLongCount = 0
    /// Listing rows that couldn't be read (stand-ins with no name).
    public private(set) var unreadableCount = 0
    public private(set) var encryptedCount = 0
    public private(set) var entryCount = 0
    public private(set) var totalSize: Int64 = 0

    public init(entries: [ArchiveEntry]) {
        for entry in entries { add(entry) }
    }

    private mutating func add(_ entry: ArchiveEntry) {
        guard let parts = entry.components else {
            if entry.rawPath.isEmpty { unreadableCount += 1 } else if ArchivePath.problem(entry.rawPath) == .tooLong { tooLongCount += 1 } else { unsafeCount += 1 }
            return
        }
        entryCount += 1
        if entry.isEncrypted { encryptedCount += 1 }
        if entry.kind == .file, let size = entry.size { totalSize = totalSize.saturatingAdd(max(size, 0)) }
        var folder = 0
        for (i, name) in parts.enumerated() {
            if i == parts.count - 1 {
                let isDirectory = entry.kind == .directory || tree[folder].subfolders[name] != nil
                tree[folder].nodes[name] = Node(name: name, isDirectory: isDirectory,
                                                entry: isDirectory && entry.kind != .directory ? nil : entry)
                if isDirectory { _ = subfolder(name, in: folder) }
            } else {
                if tree[folder].nodes[name]?.isDirectory != true {
                    // A synthesized folder; it also wins over a same-named file entry (malformed archive).
                    let existing = tree[folder].nodes[name]?.entry
                    tree[folder].nodes[name] = Node(name: name, isDirectory: true,
                                                    entry: existing?.kind == .directory ? existing : nil)
                }
                folder = subfolder(name, in: folder)
            }
        }
    }

    private mutating func subfolder(_ name: String, in parent: Int) -> Int {
        if let id = tree[parent].subfolders[name] { return id }
        tree.append(Folder())
        tree[parent].subfolders[name] = tree.count - 1
        return tree.count - 1
    }

    private func folderID(_ parts: some Sequence<String>) -> Int? {
        var id = 0
        for part in parts {
            guard let next = tree[id].subfolders[part] else { return nil }
            id = next
        }
        return id
    }

    /// The children of a folder inside the archive, or nil if there is no such folder.
    public func children(of path: String) -> [Node]? {
        let parts = path.isEmpty ? [] : (ArchivePath.components(path) ?? path.split(separator: "/").map(String.init))
        return folderID(parts).map { Array(tree[$0].nodes.values) }
    }

    public func node(at path: String) -> Node? {
        guard let parts = ArchivePath.components(path), let name = parts.last else { return nil }
        return folderID(parts.dropLast()).flatMap { tree[$0].nodes[name] }
    }

    /// Listing rows for a folder in `archive`; URLs (`archive/inner/path`) don't exist on disk, see `ArchiveItemRef`.
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
        // System kind names can be lower-case; the Type column capitalizes like Explorer.
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
