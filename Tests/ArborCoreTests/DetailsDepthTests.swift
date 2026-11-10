import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import ArborCore

private func item(_ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil, type: String = "Document") -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/tmp/fixture/\(name)"), name: name, isFolder: folder,
             size: folder ? nil : size, modified: modified, typeDescription: folder ? "Folder" : type)
}

/// A Gregorian calendar in a fixed zone with a chosen first weekday.
private func calendar(firstWeekday: Int, zone: String = "America/New_York") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    c.firstWeekday = firstWeekday
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func date(_ text: String, _ cal: Calendar) -> Date {
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: text)!
}

@Suite("Date buckets (FE-038)")
struct DateBucketTests {
    // Saturday 2026-11-07 15:00, New York.
    let sunday = calendar(firstWeekday: 1)
    let monday = calendar(firstWeekday: 2)

    func title(_ d: String, _ cal: Calendar, now: String = "2026-11-07 15:00") -> String {
        Buckets.date(date(d, cal), GroupingContext(now: date(now, cal), calendar: cal)).title
    }

    @Test func pastBuckets() {
        let c = sunday
        #expect(title("2026-11-07 00:01", c) == "Today")
        #expect(title("2026-11-06 23:59", c) == "Yesterday")
        #expect(title("2026-11-02 09:00", c) == "Earlier this week")      // Monday; week starts Sunday 11-01
        #expect(title("2026-11-01 00:00", c) == "Earlier this week")
        #expect(title("2026-10-31 12:00", c) == "Last week")              // previous week, previous month
        #expect(title("2026-10-25 00:00", c) == "Last week")
        #expect(title("2026-10-24 23:00", c) == "Last month")
        #expect(title("2026-10-01 00:00", c) == "Last month")
        #expect(title("2026-09-30 23:00", c) == "Earlier this year")
        #expect(title("2026-01-01 00:00", c) == "Earlier this year")
        #expect(title("2025-12-31 23:59", c) == "A long time ago")
    }

    @Test func earlierThisMonth() {
        // Now Thursday 2026-11-26: Nov 1–14 is this month but before last week.
        #expect(title("2026-11-10 10:00", sunday, now: "2026-11-26 10:00") == "Earlier this month")
        #expect(title("2026-11-16 10:00", sunday, now: "2026-11-26 10:00") == "Last week")
    }

    @Test func weekStartFollowsLocale() {
        // Sunday 2026-11-08 noon: with Sunday-start weeks, Friday is last week; Monday-start, this week.
        let now = "2026-11-08 12:00"
        #expect(title("2026-11-06 10:00", sunday, now: now) == "Last week")
        #expect(title("2026-11-06 10:00", monday, now: now) == "Earlier this week")
        // Yesterday wins over "last week" on the first day of the week.
        #expect(title("2026-11-07 10:00", sunday, now: now) == "Yesterday")
    }

    @Test func timeZoneDecidesTheDay() {
        let utc = calendar(firstWeekday: 1, zone: "UTC")
        let tokyo = calendar(firstWeekday: 1, zone: "Asia/Tokyo")
        let instant = date("2026-11-06 20:00", utc)    // 05:00 on the 7th in Tokyo
        let now = date("2026-11-07 06:00", utc)        // 15:00 on the 7th in Tokyo
        #expect(Buckets.date(instant, GroupingContext(now: now, calendar: utc)).title == "Yesterday")
        #expect(Buckets.date(instant, GroupingContext(now: now, calendar: tokyo)).title == "Today")
    }

    @Test func futureAndMissing() {
        let c = sunday
        #expect(title("2026-11-07 09:00", c, now: "2026-11-05 12:00") == "Later this week")
        #expect(title("2026-11-10 09:00", c) == "Next week")
        #expect(title("2027-03-01 09:00", c) == "In the future")
        #expect(Buckets.date(nil, GroupingContext()) == .unspecified)
    }

    @Test func chronologicalRanks() {
        let c = sunday
        let ctx = GroupingContext(now: date("2026-11-07 15:00", c), calendar: c)
        let ranks = ["2025-01-01 00:00", "2026-02-01 00:00", "2026-10-02 00:00", "2026-10-28 00:00",
                     "2026-11-02 00:00", "2026-11-06 00:00", "2026-11-07 09:00"].map { Buckets.date(date($0, c), ctx).rank }
        #expect(ranks == ranks.sorted())
        #expect(Set(ranks).count == ranks.count)
    }
}

@Suite("Size, name and length buckets")
struct OtherBucketTests {
    @Test func sizes() {
        let kb = Buckets.kb, mb = Buckets.mb, gb = Buckets.gb
        #expect(Buckets.size(0).title == "Empty (0 KB)")
        #expect(Buckets.size(1).title == "Tiny (0 – 16 KB)")
        #expect(Buckets.size(16 * kb).title == "Tiny (0 – 16 KB)")
        #expect(Buckets.size(16 * kb + 1).title == "Small (16 KB – 1 MB)")
        #expect(Buckets.size(mb).title == "Small (16 KB – 1 MB)")
        #expect(Buckets.size(mb + 1).title == "Medium (1 – 128 MB)")
        #expect(Buckets.size(128 * mb + 1).title == "Large (128 MB – 1 GB)")
        #expect(Buckets.size(gb + 1).title == "Huge (1 – 4 GB)")
        #expect(Buckets.size(4 * gb + 1).title == "Gigantic (> 4 GB)")
        #expect(Buckets.size(nil) == .unspecified)
    }

    @Test func names() {
        #expect(Buckets.alphabet("apple").title == "A – H")
        #expect(Buckets.alphabet("Hotel").title == "A – H")
        #expect(Buckets.alphabet("Éclair").title == "A – H")
        #expect(Buckets.alphabet("iris").title == "I – P")
        #expect(Buckets.alphabet("Zebra").title == "Q – Z")
        #expect(Buckets.alphabet("2024 budget").title == "0 – 9")
        #expect(Buckets.alphabet("_scratch").title == "Other")
        #expect(Buckets.alphabet("Ωmega").title == "Other")
        #expect(Buckets.alphabet("日本").title == "Other")
    }

    @Test func lengths() {
        #expect(Buckets.duration(59).title.hasPrefix("Very short"))
        #expect(Buckets.duration(60).title.hasPrefix("Short"))
        #expect(Buckets.duration(1800).title.hasPrefix("Long"))
        #expect(Buckets.duration(7200).title.hasPrefix("Very long"))
    }
}

@Suite("Grouping")
struct GroupingTests {
    let cal = calendar(firstWeekday: 1)

    @Test func groupsKeepSortInside() {
        let items = FileSorter.sorted([item("b.txt", type: "Text"), item("a.png", type: "PNG image"),
                                       item("c.txt", type: "Text"), item("Docs", folder: true)], by: FileSortOrder())
        let groups = FileGrouper.group(items, by: .type, ascending: true)
        #expect(groups.map(\.bucket.title) == ["Folder", "PNG image", "Text"])
        #expect(groups[2].items.map(\.name) == ["b.txt", "c.txt"])
        let down = FileGrouper.group(items, by: .type, ascending: false)
        #expect(down.map(\.bucket.title) == ["Text", "PNG image", "Folder"])
    }

    @Test func sizeGroupsPutFoldersLast() {
        let items = [item("Docs", folder: true), item("big", size: 2 * Buckets.mb), item("empty", size: 0), item("tiny", size: 10)]
        let up = FileGrouper.group(items, by: .size, ascending: true).map(\.bucket.title)
        let down = FileGrouper.group(items, by: .size, ascending: false).map(\.bucket.title)
        #expect(up == ["Empty (0 KB)", "Tiny (0 – 16 KB)", "Medium (1 – 128 MB)", "Unspecified"])
        #expect(down == ["Medium (1 – 128 MB)", "Tiny (0 – 16 KB)", "Empty (0 KB)", "Unspecified"])
    }

    @Test func dateGroupsDescendingStartWithToday() {
        let now = date("2026-11-07 15:00", cal)
        let ctx = GroupingContext(now: now, calendar: cal)
        let items = [item("old", modified: date("2020-01-01 00:00", cal)), item("new", modified: now),
                     item("y", modified: date("2026-11-06 08:00", cal))]
        let groups = FileGrouper.group(items, by: .dateModified, ascending: false, context: ctx)
        #expect(groups.map(\.bucket.title) == ["Today", "Yesterday", "A long time ago"])
    }

    @Test func metadataGroupsWaitForValues() {
        let a = item("a.jpg"), b = item("b.jpg")
        let lookup: ColumnValueLookup = { item, _ in item.name == "a.jpg" ? .dimensions(width: 10, height: 20) : nil }
        let groups = FileGrouper.group([a, b], by: .dimensions, ascending: true, lookup: lookup)
        #expect(groups.map(\.bucket.title) == ["10 x 20", "Loading…"])
    }
}

@Suite("Column filters (FE-039)")
struct ColumnFilterTests {
    let items = [item("apple.txt", size: 10, type: "Text"), item("zoo.png", size: 0, type: "PNG image"),
                 item("big.txt", size: 5 * Buckets.mb, type: "Text"), item("Docs", folder: true)]

    @Test func orWithinAndAcross() {
        var f = ColumnFilters()
        f.set(.type, ["value.Text", "value.Folder"])
        #expect(f.apply(items, lookup: nil).map(\.name) == ["apple.txt", "big.txt", "Docs"])
        f.toggle(.size, bucket: "size.tiny")
        #expect(f.apply(items, lookup: nil).map(\.name) == ["apple.txt"])
        f.toggle(.size, bucket: "size.tiny")
        #expect(!f.isFiltered(.size))
        f.clear()
        #expect(f.isEmpty)
        #expect(f.apply(items, lookup: nil).count == 4)
    }

    @Test func optionsListPresentBuckets() {
        let options = ColumnFilters.options(for: .size, items: items, lookup: nil).map(\.title)
        #expect(options == ["Empty (0 KB)", "Tiny (0 – 16 KB)", "Medium (1 – 128 MB)", "Unspecified"])
        let names = ColumnFilters.options(for: .name, items: items, lookup: nil).map(\.title)
        #expect(names == ["A – H", "Q – Z"])
    }

    @Test func multiValuedTagsMatchAny() {
        let a = item("a"), b = item("b"), c = item("c")
        let tags: [String: ColumnValue] = ["a": .list(["Red", "Work"]), "b": .list(["Work"]), "c": .empty]
        let lookup: ColumnValueLookup = { item, _ in tags[item.name] }
        var f = ColumnFilters()
        f.set(.tags, ["value.Red"])
        #expect(f.apply([a, b, c], lookup: lookup).map(\.name) == ["a"])
        f.set(.tags, ["value.Work", "~unspecified"])
        #expect(f.apply([a, b, c], lookup: lookup).map(\.name) == ["a", "b", "c"])
        #expect(ColumnFilters.options(for: .tags, items: [a, b, c], lookup: lookup).map(\.title) == ["Red", "Work", "Unspecified"])
    }
}

@Suite("Day ranges (FE-039)")
struct DayRangeTests {
    let newYork = calendar(firstWeekday: 1)

    private func day(_ text: String, _ cal: Calendar) -> Date { date(text + " 12:00", cal) }

    @Test func aSingleDayCoversItsWholeLength() throws {
        let range = try #require(DayRange(from: day("2026-03-03", newYork), through: day("2026-03-03", newYork), calendar: newYork))
        #expect(range.contains(date("2026-03-03 00:00", newYork)))
        #expect(range.contains(date("2026-03-03 23:59", newYork)))
        #expect(!range.contains(date("2026-03-04 00:00", newYork)))
        #expect(!range.contains(date("2026-03-02 23:59", newYork)))
    }

    @Test func swappedEndpointsNormalise() {
        let a = day("2026-03-03", newYork), b = day("2026-03-09", newYork)
        #expect(DayRange(from: b, through: a, calendar: newYork) == DayRange(from: a, through: b, calendar: newYork))
    }

    @Test func clockChangeDaysCountInFull() throws {
        let fall = try #require(DayRange(from: day("2026-10-31", newYork), through: day("2026-11-01", newYork), calendar: newYork))
        #expect(fall.contains(date("2026-11-01 23:59", newYork)))
        #expect(!fall.contains(date("2026-11-02 00:00", newYork)))
        let spring = try #require(DayRange(from: day("2026-03-07", newYork), through: day("2026-03-08", newYork), calendar: newYork))
        #expect(spring.contains(date("2026-03-08 23:59", newYork)))
        #expect(!spring.contains(date("2026-03-09 00:00", newYork)))
    }

    @Test func aPickerSpanCountsDaysNotSeconds() throws {
        // Midnight seed + 2 x 86,400 s would stop an hour short of Nov 2 across the 25-hour day.
        let seed = date("2026-10-31 00:00", newYork)
        let range = try #require(DayRange(from: seed, spanning: 2 * 86_400, calendar: newYork))
        #expect(range.start == seed)
        #expect(range.end == date("2026-11-03 00:00", newYork))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -86_400, 1e300, 86_400 * 36_601, Double(Int.max)])
    func anOutOfBoundsSpanIsRefused(span: Double) {
        #expect(DayRange(from: day("2026-03-03", newYork), spanning: span, calendar: newYork) == nil)
    }

    @Test func endpointsFollowTheSameBound() throws {
        let start = day("2026-03-03", newYork)
        let inside = try #require(newYork.date(byAdding: .day, value: DayRange.maxDayCount, to: start))
        let outside = try #require(newYork.date(byAdding: .day, value: DayRange.maxDayCount + 2, to: start))
        #expect(DayRange(from: start, through: inside, calendar: newYork) != nil)
        #expect(DayRange(from: start, through: outside, calendar: newYork) == nil)
        #expect(DayRange(from: start, through: Date(timeIntervalSinceReferenceDate: .nan), calendar: newYork) == nil)
    }

    @Test func aZoneWithoutMidnightStillWorks() throws {
        // Havana's clocks go from 00:00 to 01:00 on 2026-03-08, so that day has no midnight.
        let havana = calendar(firstWeekday: 1, zone: "America/Havana")
        let range = try #require(DayRange(from: day("2026-03-07", havana), through: day("2026-03-08", havana), calendar: havana))
        #expect(range.contains(date("2026-03-08 01:30", havana)))
        #expect(!range.contains(date("2026-03-09 00:00", havana)))
        let selection = range.pickerSelection(calendar: havana)
        #expect(selection.span == 86_400)
        #expect(DayRange(from: selection.anchor, spanning: selection.span, calendar: havana) == range)
    }

    @Test func pickerSelectionRoundTrips() throws {
        for (first, last) in [("2026-03-03", "2026-03-03"), ("2026-10-30", "2026-11-03"), ("2026-03-07", "2026-03-10"), ("2025-12-28", "2026-02-02")] {
            let range = try #require(DayRange(from: day(first, newYork), through: day(last, newYork), calendar: newYork))
            let selection = range.pickerSelection(calendar: newYork)
            #expect(DayRange(from: selection.anchor, spanning: selection.span, calendar: newYork) == range)
        }
    }

    @Test func titlesNameTheDays() throws {
        let one = try #require(DayRange(from: day("2026-03-03", newYork), through: day("2026-03-03", newYork), calendar: newYork))
        #expect(one.title(calendar: newYork).contains("2026"))
        #expect(!one.title(calendar: newYork).contains("–"))
        let run = try #require(DayRange(from: day("2026-03-03", newYork), through: day("2026-03-09", newYork), calendar: newYork))
        let title = run.title(calendar: newYork)
        #expect(title.contains("3") && title.contains("9") && title.contains("2026"), "\(title)")
        #expect(!title.contains("10"), "the exclusive end must not show: \(title)")
    }
}

@Suite("Date range column filters (FE-039)")
struct DateRangeFilterTests {
    let cal = calendar(firstWeekday: 1)
    let ctx: GroupingContext
    let inside: FileItem, outside: FileItem, undated: FileItem
    let march: DayRange

    init() throws {
        ctx = GroupingContext(now: date("2026-11-07 15:00", cal), calendar: cal)
        inside = item("inside.txt", modified: date("2026-03-05 10:00", cal), type: "Text")
        outside = item("outside.txt", modified: date("2026-04-05 10:00", cal), type: "Text")
        undated = item("undated.png", modified: nil, type: "PNG image")
        march = try #require(DayRange(from: date("2026-03-01 00:00", cal), through: date("2026-03-31 00:00", cal), calendar: cal))
    }

    private func names(_ f: ColumnFilters, _ items: [FileItem], lookup: ColumnValueLookup? = nil) -> [String] {
        f.apply(items, ctx: ctx, lookup: lookup).map(\.name)
    }

    @Test func rangeOnlyKeepsDatesInside() {
        var f = ColumnFilters()
        f.setDateRange(.dateModified, march)
        #expect(names(f, [inside, outside, undated]) == ["inside.txt"])
        #expect(f.isFiltered(.dateModified) && !f.isEmpty && f.columns == [.dateModified])
        #expect(f.dateRange(.dateModified) == march && f.selected(.dateModified).isEmpty)
    }

    @Test func rangeOrBucketWithinAColumnAndAcrossColumns() {
        var f = ColumnFilters()
        f.setDateRange(.dateModified, march)
        f.set(.dateModified, ["~unspecified"])
        #expect(names(f, [inside, outside, undated]) == ["inside.txt", "undated.png"])
        f.set(.type, ["value.Text"])
        #expect(names(f, [inside, outside, undated]) == ["inside.txt"])
    }

    @Test func loadingAndUnknownNeverSatisfyARange() {
        var f = ColumnFilters()
        f.setDateRange(.dateCreated, march)
        let values: [String: ColumnValue] = ["unknown": .unknown, "unsupported": .unsupported, "empty": .empty,
                                             "hit": .date(date("2026-03-05 10:00", cal))]
        let lookup: ColumnValueLookup = { item, _ in values[item.name] }
        let items = ["unknown", "unsupported", "empty", "hit", "loading"].map { item($0) }
        #expect(names(f, items, lookup: lookup) == ["hit"])
        f.set(.dateCreated, ["~unspecified"])
        #expect(names(f, items, lookup: lookup) == ["unknown", "unsupported", "empty", "hit"])
        f.set(.dateCreated, ["~loading"])
        #expect(names(f, items, lookup: lookup) == ["hit", "loading"])
    }

    @Test func eachPartKeepsTheOtherAndTheLastOneRemovesTheColumn() {
        var f = ColumnFilters()
        f.setDateRange(.dateModified, march)
        f.toggle(.dateModified, bucket: "date.today")
        f.set(.dateModified, ["date.lastWeek"])
        #expect(f.dateRange(.dateModified) == march)
        f.setDateRange(.dateModified, nil)
        #expect(f.selected(.dateModified) == ["date.lastWeek"])
        f.toggle(.dateModified, bucket: "date.lastWeek")
        #expect(f.isEmpty && !f.isFiltered(.dateModified))
        f.setDateRange(.dateModified, march)
        f.setDateRange(.dateModified, nil)
        #expect(f.isEmpty)
    }
}

@Suite("Column filter summaries (FE-039)")
struct ColumnFilterSummaryTests {
    let cal = calendar(firstWeekday: 1)
    let items = [item("a.txt", type: "Text"), item("b.png", type: "PNG"), item("c.jpg", type: "JPEG"),
                 item("d.gif", type: "GIF"), item("e.pdf", type: "PDF")]

    @Test func columnOrderFollowsTheColumnsThenStableIDs() {
        var f = ColumnFilters()
        for column: ColumnID in ["zeta", .type, "alpha", .size] { f.set(column, ["x"]) }
        #expect(f.orderedColumns([.size, .name, .type]) == [.size, .type, "alpha", "zeta"])
        #expect(f.summaries(order: [.size, .name, .type], items: [], lookup: nil).map(\.column) == [.size, .type, "alpha", "zeta"])
    }

    @Test func valuesAreCappedAndTheRestCounted() throws {
        var f = ColumnFilters()
        f.set(.type, ["value.Text", "value.PNG", "value.JPEG", "value.GIF", "value.PDF", "value.Gone"])
        let summary = try #require(f.summaries(order: [.type], items: items, lookup: nil).first)
        #expect(summary.values == ["GIF", "JPEG", "PDF"])
        #expect(summary.moreCount == 3)
        #expect(summary.line == "Type: GIF or JPEG or PDF or 3 more")
    }

    @Test func aRangeComesFirstAndCountsTowardTheCap() throws {
        let range = try #require(DayRange(from: date("2026-03-03 12:00", cal), through: date("2026-03-03 12:00", cal), calendar: cal))
        var f = ColumnFilters()
        f.setDateRange(.type, range)
        f.set(.type, ["value.Text", "value.PNG", "value.JPEG"])
        let ctx = GroupingContext(now: date("2026-11-07 15:00", cal), calendar: cal)
        let summary = try #require(f.summaries(order: [.type], items: items, ctx: ctx, lookup: nil).first)
        #expect(summary.values == [range.title(calendar: cal), "JPEG", "PNG"])
        #expect(summary.moreCount == 1)
    }

    @Test func checkedChoicesAbsentFromTheListingStillRead() throws {
        var f = ColumnFilters()
        f.set(.type, ["value.Gone", "value.Lost"])
        let summary = try #require(f.summaries(order: [.type], items: items, lookup: nil).first)
        #expect(summary.values.isEmpty && summary.moreCount == 2)
        #expect(summary.line == "Type: none in this folder")
    }

    @Test func displayValueRemovesControlsAndDirectionOverrides() {
        #expect(ColumnFilterSummary.displayValue("a\u{202E}b\u{2066}c\u{2069}d\u{0007}e\nf\tg") == "abcdefg")
        #expect(ColumnFilterSummary.displayValue("one\u{2028}two\u{2029}three") == "onetwothree")
    }

    @Test func displayValueKeepsJoinedEmoji() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(ColumnFilterSummary.displayValue(family) == family)
    }

    @Test func displayValueIsBoundedByCharactersAndScalars() {
        let long = ColumnFilterSummary.displayValue(String(repeating: "x", count: 100))
        #expect(long == String(repeating: "x", count: 40) + "…")
        #expect(ColumnFilterSummary.displayValue(String(repeating: "x", count: 40)) == String(repeating: "x", count: 40))
        let zalgo = "a" + String(repeating: "\u{0301}", count: 5_000)
        let bounded = ColumnFilterSummary.displayValue(zalgo)
        #expect(bounded.unicodeScalars.count <= 161)
        #expect(bounded.hasSuffix("…"))
    }
}

@Suite("Column sorting (FE-235)")
struct ColumnSortTests {
    @Test func sortsByMetadataColumnWithLoadingLast() {
        let values: [String: ColumnValue] = ["a": .dimensions(width: 100, height: 100), "b": .dimensions(width: 10, height: 10),
                                             "c": .unsupported]
        FileSorter.columnValues.register("tests.dimensions") { item, _ in .some(values[item.name]) }
        defer { FileSorter.columnValues.remove("tests.dimensions") }
        var order = FileSortOrder()
        order.setPrimary(.dimensions, ascending: true)
        let items = [item("d"), item("c"), item("a"), item("b")]
        #expect(FileSorter.sorted(items, by: order).map(\.name) == ["b", "a", "c", "d"])
        order.ascending = false
        #expect(FileSorter.sorted(items, by: order).map(\.name) == ["a", "b", "c", "d"])
        #expect(order.primaryColumn == .dimensions)
        #expect(order.thenBy == [SortCriterion(.name, ascending: true)])
    }

    @Test func previousKeyBreaksTies() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let items = [item("x.txt", modified: t.addingTimeInterval(60), type: "Text"),
                     item("y.png", modified: t, type: "PNG"),
                     item("a.txt", modified: t, type: "Text")]
        var order = FileSortOrder(foldersFirst: false)
        order.setPrimary(.dateModified, ascending: false)
        order.setPrimary(.type, ascending: true)
        #expect(order.key == .type && order.column == nil)
        #expect(order.thenBy.first == SortCriterion(.dateModified, ascending: false))
        // Within "Text": newest first (secondary), not by name.
        #expect(FileSorter.sorted(items, by: order).map(\.name) == ["y.png", "x.txt", "a.txt"])
    }

    @Test func secondaryKeysAreBoundedAndUnique() {
        var order = FileSortOrder()
        for c: ColumnID in [.size, .type, .dateModified, .size, .dateCreated] { order.setPrimary(c, ascending: true) }
        #expect(order.primaryColumn == .dateCreated)
        #expect(order.thenBy.map(\.column) == [.size, .dateModified])
    }

    @Test func equalValuesFallBackToName() {
        let items = [item("b", size: 5), item("a", size: 5), item("c", size: 5)]
        let sorted = FileSorter.sorted(items, by: FileSortOrder(key: .size, ascending: false))
        #expect(sorted.map(\.name) == ["a", "b", "c"])
    }
}

@Suite("Column sets (FE-040)")
struct ColumnSetTests {
    @Test func defaults() {
        #expect(ColumnSet.defaults(for: .general).ids == [.name, .dateModified, .type, .size])
        #expect(ColumnSet.defaults(for: .music).ids == [.name, .trackNumber, .title, .artists, .album])
        #expect(ColumnSet.defaults(for: .pictures).contains(.dimensions))
        #expect(ColumnSet.defaults(for: .downloads).groupBy == .dateModified)
        #expect(ColumnSet.defaults(for: .downloads).groupAscending == false)
    }

    @Test func nameStaysFirstAndVisible() {
        var set = ColumnSet(ids: [.size, .name, .type, .size])
        #expect(set.ids == [.name, .size, .type])
        set.setVisible(.name, false)
        #expect(set.contains(.name))
        set.move(.type, to: 0)
        #expect(set.ids == [.name, .type, .size])
        set.setVisible(.dateCreated, true)
        set.setWidth(222, of: .dateCreated)
        #expect(set.ids.last == .dateCreated && set.width(of: .dateCreated) == 222)
        let data = try! JSONEncoder().encode(set)
        #expect(try! JSONDecoder().decode(ColumnSet.self, from: data) == set)
    }

    @Test func formatting() {
        #expect(ColumnValues.text(nil) == "…")
        #expect(ColumnValues.text(.unknown) == "—")
        #expect(ColumnValues.text(.unsupported) == "")
        #expect(ColumnValues.text(.empty) == "")
        #expect(ColumnValues.text(.duration(3725)) == "01:02:05")
        #expect(ColumnValues.text(.dimensions(width: 640, height: 480)) == "640 x 480")
        #expect(ColumnValues.text(.bitRate(128_000)) == "128kbps")
        #expect(ColumnValues.text(.dimensions(width: 1920, height: 1080)) == "1920 x 1080")
        #expect(ColumnValues.text(.bitRate(1_411_000)) == "1411kbps")
        #expect(ColumnValues.text(.list(["Red", "Work"])) == "Red; Work")
        #expect(ColumnValues.text(.number(2024), column: .year) == "2024")
    }
}

@Suite("Metadata reading")
struct MetadataTests {
    @Test func readsImageDimensionsAndFileAttributes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png")
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        let text = dir.appendingPathComponent("note.txt")
        try "hi".write(to: text, atomically: true, encoding: .utf8)

        let values = MetadataReader.read(png, isFolder: false, columns: [.dimensions, .width, .length, .dateCreated, .tags, .title])
        #expect(values[.dimensions] == .dimensions(width: 64, height: 48))
        #expect(values[.width] == .number(64))
        #expect(values[.length] == .unsupported)
        if case .date = values[.dateCreated] {} else { Issue.record("no creation date") }
        #expect(values[.tags] == .empty)
        #expect(values[.title] == .empty)

        let t = MetadataReader.read(text, isFolder: false, columns: [.dimensions, .pages])
        #expect(t[.dimensions] == .unsupported && t[.pages] == .unsupported)
        let folder = MetadataReader.read(dir, isFolder: true, columns: [.sizeOnDisk, .dateCreated])
        #expect(folder[.sizeOnDisk] == .unsupported)
    }

    @Test func storeLoadsOffMainCachesAndCancels() {
        let store = ColumnValueStore(limit: 10, concurrency: 1)
        let gate = DispatchSemaphore(value: 0)
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        store.reader = { url, _, columns in
            counter.n += 1
            if url.lastPathComponent == "slow" { gate.wait() }
            return Dictionary(uniqueKeysWithValues: columns.map { ($0, ColumnValue.text(url.lastPathComponent)) })
        }
        let slow = item("slow"), a = item("a"), b = item("b")
        #expect(store.value(a, .title) == nil)   // loading
        store.request([slow], columns: [.title, .name], owner: "one", batchSize: 1) { _ in }
        store.request([a, b], columns: [.title], owner: "two", batchSize: 1) { _ in }
        // Same columns again while in flight: nothing new is queued.
        #expect(store.request([a], columns: [.title], owner: "three") { _ in } == 0)
        store.cancel(owner: "two")
        gate.signal()
        store.waitUntilIdle()
        #expect(store.value(slow, .title) == .text("slow"))
        #expect(store.value(slow, .name) == nil)          // listing columns are never read
        #expect(store.value(a, .title) == nil)            // cancelled
        // Cancelled items can be requested again.
        #expect(store.request([a, b], columns: [.title], owner: "four") { _ in } == 2)
        store.waitUntilIdle()
        #expect(store.value(b, .title) == .text("b"))
        #expect(counter.n == 3)
        // Bounded: never more than the limit.
        let many = (0..<30).map { item("f\($0)") }
        store.request(many, columns: [.title], owner: "many") { _ in }
        store.waitUntilIdle()
        #expect(store.count <= 10)
    }

    @Test func replacedFileIsReRead() {
        let store = ColumnValueStore()
        store.reader = { _, _, columns in Dictionary(uniqueKeysWithValues: columns.map { ($0, ColumnValue.number(1)) }) }
        let old = item("x", modified: Date(timeIntervalSinceReferenceDate: 1))
        let new = item("x", modified: Date(timeIntervalSinceReferenceDate: 2))
        store.request([old], columns: [.pages], owner: "o") { _ in }
        store.waitUntilIdle()
        #expect(store.value(old, .pages) == .number(1))
        #expect(store.value(new, .pages) == nil)
    }
}

@Suite("Status text with column filters")
struct FilterStatusTests {
    @Test func showsNofM() {
        #expect(StatusText.explorerSummary(visible: 3, total: 15, query: "", selected: []) == "3 of 15 items  |")
        #expect(StatusText.explorerSummary(visible: 15, total: 15, query: "", selected: []) == "15 items  |")
    }
}

@Suite("Folder type discovery")
struct FolderKindTests {
    @Test func discoversMediaFolders() {
        #expect(FolderKind.discover([item("a.jpg"), item("b.png"), item("c.heic"), item("d.txt")]) == .pictures)
        #expect(FolderKind.discover([item("a.mp3"), item("b.m4a"), item("c.flac")]) == .music)
        #expect(FolderKind.discover([item("a.mov"), item("b.mp4"), item("c.mov"), item("Sub", folder: true)]) == .videos)
        #expect(FolderKind.discover([item("a.jpg"), item("b.txt"), item("c.pdf")]) == nil)
        #expect(FolderKind.discover([item("a.jpg"), item("b.jpg")]) == nil)
    }
}
