import Foundation

/// One item the user asked to restore.
public struct RestoreCandidate: Sendable {
    public let trashedURL: URL
    public let isFolder: Bool
    public let record: TrashRecord?

    public init(trashedURL: URL, isFolder: Bool, record: TrashRecord?) {
        self.trashedURL = trashedURL
        self.isFolder = isFolder
        self.record = record
    }
}

/// What restoring one item will do (spec §12.4, §9.4).
public enum RestorePlan: Equatable, Sendable {
    /// Move back to `to`. `missingParents` are created first, outermost first (Windows recreates them).
    case restore(from: URL, to: URL, missingParents: [URL])
    /// The original location is taken (on disk or by an earlier item in this batch). `keepBoth` is a
    /// free name next to it ("Report (2).pdf"); the user chooses Keep both or Skip.
    case conflict(from: URL, to: URL, keepBoth: URL, missingParents: [URL])
    /// Arbor doesn't know where the item came from; it can't be restored here.
    case unknownOrigin(URL)

    public var source: URL {
        switch self {
        case .restore(let from, _, _), .conflict(let from, _, _, _): return from
        case .unknownOrigin(let url): return url
        }
    }
}

public enum TrashRestorePlanner {
    /// Plans a batch. `exists` is checked for destinations and parents; names already claimed by
    /// earlier items in the batch count as taken (compared case-insensitively, like APFS by default).
    public static func plan(_ candidates: [RestoreCandidate], exists: (URL) -> Bool) -> [RestorePlan] {
        var claimed = Set<String>()
        func taken(_ url: URL) -> Bool { exists(url) || claimed.contains(claimKey(url)) }

        return candidates.map { candidate in
            guard let record = candidate.record else { return .unknownOrigin(candidate.trashedURL) }
            let destination = record.originalURL.standardizedFileURL
            let folder = destination.deletingLastPathComponent()
            let parents = missingParents(of: folder, exists: exists)
            if !taken(destination) {
                claimed.insert(claimKey(destination))
                return .restore(from: candidate.trashedURL, to: destination, missingParents: parents)
            }
            let name = NameRules.keepBothName(for: destination.lastPathComponent, treatAsFolder: candidate.isFolder) {
                taken(folder.appendingPathComponent($0))
            }
            let keepBoth = folder.appendingPathComponent(name)
            claimed.insert(claimKey(keepBoth))
            return .conflict(from: candidate.trashedURL, to: destination, keepBoth: keepBoth, missingParents: parents)
        }
    }

    /// Folders between the nearest existing ancestor and `folder`, outermost first.
    public static func missingParents(of folder: URL, exists: (URL) -> Bool) -> [URL] {
        var missing: [URL] = []
        var current = folder.standardizedFileURL
        while current.path != "/", !exists(current) {
            missing.insert(current, at: 0)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return missing
    }

    private static func claimKey(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
}

public enum TrashRestoreError: Error, LocalizedError, Equatable {
    case destinationTaken(String)
    case notInTrash(String)

    public var errorDescription: String? {
        switch self {
        case .destinationTaken(let path): return "“\(path)” is already taken."
        case .notInTrash(let name): return "“\(name)” is no longer in the Trash."
        }
    }
}

/// Performs one restore. Never overwrites: if the destination appeared since planning, it throws.
public enum TrashRestorer {
    @discardableResult
    public static func restore(from trashed: URL, to destination: URL, missingParents: [URL],
                               journal: TrashJournal?, fileManager: FileManager = .default) throws -> URL {
        guard FileOps.exists(trashed) else { throw TrashRestoreError.notInTrash(trashed.lastPathComponent) }
        // Recreate the original folder chain if it's gone, like Windows does (`missingParents`, outermost first).
        let parent = destination.deletingLastPathComponent()
        if !missingParents.isEmpty || !FileOps.exists(parent) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        guard !FileOps.exists(destination) else { throw TrashRestoreError.destinationTaken(destination.path) }
        try fileManager.moveItem(at: trashed, to: destination)
        journal?.remove([trashed])
        return destination
    }
}

/// Names shown in the Trash list. Windows shows each item's original name; Arbor does the same when
/// it knows it and it's unambiguous, otherwise the item's name inside the Trash. Every name is
/// unique in the listing, because names identify rows.
public enum TrashNaming {
    public struct Entry: Sendable {
        public let onDisk: String
        public let original: String?
        /// Disambiguator for items in different Trash folders (the volume name).
        public let group: String
        public init(onDisk: String, original: String?, group: String) {
            self.onDisk = onDisk
            self.original = original
            self.group = group
        }
    }

    public static func displayNames(_ entries: [Entry]) -> [String] {
        func fold(_ s: String) -> String { s.lowercased() }
        var counts: [String: Int] = [:]
        for e in entries { counts[fold(e.original ?? e.onDisk), default: 0] += 1 }
        var names = entries.map { e -> String in
            if let original = e.original, counts[fold(original)] == 1 { return original }
            return e.onDisk
        }
        var used = Set<String>()
        for i in names.indices {
            var name = names[i]
            if used.contains(fold(name)) {
                let base = "\(name) (\(entries[i].group))"
                name = base
                var n = 2
                while used.contains(fold(name)) { name = "\(base) \(n)"; n += 1 }
            }
            used.insert(fold(name))
            names[i] = name
        }
        return names
    }
}
