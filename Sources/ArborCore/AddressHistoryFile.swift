import Foundation

/// What loading the address history found.
public struct AddressHistoryLoad: Equatable, Sendable {
    public var entries: [RecentLocations.Entry] = []
    /// A newer Arbor wrote it: shown as far as it parses, and only Clear history replaces it.
    public var isNewerVersion = false
}

/// The versioned, tolerant format of AddressHistory.json. Damage just starts an empty list: a kept copy would outlive Clear history.
public enum AddressHistoryFile {
    public static let currentVersion = 1
    /// Holds a full list of the longest entries, escapes included.
    public static let byteLimit = 1 << 20

    /// Nil above `byteLimit`, which the next launch would refuse to read.
    public static func encoded(_ entries: [RecentLocations.Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Written(version: currentVersion, entries: entries.map(\.key))),
              data.count <= byteLimit else { return nil }
        return data
    }

    public static func parse(_ data: Data, limit: Int) -> AddressHistoryLoad {
        guard let document = try? JSONDecoder().decode(Stored.self, from: data) else { return AddressHistoryLoad() }
        var load = AddressHistoryLoad(isNewerVersion: document.version > currentVersion)
        var seen = Set<String>()
        for key in document.entries.lazy.compactMap(\.value) {
            guard load.entries.count < limit else { break }
            if seen.insert(key).inserted, let entry = RecentLocations.Entry(storedKey: key) { load.entries.append(entry) }
        }
        return load
    }

    /// Off the main thread. Reads this one file and nothing the entries name, which may be on a share that is gone.
    public static func load(at url: URL, limit: Int) -> AddressHistoryLoad {
        guard let handle = FileHandle.openRegularFile(atPath: url.path) else { return AddressHistoryLoad() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit + 1), data.count <= byteLimit else { return AddressHistoryLoad() }
        return parse(data, limit: limit)
    }

    private struct Written: Encodable {
        let version: Int
        let entries: [String]
    }

    private struct Stored: Decodable {
        let version: Int
        let entries: [WorkspaceFile.Lossy<String>]

        private enum Keys: String, CodingKey { case version, entries }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            version = (try? values.decode(Int.self, forKey: .version)) ?? currentVersion
            entries = (try? values.decode([WorkspaceFile.Lossy<String>].self, forKey: .entries)) ?? []
        }
    }
}
