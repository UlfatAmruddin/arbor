import Foundation

/// The pane's tag list (FE-081). Independent of insertion order: Spotlight's isn't stable, and an equal catalog must not reload the tree.
public struct TagCatalog: Equatable, Sendable {
    public static let maxCustomTags = 200
    /// `NSWorkspace.fileLabels` indices: Red, Orange, Yellow, Green, Blue, Purple, Gray.
    static let sidebarOrder = [6, 7, 5, 2, 4, 3, 1]

    public private(set) var system: [FinderTag] = []
    private var systemKeys: Set<String> = []
    private var customs: [String: FinderTag] = [:]
    /// The largest key kept once the cap is reached; anything at or past it can't enter.
    private var cutoff: String?

    /// `labels` is `NSWorkspace.fileLabels`; index 0 is "None", and the length is not assumed.
    public init(systemLabels labels: [String]) {
        for index in Self.sidebarOrder where labels.indices.contains(index) {
            let name = labels[index]
            guard TagCollectionQuery.request(for: name) != nil, systemKeys.insert(Self.key(name)).inserted else { continue }
            system.append(FinderTag(name: name, colorIndex: index))
        }
    }

    /// Same folding as the search match, so two rows can never show the same set of files.
    static func key(_ name: String) -> String { String(TextMatcher.fold(name)) }

    public var custom: [FinderTag] { customs.values.sorted { Self.precedes($0.name, $1.name) } }
    public var tags: [FinderTag] { system + custom }

    public var systemOnly: TagCatalog {
        var copy = self
        copy.customs = [:]
        copy.cutoff = nil
        return copy
    }

    public func tag(named name: String) -> FinderTag? {
        let key = Self.key(name)
        return customs[key] ?? system.first { Self.key($0.name) == key }
    }

    /// True for a listed custom tag whose colour is still unknown.
    public func needsColor(_ name: String) -> Bool { customs[Self.key(name)]?.colorIndex == 0 }

    public func merging(_ other: TagCatalog) -> TagCatalog {
        var result = self
        other.customs.values.forEach { result.insert($0) }
        return result
    }

    /// The same custom tags over new system labels (Finder's labels were renamed).
    public func rebased(onSystemLabels labels: [String]) -> TagCatalog {
        TagCatalog(systemLabels: labels).merging(self)
    }

    /// Cheap checks first: names repeat across files, so most inserts never reach the parser.
    public mutating func insert(_ tag: FinderTag) {
        guard !tag.name.isEmpty, tag.name.utf8.count <= TagCollectionQuery.maxNameBytes else { return }
        let key = Self.key(tag.name)
        guard !systemKeys.contains(key) else { return }
        if let existing = customs[key], existing.name == tag.name {
            customs[key] = Self.merged(existing, tag)
            return
        }
        // Keeps the lowest keys, so which names survive doesn't depend on which arrived first.
        if customs[key] == nil, let cutoff, key >= cutoff { return }
        guard TagCollectionQuery.request(for: tag.name) != nil else { return }
        customs[key] = customs[key].map { Self.merged($0, tag) } ?? tag
        if customs.count > Self.maxCustomTags, let largest = customs.keys.max() { customs[largest] = nil }
        if customs.count == Self.maxCustomTags { cutoff = customs.keys.max() }
    }

    /// One spelling and colour per name, whichever file came first: lowest spelling, highest colour number.
    private static func merged(_ a: FinderTag, _ b: FinderTag) -> FinderTag {
        FinderTag(name: precedes(b.name, a.name) ? b.name : a.name, colorIndex: max(a.colorIndex, b.colorIndex))
    }

    private static func precedes(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a < b
        }
    }
}
