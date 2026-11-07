import Foundation
import UniformTypeIdentifiers

/// Identifies a Details column (FE-035, FE-036). `SortKey` raw values are column ids too
/// ("name", "dateModified", "type", "size").
public struct ColumnID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    // From the listing (always in memory).
    public static let name: ColumnID = "name"
    public static let dateModified: ColumnID = "dateModified"
    public static let type: ColumnID = "type"
    public static let size: ColumnID = "size"
    // File-system attributes, read lazily.
    public static let dateCreated: ColumnID = "dateCreated"
    public static let dateAccessed: ColumnID = "dateAccessed"
    public static let sizeOnDisk: ColumnID = "sizeOnDisk"
    public static let tags: ColumnID = "tags"
    // Content metadata (Spotlight, ImageIO, AudioToolbox, AVFoundation), read lazily.
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
}

/// One cell's value. Absent metadata, unsupported metadata and still-loading metadata are kept
/// apart (spec §6.2, §16.1): loading is the absence of a value in `ColumnValueStore`.
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
    /// The property applies to this item, which simply has none (an untitled document, no tags).
    case empty
    /// The property applies but couldn't be read (damaged image, unreadable file).
    case unknown
    /// The property doesn't apply to this kind of item (Dimensions of a text file).
    case unsupported

    /// True for values that carry data.
    public var hasValue: Bool {
        switch self {
        case .empty, .unknown, .unsupported: return false
        case .list(let l): return !l.isEmpty
        case .text(let t): return !t.isEmpty
        default: return true
        }
    }
}

/// How a column's values are bucketed for grouping and header filters (docs/research/windows11-reference.md §6.1).
public enum GroupStyle: String, Sendable {
    /// A – H · I – P · Q – Z · 0 – 9 · Other.
    case alphabet
    /// Today · Yesterday · Earlier this week · … · A long time ago.
    case date
    /// Empty · Tiny · Small · Medium · Large · Huge · Gigantic.
    case size
    /// Very short · Short · Medium · Long · Very long.
    case duration
    /// One group per distinct value.
    case distinct
}

/// Where a column's values come from.
public enum ColumnSource: Sendable {
    /// Already in `FileItem` (no I/O).
    case listing
    /// File-system attributes (one stat/xattr read per item, off the main thread).
    case fileSystem
    /// Content metadata (Spotlight or file parsing, off the main thread).
    case content
}

/// Everything the Details view needs to know about a column (spec §6.2: key, label, value state,
/// formatter, width/minimum, alignment, sortable/filterable, fetch policy).
public struct ColumnDescriptor: Sendable {
    public let id: ColumnID
    public let title: String
    public let width: Double
    public let minWidth: Double
    public let alignRight: Bool
    public let source: ColumnSource
    public let groupStyle: GroupStyle
    /// Listed in the header's right-click checklist (Windows: Name, Date modified, Type, Size,
    /// Date created, Authors, Tags, Title).
    public let isCommon: Bool
    /// Extra words the Choose Details search box matches ("duration" finds Length).
    public let keywords: [String]
    /// Value for `.listing` columns; other sources are read by `MetadataReader`.
    public let listingValue: (@Sendable (FileItem) -> ColumnValue)?

    public init(id: ColumnID, title: String, width: Double, minWidth: Double = 50, alignRight: Bool = false,
                source: ColumnSource, groupStyle: GroupStyle, isCommon: Bool = false, keywords: [String] = [],
                listingValue: (@Sendable (FileItem) -> ColumnValue)? = nil) {
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
    }
}

/// All columns the Details view can show. Features may add their own (e.g. Trash's "Date deleted"
/// with a `listingValue`): `ColumnCatalog.register(...)`.
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

    public static func title(_ id: ColumnID) -> String { descriptor(id)?.title ?? id.rawValue }

    /// Columns read from the listing never need loading.
    public static func needsLoading(_ id: ColumnID) -> Bool { (descriptor(id)?.source ?? .listing) != .listing }

    public static let builtIn: [ColumnDescriptor] = [
        ColumnDescriptor(id: .name, title: "Name", width: 340, minWidth: 140, source: .listing, groupStyle: .alphabet,
                         isCommon: true, listingValue: { .text($0.name) }),
        ColumnDescriptor(id: .dateModified, title: "Date modified", width: 160, minWidth: 90, source: .listing,
                         groupStyle: .date, isCommon: true, listingValue: { $0.modified.map(ColumnValue.date) ?? .unknown }),
        ColumnDescriptor(id: .type, title: "Type", width: 150, minWidth: 70, source: .listing, groupStyle: .distinct,
                         isCommon: true, keywords: ["kind", "item type"], listingValue: { .text($0.typeDescription) }),
        ColumnDescriptor(id: .size, title: "Size", width: 90, minWidth: 55, alignRight: true, source: .listing,
                         groupStyle: .size, isCommon: true, listingValue: { item in
                             item.isFolder ? .unsupported : (item.size.map(ColumnValue.bytes) ?? .unknown) }),
        ColumnDescriptor(id: .dateCreated, title: "Date created", width: 160, minWidth: 90, source: .fileSystem,
                         groupStyle: .date, isCommon: true),
        ColumnDescriptor(id: .dateAccessed, title: "Date accessed", width: 160, minWidth: 90, source: .fileSystem,
                         groupStyle: .date, keywords: ["last opened"]),
        ColumnDescriptor(id: .sizeOnDisk, title: "Size on disk", width: 100, minWidth: 55, alignRight: true,
                         source: .fileSystem, groupStyle: .size, keywords: ["allocated"]),
        ColumnDescriptor(id: .authors, title: "Authors", width: 150, source: .content, groupStyle: .distinct,
                         isCommon: true, keywords: ["creator"]),
        ColumnDescriptor(id: .tags, title: "Tags", width: 140, source: .fileSystem, groupStyle: .distinct,
                         isCommon: true, keywords: ["finder tags", "labels", "keywords"]),
        ColumnDescriptor(id: .title, title: "Title", width: 180, source: .content, groupStyle: .alphabet, isCommon: true),
        ColumnDescriptor(id: .itemDate, title: "Date", width: 160, minWidth: 90, source: .content, groupStyle: .date,
                         keywords: ["item date"]),
        ColumnDescriptor(id: .dimensions, title: "Dimensions", width: 110, source: .content, groupStyle: .distinct,
                         keywords: ["resolution", "pixels"]),
        ColumnDescriptor(id: .width, title: "Width", width: 80, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["pixels"]),
        ColumnDescriptor(id: .height, title: "Height", width: 80, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["pixels"]),
        ColumnDescriptor(id: .dateTaken, title: "Date taken", width: 160, minWidth: 90, source: .content, groupStyle: .date,
                         keywords: ["photo", "exif"]),
        ColumnDescriptor(id: .cameraModel, title: "Camera model", width: 140, source: .content, groupStyle: .distinct,
                         keywords: ["photo", "exif"]),
        ColumnDescriptor(id: .length, title: "Length", width: 90, alignRight: true, source: .content, groupStyle: .duration,
                         keywords: ["duration", "time"]),
        ColumnDescriptor(id: .bitRate, title: "Bit rate", width: 90, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["kbps", "bitrate"]),
        ColumnDescriptor(id: .trackNumber, title: "#", width: 50, minWidth: 36, alignRight: true, source: .content,
                         groupStyle: .distinct, keywords: ["track", "number"]),
        ColumnDescriptor(id: .artists, title: "Contributing artists", width: 170, source: .content, groupStyle: .distinct,
                         keywords: ["artist", "performer"]),
        ColumnDescriptor(id: .album, title: "Album", width: 160, source: .content, groupStyle: .distinct),
        ColumnDescriptor(id: .genre, title: "Genre", width: 110, source: .content, groupStyle: .distinct),
        ColumnDescriptor(id: .year, title: "Year", width: 70, alignRight: true, source: .content, groupStyle: .distinct),
        ColumnDescriptor(id: .pages, title: "Pages", width: 70, alignRight: true, source: .content, groupStyle: .distinct,
                         keywords: ["page count"]),
        ColumnDescriptor(id: .comments, title: "Comments", width: 180, source: .content, groupStyle: .distinct,
                         keywords: ["finder comment"]),
    ]
}

// MARK: - Values and formatting

/// Supplies values for columns that aren't in the listing. Returns nil while a value is loading.
public typealias ColumnValueLookup = (FileItem, ColumnID) -> ColumnValue?

public enum ColumnValues {
    /// The value of `column` for `item`: from the listing, else from `lookup` (nil = loading).
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

    /// Cell text. Loading shows "…", unknown "—", empty and unsupported show nothing (like Explorer).
    public static func text(_ value: ColumnValue?, column: ColumnID = "") -> String {
        guard let value else { return "…" }
        switch value {
        case .text(let s): return s
        case .number(let n):
            if column == .year { return String(Int(n)) }
            return integer.string(from: NSNumber(value: n)) ?? "\(n)"
        case .date(let d): return dateFormatter.string(from: d)
        case .bytes(let b): return StatusText.bytes(b)
        case .duration(let s): return durationText(s)
        case .bitRate(let b): return "\(Int((b / 1000).rounded()))kbps"
        case .dimensions(let w, let h): return "\(w) x \(h)"
        case .list(let l): return l.joined(separator: "; ")
        case .empty, .unsupported: return ""
        case .unknown: return "—"
        }
    }

    /// Explorer's Length format: hh:mm:ss.
    public static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// Spoken/tooltip description of a cell's state.
    public static func stateDescription(_ value: ColumnValue?) -> String? {
        switch value {
        case nil: return "Loading…"
        case .unknown?: return "Unknown: this information couldn't be read"
        case .unsupported?: return "Not available for this kind of item"
        case .empty?: return "None"
        default: return nil
        }
    }

    /// Comparable form for sorting. nil sorts last in both directions.
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

/// Explorer's folder templates ("Optimize this folder for"), plus the Downloads special case.
public enum FolderKind: String, CaseIterable, Sendable, Codable {
    case general, documents, pictures, music, videos, downloads

    public var title: String {
        switch self {
        case .general: return "General items"
        case .documents: return "Documents"
        case .pictures: return "Pictures"
        case .music: return "Music"
        case .videos: return "Videos"
        case .downloads: return "Downloads"
        }
    }

    /// Folder type discovery from content (RECALL-m): at least 3 files, 70 % or more of them
    /// pictures, music or videos. Nil = no clear kind. Uses file name extensions only (no I/O).
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

/// The ordered columns of a Details view plus its default grouping. Name is always first and can't be hidden.
public struct ColumnSet: Equatable, Sendable, Codable {
    public var columns: [ColumnSpec]
    /// Default Group by for folders of this kind (nil = none).
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

    /// Shows or hides a column. Hiding Name is ignored; shown columns are appended at the end.
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

    /// Moves a column to an index (Name stays first).
    public mutating func move(_ id: ColumnID, to index: Int) {
        guard id != .name, let from = columns.firstIndex(where: { $0.id == id }) else { return }
        let spec = columns.remove(at: from)
        columns.insert(spec, at: min(max(index, 1), columns.count))
    }

    /// Default sets (docs/research/windows11-reference.md §5.1).
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
