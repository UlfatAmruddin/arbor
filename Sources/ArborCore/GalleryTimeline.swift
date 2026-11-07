import Foundation

/// Photo or video, as Gallery shows it (FE-075).
public enum GalleryMediaKind: String, Sendable, Codable {
    case image, video
}

/// One photo or video in the Gallery. The Gallery is a projection: every item is a real file at `url`,
/// and every action (open, copy, Trash) acts on that file (spec §12.2, FE-239).
public struct GalleryItem: Hashable, Sendable {
    public let url: URL
    /// Date taken when known (EXIF / Spotlight content creation), else file creation, else modification.
    public let date: Date
    public let kind: GalleryMediaKind
    public let size: Int64?
    /// Displayed width ÷ height (EXIF orientation applied). nil when unknown.
    public let aspect: Double?
    public let modified: Date?

    public init(url: URL, date: Date, kind: GalleryMediaKind, size: Int64? = nil, aspect: Double? = nil, modified: Date? = nil) {
        self.url = url.standardizedFileURL
        self.date = date
        self.kind = kind
        self.size = size
        self.aspect = aspect
        self.modified = modified
    }

    /// Path identity used to merge scans and overlapping sources (never the file name).
    public var key: String { Location.normalizedPath(url) }
}

/// A month section: the "November 2026" header and its items, newest first.
public struct GalleryMonth: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let title: String
    public var items: [GalleryItem]
}

/// Month bucketing, ordering and dates for Gallery (pure logic, unit-tested).
public enum GalleryTimeline {
    /// Newest first (or oldest first); ties broken by path so the order is stable between scans.
    public static func sorted(_ items: [GalleryItem], newestFirst: Bool = true) -> [GalleryItem] {
        items.sorted { a, b in
            if a.date != b.date { return newestFirst ? a.date > b.date : a.date < b.date }
            return a.key.localizedStandardCompare(b.key) == .orderedAscending
        }
    }

    /// Groups items by calendar month. Sections and the items inside them follow `newestFirst`.
    public static func months(_ items: [GalleryItem], newestFirst: Bool = true,
                              calendar: Calendar = .current, locale: Locale = .current) -> [GalleryMonth] {
        var sections: [GalleryMonth] = []
        var titles: [Int: String] = [:]
        for item in sorted(items, newestFirst: newestFirst) {
            let parts = calendar.dateComponents([.year, .month], from: item.date)
            let year = parts.year ?? 1970, month = parts.month ?? 1
            if let last = sections.last, last.year == year, last.month == month {
                sections[sections.count - 1].items.append(item)
                continue
            }
            let id = year * 100 + month
            let title = titles[id] ?? title(year: year, month: month, calendar: calendar, locale: locale)
            titles[id] = title
            sections.append(GalleryMonth(year: year, month: month, title: title, items: [item]))
        }
        return sections
    }

    /// "November 2026" (localized month and year).
    public static func title(year: Int, month: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = 15
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        guard let date = calendar.date(from: c) else { return "\(month)/\(year)" }
        return formatter.string(from: date)
    }

    /// Years for the date rail, in display order, each with the index of its first month section.
    public static func years(_ months: [GalleryMonth]) -> [(year: Int, firstSection: Int)] {
        var result: [(Int, Int)] = []
        for (index, section) in months.enumerated() where result.last?.0 != section.year {
            result.append((section.year, index))
        }
        return result
    }

    /// The date Gallery files an item under: the date taken when known, else the earlier of the file's
    /// creation and modification dates (a copied photo has a new creation date but keeps its
    /// modification date; an edited one the reverse). Dates before 1900 or more than a day in the
    /// future are treated as unknown (bad camera clocks, zero dates).
    public static func bestDate(taken: Date?, created: Date?, modified: Date?, now: Date = Date()) -> Date? {
        let earliest = Date(timeIntervalSince1970: -2_208_988_800)   // 1900-01-01
        let latest = now.addingTimeInterval(86_400)
        func valid(_ date: Date?) -> Date? { date.flatMap { $0 >= earliest && $0 <= latest ? $0 : nil } }
        if let taken = valid(taken) { return taken }
        return [valid(created), valid(modified)].compactMap { $0 }.min()
    }

    /// Parses an EXIF date ("2024:03:15 14:30:05", local time without a zone) in `timeZone`.
    public static func parseExifDate(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = digits.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count >= 3, parts[0] > 1800, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = parts.count > 3 ? parts[3] : 0
        c.minute = parts.count > 4 ? parts[4] : 0
        c.second = parts.count > 5 ? parts[5] : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: c)
    }

    /// Width ÷ height after EXIF orientation (5–8 rotate by 90°).
    public static func aspect(width: Double, height: Double, orientation: Int = 1) -> Double? {
        guard width > 0, height > 0 else { return nil }
        return (5...8).contains(orientation) ? height / width : width / height
    }
}

// MARK: - Justified grid

/// One row of the justified thumbnail grid.
public struct JustifiedRow: Equatable, Sendable {
    /// Indexes into the input array.
    public var indexes: [Int]
    /// x offset and width of each tile, in the same order as `indexes`.
    public var frames: [(x: Double, width: Double)]
    public var height: Double

    public static func == (a: JustifiedRow, b: JustifiedRow) -> Bool {
        a.indexes == b.indexes && a.height == b.height
            && a.frames.map(\.x) == b.frames.map(\.x) && a.frames.map(\.width) == b.frames.map(\.width)
    }
}

/// "Justified" rows like Gallery: tiles keep their aspect ratio, every full row spans the width,
/// and the last row of a section keeps the target height instead of being stretched.
public enum JustifiedLayout {
    /// Aspect ratios are clamped so panoramas and slivers stay usable.
    public static let minAspect = 0.5
    public static let maxAspect = 2.6

    public static func rows(aspects: [Double?], width: Double, targetHeight: Double, spacing: Double,
                            maxHeight: Double? = nil) -> [JustifiedRow] {
        guard width > 0, targetHeight > 0 else { return [] }
        let clamped = aspects.map { min(max($0 ?? 1, minAspect), maxAspect) }
        let ceiling = maxHeight ?? targetHeight * 1.6
        var rows: [JustifiedRow] = []
        var current: [Int] = []
        var sum = 0.0
        func emit(height: Double, stretch: Bool) {
            guard !current.isEmpty else { return }
            var frames: [(x: Double, width: Double)] = []
            var x = 0.0
            let usable = width - spacing * Double(current.count - 1)
            for (n, index) in current.enumerated() {
                var w = clamped[index] * height
                if stretch, n == current.count - 1 { w = max(1, usable + spacing * Double(current.count - 1) - x) }
                frames.append((x, w))
                x += w + spacing
            }
            rows.append(JustifiedRow(indexes: current, frames: frames, height: height))
            current = []
            sum = 0
        }
        for index in clamped.indices {
            current.append(index)
            sum += clamped[index]
            let usable = width - spacing * Double(current.count - 1)
            if sum * targetHeight >= usable {
                // Row is full: shrink it to fit the width exactly (one tile may be wider than the view).
                let height = min(max(usable / sum, 1), ceiling)
                emit(height: height, stretch: height < ceiling)
            }
        }
        emit(height: targetHeight, stretch: false)
        return rows
    }
}
