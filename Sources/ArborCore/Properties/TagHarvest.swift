import Foundation

/// Builds a catalog from Spotlight's answers; colour reads grow with distinct names, not tagged files (FE-081, FE-207).
public struct TagHarvest: Sendable {
    public static let samplesPerName = 3
    public static let maxColorReads = TagCatalog.maxCustomTags * samplesPerName

    public private(set) var catalog: TagCatalog
    private var samples: [String: Int] = [:]
    private var readsLeft = TagHarvest.maxColorReads

    public init(catalog: TagCatalog) {
        self.catalog = catalog
    }

    /// Takes one file's tags. True when that file should be read once for colours.
    public mutating func add(_ tags: [FinderTag]) -> Bool {
        tags.forEach { catalog.insert($0) }
        guard readsLeft > 0 else { return false }
        var wanted = false
        for tag in tags where catalog.needsColor(tag.name) {
            let key = TagCatalog.key(tag.name)
            guard samples[key, default: 0] < Self.samplesPerName else { continue }
            samples[key, default: 0] += 1
            wanted = true
        }
        if wanted { readsLeft -= 1 }
        return wanted
    }

    public mutating func addColors(_ tags: [FinderTag]) {
        tags.forEach { catalog.insert($0) }
    }
}
