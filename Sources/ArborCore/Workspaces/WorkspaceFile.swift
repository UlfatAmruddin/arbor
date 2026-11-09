import Foundation

/// What loading Workspaces.json found.
public struct WorkspaceLoad: Equatable, Sendable {
    public enum Issue: Equatable, Sendable {
        /// Not usable at all; moved aside when `copyKept`.
        case damaged(copyKept: Bool)
        /// Some entries were dropped; the original was copied aside when `copyKept`.
        case partial(skipped: Int, copyKept: Bool)
        /// Written by a newer Arbor: shown as far as it parses, never rewritten.
        case newerVersion
        /// Not a regular file, over the size limit, or the read failed: left untouched.
        case unreadable

        /// Rewriting the file now would destroy data no copy protects.
        public var isReadOnly: Bool {
            switch self {
            case .damaged(let copyKept), .partial(_, let copyKept): return !copyKept
            case .newerVersion, .unreadable: return true
            }
        }
    }

    public var list: WorkspaceList
    public var issue: Issue?

    public init(list: WorkspaceList = WorkspaceList(), issue: Issue? = nil) {
        self.list = list
        self.issue = issue
    }
}

/// The versioned, tolerant format of Workspaces.json (docs/features/workspaces.md). Keys are sorted, like Session.json.
public enum WorkspaceFile {
    public static let currentVersion = 1
    public static let byteLimit = 4 * 1024 * 1024
    public static let damagedCopyName = "Workspaces.damaged.json"

    public enum Parsed: Equatable, Sendable {
        /// `skipped` counts every entry the next save would lose: bad, over a limit or a repeated name.
        case loaded(WorkspaceList, skipped: Int)
        case newerVersion(WorkspaceList)
        case damaged
    }

    // MARK: Encoding

    /// Nil above `byteLimit`, which the next launch would refuse to read.
    public static func encoded(_ list: WorkspaceList) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Written(version: currentVersion, workspaces: list.workspaces)),
              data.count <= byteLimit else { return nil }
        return data
    }

    // MARK: Parsing

    public static func parse(_ data: Data) -> Parsed {
        guard let document = try? JSONDecoder().decode(Stored.self, from: data) else { return .damaged }
        let isNewer = document.version > currentVersion
        // A version 2 format migrates `document` here, before its entries are built.
        guard let stored = document.workspaces else { return isNewer ? .newerVersion(WorkspaceList()) : .damaged }
        let (list, skipped) = entries(of: stored)
        return isNewer ? .newerVersion(list) : .loaded(list, skipped: skipped)
    }

    private static func entries(of stored: [Lossy<Stored.Entry>]) -> (list: WorkspaceList, skipped: Int) {
        var accepted: [Workspace] = []
        var seenIDs = Set<String>()
        var skipped = 0
        for element in stored {
            guard let entry = element.value, accepted.count < WorkspaceList.limit,
                  let workspace = workspace(from: entry, seenIDs: &seenIDs),
                  !accepted.contains(where: { WorkspaceName.matches($0.name, workspace.name) }) else {
                skipped += 1
                continue
            }
            accepted.append(workspace)
            skipped += entry.tabs.count - workspace.tabs.count
        }
        return (WorkspaceList(validated: accepted), skipped)
    }

    private static func workspace(from stored: Stored.Entry, seenIDs: inout Set<String>) -> Workspace? {
        let readable = Workspace.filtered(stored.tabs, active: stored.activeTab) { $0.value != nil }
        var id = UUID().uuidString
        if let given = stored.id.flatMap(UUID.init(uuidString:))?.uuidString, !seenIDs.contains(given) { id = given }
        seenIDs.insert(id)
        return Workspace(id: id, name: stored.name, tabs: readable.items.compactMap(\.value), activeTab: readable.active)
    }

    // MARK: Disk

    /// Off the main thread. Sets aside whatever the next save would lose; if that fails the session is read-only.
    public static func load(at url: URL) -> WorkspaceLoad {
        let copy = url.deletingLastPathComponent().appendingPathComponent(damagedCopyName)
        switch readBytes(at: url) {
        case .absent:
            return WorkspaceLoad()
        case .unreadable:
            return WorkspaceLoad(issue: .unreadable)
        case .bytes(let data):
            switch parse(data) {
            case .damaged:
                // One rename: it replaces any old copy, never follows a symlink there, and leaves no window.
                return WorkspaceLoad(issue: .damaged(copyKept: Darwin.rename(url.path, copy.path) == 0))
            case .newerVersion(let list):
                return WorkspaceLoad(list: list, issue: .newerVersion)
            case .loaded(let list, skipped: 0):
                return WorkspaceLoad(list: list)
            case .loaded(let list, let skipped):
                let copied = (try? FolderViewStore.write(data, to: copy)) != nil
                return WorkspaceLoad(list: list, issue: .partial(skipped: skipped, copyKept: copied))
            }
        }
    }

    private enum Bytes {
        case absent
        case unreadable
        case bytes(Data)
    }

    private static func readBytes(at url: URL) -> Bytes {
        guard let handle = FileHandle.openRegularFile(atPath: url.path) else {
            // Not fileExists: it follows symlinks and would call a dangling one absent.
            var info = stat()
            return lstat(url.path, &info) != 0 && errno == ENOENT ? .absent : .unreadable
        }
        defer { try? handle.close() }
        do {
            // Nil means end of file, so an empty file reaches `parse` and is set aside like other damage.
            let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
            // Past the limit its version can't be read, and a newer Arbor's file must never be moved.
            return data.count <= byteLimit ? .bytes(data) : .unreadable
        } catch {
            return .unreadable
        }
    }

    // MARK: Wire types

    private struct Written: Encodable {
        let version: Int
        let workspaces: [Workspace]
    }

    /// One bad element is skipped and counted; its siblings survive.
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Value.self) }
    }

    /// Throws only when the top level isn't an object. A nil `workspaces` is damage, unless a newer version changed the format.
    private struct Stored: Decodable {
        let version: Int
        let workspaces: [Lossy<Entry>]?

        private enum Keys: String, CodingKey { case version, workspaces }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            version = (try? values.decode(Int.self, forKey: .version)) ?? 1
            workspaces = try? values.decode([Lossy<Entry>].self, forKey: .workspaces)
        }

        struct Entry: Decodable {
            let id: String?
            let name: String
            let tabs: [Lossy<SessionTab>]
            let activeTab: Int

            private enum Keys: String, CodingKey { case id, name, tabs, activeTab }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                name = try values.decode(String.self, forKey: .name)
                tabs = try values.decode([Lossy<SessionTab>].self, forKey: .tabs)
                id = try? values.decode(String.self, forKey: .id)
                activeTab = (try? values.decode(Int.self, forKey: .activeTab)) ?? 0
            }
        }
    }
}
