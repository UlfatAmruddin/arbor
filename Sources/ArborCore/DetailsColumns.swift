import Foundation
import UniformTypeIdentifiers

/// A Details column (FE-035, FE-036). `SortKey` raw values are column ids too.
public struct ColumnID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    // From the listing.
    public static let name: ColumnID = "name"
    public static let dateModified: ColumnID = "dateModified"
    public static let type: ColumnID = "type"
    public static let size: ColumnID = "size"
    // File-system attributes, read lazily.
    public static let dateCreated: ColumnID = "dateCreated"
    public static let dateAccessed: ColumnID = "dateAccessed"
    public static let sizeOnDisk: ColumnID = "sizeOnDisk"
    public static let tags: ColumnID = "tags"
    // Content metadata, read lazily.
    public static let itemDate: ColumnID = "itemDate"
    public static let dimensions: ColumnID = "dimensions"
    public static let width: ColumnID = "width"
    public static let height: ColumnID = "height"
    public static let dateTaken: ColumnID = "dateTaken"
    public static let cameraModel: ColumnID = "cameraModel"
    public static let length: ColumnID = "length"
    public static let bitRate: ColumnID = "bitRate"
    public static let title: ColumnID = "title"
    public static let authors: ColumnID = "authors"
    public static let artists: ColumnID = "artists"
    public static let album: ColumnID = "album"
    public static let trackNumber: ColumnID = "trackNumber"
    public static let genre: ColumnID = "genre"
    public static let year: ColumnID = "year"
    public static let pages: ColumnID = "pages"
    public static let comments: ColumnID = "comments"
    /// Which folder an item lives in (libraries merge several).
    public static let folder: ColumnID = "folder"
}

/// One cell's value; empty, unknown and unsupported stay distinct (spec §6.2, §16.1).
/// Loading is the absence of a value in `ColumnValueStore`.
public enum ColumnValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    case bytes(Int64)
    /// Seconds.
    case duration(Double)
    /// Bits per second.
    case bitRate(Double)
    case dimensions(width: Int, height: Int)
    case list([String])
    /// Applies, but the item has none (no tags).
    case empty
    /// Applies but couldn't be read.
    case unknown
    /// Doesn't apply (Dimensions of a text file).
    case unsupported

    public var hasValue: Bool {
        switch self {
        case .empty, .unknown, .unsupported: return false
        case .list(let l): return !l.isEmpty
        case .text(let t): return !t.isEmpty
        default: return true
        }
    }
}

/// Buckets for grouping and header filters (windows11-reference.md §6.1).
public enum GroupStyle: String, Sendable {
    /// A – H · I – P · Q – Z · 0 – 9 · Other.
    case alphabet
    /// Today · Yesterday · Earlier this week · … · A long time ago.
    case date
    /// Empty · Tiny · Small · Medium · Large · Huge · Gigantic.
    case size
    /// Very short · Short · Medium · Long · Very long.
    case duration
    case distinct
}

public enum ColumnSource: Sendable {
    /// In `FileItem`; no I/O.
    case listing
    /// One stat/xattr read per item, off the main thread.
    case fileSystem
    /// Spotlight or file parsing, off the main thread.
    case content
}

/// Everything the Details view needs about a column (spec §6.2).
public struct ColumnDescriptor: Sendable {
    public let id: ColumnID
    public let title: String
    public let width: Double
    public let minWidth: Double
    public let alignRight: Bool
    public let source: ColumnSource
    public let groupStyle: GroupStyle
    /// Listed in the header's right-click checklist.
    public let isCommon: Bool
    /// Choose Details search synonyms ("duration" finds Length).
    public let keywords: [String]
    /// For `.listing` columns; others are read by `MetadataReader`.
    public let listingValue: (@Sendable (FileItem) -> ColumnValue)?
    /// Long paths keep both ends readable.
    public let truncatesMiddle: Bool
    /// A cell's tooltip when it has no state to report.
    public let toolTip: (@Sendable (FileItem) -> String)?

    public init(id: ColumnID, title: String, width: Double, minWidth: Double = 50, alignRight: Bool = false,
                source: ColumnSource, groupStyle: GroupStyle, isCommon: Bool = false, keywords: [String] = [],
                listingValue: (@Sendable (FileItem) -> ColumnValue)? = nil, truncatesMiddle: Bool = false,
                toolTip: (@Sendable (FileItem) -> String)? = nil) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.alignRight = alignRight
        self.source = source
        self.groupStyle = groupStyle
        self.isCommon = isCommon
        self.keywords = keywords
        self.listingValue = listingValue
        self.truncatesMiddle = truncatesMiddle
        self.toolTip = toolTip
    }
}

/// All Details columns; features add their own via `register` (e.g. Trash's "Date deleted").
public enum ColumnCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: [ColumnDescriptor] = builtIn

    public static var all: [ColumnDescriptor] { lock.lock(); defer { lock.unlock() }; return registered }

    public static func descriptor(_ id: ColumnID) -> ColumnDescriptor? { all.first { $0.id == id } }

    public static func register(_ descriptor: ColumnDescriptor) {
        lock.lock(); defer { lock.unlock() }
        registered.removeAll { $0.id == descriptor.id }
        registered.append(descriptor)
    }

    public static func title(_ id: ColumnID) -> String { descriptor(id).map { L10n.tr($0.title) } ?? id.rawValue }

    public static func needsLoading(_ id: ColumnID) -> Bool { (descriptor(id)?.source ?? .listing) != .listing }

    public static let builtIn: [ColumnDescriptor] = [
        ColumnDescriptor(id: .name, title: L10n.tr("Name"), width: 340, minWidth: 140, source: .listing, groupStyle: .alphabet,
                         isCommon: true, listingValue: { .text($0.name) }),
        ColumnDescriptor(id: .dateModified, title: L10n.tr("Date modified"), width: 160, minWidth: 90, source: .listing,
                         groupStyle: .date, isCommon: true, listingValue: { $0.modified.map(ColumnValue.date) ?? .unknown }),
        ColumnDescriptor(id: .type, title: L10n.tr("Type"), width: 150, minWidth: 70, source: .listing, groupStyle: .distinct,
                         isCommon: true, keywords: ["kind", "item type"], listingValue: { .text($0.typeDescription) }),
        ColumnDescriptor(id: .size, title: L10n.tr("Size"), width: 90, minWidth: 55, alignRight: true, source: .listing,
                         groupStyle: .size, isCommon: true, listingValue: { item in
                             item.isFolder ? .unsupported : (item.size.map(ColumnValue.bytes) ?? .unknown) }),
        ColumnDescriptor(id: .dateCreated, title: L10n.tr("Date created"), width: 160, minWidth: 90, source: .fileSystem,
                         groupStyle: .date, isCommon: true),
        ColumnDescriptor(id: .dateAccessed, title: L10n.tr("Date accessed"), width: 160, minWidth: 90, source: .fileSystem,
                         groupStyle: .date, keywords: ["last opened"]),
        ColumnDescriptor(id: .sizeOnDisk, title: L10n.tr("Size on disk"), width: 100, minWidth: 55, alignRight: true,
                         source: .fileSystem, groupStyle: .size, keywords: ["allocated"]),
        ColumnDescriptor(id: .authors, title: L10n.tr("Authors"), width: 150, source: .content, groupStyle: .distinct,
                         isCommon: true, keywords: ["creator"]),
        ColumnDescriptor(id: .tags, title: L10n.tr("Tags"), width: 140, source: .fileSystem, groupStyle: .distinct,
                         isCommon: true, keywords: ["finder tags", "labels", "keywords"]),
        ColumnDescriptor(id: .title, title: L10n.tr("Title"), width: 180, source: .content, groupStyle: .alphabet, isCommon: true),
        ColumnDescriptor(id: .itemDate, title: L10n.tr("Date"), width: 160, minWidth: 90, source: .content, groupStyle: .date,
                         keywords: ["item date"]),
        ColumnDescriptor(id: .dimensions, title: L10n.tr("Dimensions"), width: 110, source: .content, groupStyle: .distinct,
                         keywords: ["resolution", "pixels"]),
        ColumnDescriptor(id: .width, title: L10n.tr("Width"), width: 80, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["pixels"]),
        ColumnDescriptor(id: .height, title: L10n.tr("Height"), width: 80, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["pixels"]),
        ColumnDescriptor(id: .dateTaken, title: L10n.tr("Date taken"), width: 160, minWidth: 90, source: .content, groupStyle: .date,
                         keywords: ["photo", "exif"]),
        ColumnDescriptor(id: .cameraModel, title: L10n.tr("Camera model"), width: 140, source: .content, groupStyle: .distinct,
                         keywords: ["photo", "exif"]),
        ColumnDescriptor(id: .length, title: L10n.tr("Length"), width: 90, alignRight: true, source: .content, groupStyle: .duration,
                         keywords: ["duration", "time"]),
        ColumnDescriptor(id: .bitRate, title: L10n.tr("Bit rate"), width: 90, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["kbps", "bitrate"]),
        ColumnDescriptor(id: .trackNumber, title: "#", width: 50, minWidth: 36, alignRight: true, source: .content,
                         groupStyle: .distinct, keywords: ["track", "number"]),
        ColumnDescriptor(id: .artists, title: L10n.tr("Contributing artists"), width: 170, source: .content, groupStyle: .distinct,
                         keywords: ["artist", "performer"]),
        ColumnDescriptor(id: .album, title: L10n.tr("Album"), width: 160, source: .content, groupStyle: .distinct),
        ColumnDescriptor(id: .genre, title: L10n.tr("Genre"), width: 110, source: .content, groupStyle: .distinct),
        ColumnDescriptor(id: .year, title: L10n.tr("Year"), width: 70, alignRight: true, source: .content, groupStyle: .distinct),
        ColumnDescriptor(id: .pages, title: L10n.tr("Pages"), width: 70, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["page count"]),
        ColumnDescriptor(id: .comments, title: L10n.tr("Comments"), width: 180, source: .content, groupStyle: .distinct,
                         keywords: ["finder comment"]),
        ColumnDescriptor(id: .folder, title: L10n.tr("Folder"), width: 280, minWidth: 80, source: .listing, groupStyle: .distinct,
                         keywords: ["location", "path"], listingValue: { .text(LibraryMerge.folderColumnText(for: $0.url)) },
                         truncatesMiddle: true, toolTip: { $0.url.deletingLastPathComponent().path }),
    ]
}

// MARK: - Values and formatting

/// Values for non-listing columns; nil while loading.
public typealias ColumnValueLookup = (FileItem, ColumnID) -> ColumnValue?

public enum ColumnValues {
    /// From the listing, else `lookup` (nil = loading).
    public static func value(_ item: FileItem, _ column: ColumnID, lookup: ColumnValueLookup?) -> ColumnValue? {
        if let d = ColumnCatalog.descriptor(column), let listing = d.listingValue { return listing(item) }
        return lookup?(item, column)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Loading "…", unknown "—", empty and unsupported blank, as in Explorer.
    public static func text(_ value: ColumnValue?, column: ColumnID = "") -> String {
        guard let value else { return "…" }
        switch value {
        case .text(let s): return s
        case .number(let n):
            if column == .year { return Int(checked: n).map(String.init) ?? "" }
            return integer.string(from: NSNumber(value: n)) ?? "\(n)"
        case .date(let d): return dateFormatter.string(from: d)
        case .bytes(let b): return ExplorerSize.detailsColumn(b)   // always KB
        case .duration(let s): return durationText(s)
        case .bitRate(let b): return Int(checked: (b / 1000).rounded()).map { "\($0)kbps" } ?? ""
        case .dimensions(let w, let h): return "\(w) x \(h)"
        case .list(let l): return l.joined(separator: "; ")
        case .empty, .unsupported: return ""
        case .unknown: return "—"
        }
    }

    /// hh:mm:ss, as Explorer's Length.
    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// For VoiceOver and tooltips.
    public static func stateDescription(_ value: ColumnValue?) -> String? {
        switch value {
        case nil: return L10n.tr("Loading…")
        case .unknown?: return L10n.tr("Unknown: this information couldn't be read")
        case .unsupported?: return L10n.tr("Not available for this kind of item")
        case .empty?: return L10n.tr("None")
        default: return nil
        }
    }

    /// nil sorts last in both directions.
    public enum SortValue: Comparable {
        case number(Double)
        case text(String)

        public static func < (a: SortValue, b: SortValue) -> Bool {
            switch (a, b) {
            case let (.number(x), .number(y)): return x < y
            case let (.text(x), .text(y)): return x.localizedStandardCompare(y) == .orderedAscending
            case (.number, .text): return true
            case (.text, .number): return false
            }
        }
    }

    public static func sortValue(_ value: ColumnValue?) -> SortValue? {
        guard let value, value.hasValue else { return nil }
        switch value {
        case .text(let s): return .text(s)
        case .number(let n), .duration(let n), .bitRate(let n): return .number(n)
        case .date(let d): return .number(d.timeIntervalSinceReferenceDate)
        case .bytes(let b): return .number(Double(b))
        case .dimensions(let w, let h): return .number(Double(w) * Double(h))
        case .list(let l): return .text(l.joined(separator: "; "))
        case .empty, .unknown, .unsupported: return nil
        }
    }
}

// MARK: - Column sets per folder kind (FE-040)

/// Explorer's "Optimize this folder for" templates, plus Downloads.
public enum FolderKind: String, CaseIterable, Sendable, Codable {
    case general, documents, pictures, music, videos, downloads

    public var title: String {
        switch self {
        case .general: return L10n.tr("General items")
        case .documents: return L10n.tr("Documents")
        case .pictures: return L10n.tr("Pictures")
        case .music: return L10n.tr("Music")
        case .videos: return L10n.tr("Videos")
        case .downloads: return L10n.tr("Downloads")
        }
    }

    /// RECALL-m: 3+ files, 70 %+ pictures, music or videos, by extension only (no I/O); else nil.
    public static func discover(_ items: [FileItem]) -> FolderKind? {
        let files = items.filter { !$0.isFolder }
        guard files.count >= 3 else { return nil }
        var counts: [FolderKind: Int] = [:]
        for file in files {
            guard let type = UTType(filenameExtension: file.url.pathExtension) else { continue }
            if type.conforms(to: .image) { counts[.pictures, default: 0] += 1 }
            else if type.conforms(to: .audio) { counts[.music, default: 0] += 1 }
            else if type.conforms(to: .movie) { counts[.videos, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), Double(best.value) >= Double(files.count) * 0.7 else { return nil }
        return best.key
    }
}

public struct ColumnSpec: Equatable, Sendable, Codable {
    public var id: ColumnID
    public var width: Double
    public init(_ id: ColumnID, width: Double? = nil) {
        self.id = id
        self.width = width ?? ColumnCatalog.descriptor(id)?.width ?? 120
    }
}

/// Ordered Details columns plus default grouping; Name is always first and can't be hidden.
public struct ColumnSet: Equatable, Sendable, Codable {
    public var columns: [ColumnSpec]
    /// nil = no grouping.
    public var groupBy: ColumnID?
    public var groupAscending: Bool

    public init(_ columns: [ColumnSpec], groupBy: ColumnID? = nil, groupAscending: Bool = true) {
        self.columns = columns
        self.groupBy = groupBy
        self.groupAscending = groupAscending
        normalize()
    }

    public init(ids: [ColumnID], groupBy: ColumnID? = nil, groupAscending: Bool = true) {
        self.init(ids.map { ColumnSpec($0) }, groupBy: groupBy, groupAscending: groupAscending)
    }

    public var ids: [ColumnID] { columns.map(\.id) }
    public func contains(_ id: ColumnID) -> Bool { columns.contains { $0.id == id } }
    public func width(of id: ColumnID) -> Double? { columns.first { $0.id == id }?.width }

    /// Name first, no duplicates.
    public mutating func normalize() {
        var seen = Set<ColumnID>()
        columns = columns.filter { seen.insert($0.id).inserted }
        if let i = columns.firstIndex(where: { $0.id == .name }) {
            if i != 0 { columns.insert(columns.remove(at: i), at: 0) }
        } else {
            columns.insert(ColumnSpec(.name), at: 0)
        }
    }

    /// Hiding Name is ignored; shown columns are appended.
    public mutating func setVisible(_ id: ColumnID, _ visible: Bool) {
        if visible {
            if !contains(id) { columns.append(ColumnSpec(id)) }
        } else if id != .name {
            columns.removeAll { $0.id == id }
        }
    }

    public mutating func setWidth(_ width: Double, of id: ColumnID) {
        if let i = columns.firstIndex(where: { $0.id == id }) { columns[i].width = width }
    }

    /// Name stays first.
    public mutating func move(_ id: ColumnID, to index: Int) {
        guard id != .name, let from = columns.firstIndex(where: { $0.id == id }) else { return }
        let spec = columns.remove(at: from)
        columns.insert(spec, at: min(max(index, 1), columns.count))
    }

    /// windows11-reference.md §5.1.
    public static func defaults(for kind: FolderKind) -> ColumnSet {
        let general: [ColumnID] = [.name, .dateModified, .type, .size]
        switch kind {
        case .general, .documents: return ColumnSet(ids: general)
        case .pictures: return ColumnSet(ids: [.name, .itemDate, .type, .size, .tags, .dimensions])
        case .music: return ColumnSet(ids: [.name, .trackNumber, .title, .artists, .album])
        case .videos: return ColumnSet(ids: [.name, .itemDate, .type, .size, .length])
        case .downloads: return ColumnSet(ids: general, groupBy: .dateModified, groupAscending: false)
        }
    }
}
