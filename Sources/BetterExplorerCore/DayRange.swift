import Foundation

/// A run of whole calendar days for date column filters (FE-039).
public struct DayRange: Equatable, Sendable {
    /// Local midnight of the first day, inclusive.
    public let start: Date
    /// Local midnight after the last day, exclusive, so 23- and 25-hour days count in full.
    public let end: Date

    /// About 100 years; Calendar returns garbage rather than nil for absurd day counts.
    public static let maxDayCount = 36_600
    private static let secondsPerDay: TimeInterval = 86_400

    /// Either order works; nil when the span is too long or the calendar can't answer.
    public init?(from first: Date, through last: Date, calendar: Calendar) {
        let days = abs(last.timeIntervalSince(first)) / Self.secondsPerDay
        guard days.isFinite, days < Double(Self.maxDayCount + 1) else { return nil }
        let (low, high) = first <= last ? (first, last) : (last, first)
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: high)) else { return nil }
        start = calendar.startOfDay(for: low)
        end = calendar.startOfDay(for: dayAfter)   // some zones have no midnight on a transition day
    }

    /// Adapts NSDatePicker's range, whose span is always whole 86,400-second days, even across a 25-hour day.
    public init?(from first: Date, spanning span: TimeInterval, calendar: Calendar) {
        guard let days = Int(checked: (span / Self.secondsPerDay).rounded()), (0...Self.maxDayCount).contains(days),
              let last = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: first)) else { return nil }
        self.init(from: first, through: last, calendar: calendar)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The last day this range covers, as a moment within it; `end` belongs to the following day.
    public var lastInstant: Date { end.addingTimeInterval(-1) }

    /// What to give a graphical NSDatePicker: noon keeps whole-day spans on the right day across clock changes.
    public func pickerSelection(calendar: Calendar) -> (anchor: Date, span: TimeInterval) {
        let parts: Set<Calendar.Component> = [.era, .year, .month, .day]
        let days = calendar.dateComponents([.day], from: calendar.dateComponents(parts, from: start),
                                            to: calendar.dateComponents(parts, from: lastInstant)).day ?? 0
        let anchor = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
        return (anchor, TimeInterval(days) * Self.secondsPerDay)
    }

    /// "Mar 3 – 9, 2026"; one day prints as a single date.
    public func title(calendar: Calendar) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: lastInstant)
    }
}
