import Foundation

/// Explorer-style formatting for Properties and the Details pane (FE-150).
public enum PropertyFormat {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    public static func grouped(_ n: Int64) -> String { grouped.string(from: NSNumber(value: n)) ?? "\(n)" }
    public static func grouped(_ n: Int) -> String { grouped(Int64(n)) }

    /// Explorer's size: 1024-based, three significant digits, truncated, unit switch at 1000 ("0.99 MB").
    public static func adaptiveSize(_ bytes: Int64) -> String {
        if bytes < 1000 { return L10n.format("%@ bytes", "\(grouped(max(bytes, 0)))") }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let decimals = value < 10 ? 2 : (value < 100 ? 1 : 0)
        let scale = pow(10, Double(decimals))
        let truncated = (value * scale).rounded(.down) / scale
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        f.roundingMode = .down
        return "\(f.string(from: NSNumber(value: truncated)) ?? "\(truncated)") \(units[unit])"
    }

    /// `1.23 KB (1,264 bytes)`.
    public static func propertiesSize(_ bytes: Int64) -> String {
        if bytes < 1000 { return L10n.format("%@ bytes", "\(grouped(max(bytes, 0)))") }
        return L10n.format("%@ (%@ bytes)", "\(adaptiveSize(bytes))", "\(grouped(bytes))")
    }

    /// "Saturday, November 7, 2026, 10:21:33 AM".
    public static func longDate(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let d = DateFormatter()
        d.locale = locale
        d.timeZone = timeZone
        d.dateStyle = .full
        d.timeStyle = .none
        let t = DateFormatter()
        t.locale = locale
        t.timeZone = timeZone
        t.dateStyle = .none
        t.timeStyle = .medium
        return "\(d.string(from: date)), \(t.string(from: date))"
    }

    /// "11/7/2026 3:45 PM".
    public static func shortDate(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// One date when equal, else "first - last".
    public static func dateRange(_ dates: [Date], locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let a = shortDate(first, locale: locale, timeZone: timeZone)
        let b = shortDate(last, locale: locale, timeZone: timeZone)
        return a == b ? a : "\(a) - \(b)"
    }

    /// "00:03:25".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(grouped(n)) \(n == 1 ? singular : plural)"
    }

    /// "12 Files, 3 Folders".
    public static func filesAndFolders(files: Int, folders: Int) -> String {
        "\(count(files, "File", "Files")), \(count(folders, "Folder", "Folders"))"
    }
}

// MARK: - Mixed values

/// A checkbox across a selection (FE-148).
public enum TriState: Equatable, Sendable {
    case on, off, mixed

    public init(_ values: [Bool]) {
        if values.isEmpty || values.allSatisfy({ !$0 }) { self = .off }
        else if values.allSatisfy({ $0 }) { self = .on }
        else { self = .mixed }
    }

    public var boolValue: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .mixed: return nil
        }
    }
}

public enum MixedValue<T: Equatable>: Equatable {
    case none, same(T), mixed

    public init(_ values: [T]) {
        guard let first = values.first else { self = .none; return }
        self = values.allSatisfy { $0 == first } ? .same(first) : .mixed
    }

    public var value: T? { if case .same(let v) = self { return v } else { return nil } }
}

// MARK: - Selection summaries

/// Multi-selection summary for Properties and the Details pane (FE-148, FE-150).
public struct SelectionSummary: Equatable {
    public struct Entry: Equatable {
        public var isFolder: Bool
        public var typeDescription: String
        public var parentPath: String
        public var size: Int64?
        public var modified: Date?
        public init(isFolder: Bool, typeDescription: String, parentPath: String, size: Int64? = nil, modified: Date? = nil) {
            self.isFolder = isFolder
            self.typeDescription = typeDescription
            self.parentPath = parentPath
            self.size = size
            self.modified = modified
        }
    }

    public let files: Int
    public let folders: Int
    public let type: MixedValue<String>
    public let parent: MixedValue<String>
    /// Folders excluded; `sizeIsComplete` is false when folders or unknown sizes exist.
    public let knownFileSize: Int64
    public let sizeIsComplete: Bool
    public let modifiedDates: [Date]

    public init(_ entries: [Entry]) {
        files = entries.filter { !$0.isFolder }.count
        folders = entries.filter(\.isFolder).count
        type = MixedValue(entries.map(\.typeDescription))
        parent = MixedValue(entries.map(\.parentPath))
        knownFileSize = entries.compactMap { $0.isFolder ? nil : $0.size }.saturatingSum()
        sizeIsComplete = entries.allSatisfy { !$0.isFolder && $0.size != nil }
        modifiedDates = entries.compactMap(\.modified)
    }

    public init(items: [FileItem]) {
        self.init(items.map {
            Entry(isFolder: $0.isFolder, typeDescription: $0.typeDescription,
                  parentPath: $0.url.deletingLastPathComponent().path, size: $0.size, modified: $0.modified)
        })
    }

    public var count: Int { files + folders }
    public var countText: String { PropertyFormat.filesAndFolders(files: files, folders: folders) }
    public var selectedText: String { count == 1 ? "1 item selected" : "\(PropertyFormat.grouped(count)) items selected" }

    public var typeText: String {
        switch type {
        case .same(let t): return L10n.format("All of type %@", "\(t)")
        case .mixed: return L10n.tr("Multiple types")
        case .none: return ""
        }
    }

    /// Bare common folder, for the Details pane's Location row.
    public var locationValue: String {
        switch parent {
        case .same(let p): return p
        case .mixed: return L10n.tr("Multiple locations")
        case .none: return ""
        }
    }

    public var locationText: String {
        switch parent {
        case .same(let p): return L10n.format("All in %@", "\(p)")
        case .mixed: return L10n.tr("Multiple locations")
        case .none: return ""
        }
    }
}
