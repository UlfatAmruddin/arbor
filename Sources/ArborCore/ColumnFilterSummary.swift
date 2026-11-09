import Foundation

/// The wording of one active column filter, for the address bar's menu (FE-039).
public struct ColumnFilterSummary: Equatable, Sendable {
    public static let maxValues = 3

    public let column: ColumnID
    /// The date range first, then checked buckets, at most `maxValues`.
    public let values: [String]
    /// Checked choices not in `values`, including ones no current item has.
    public let moreCount: Int

    /// "Date modified: Mar 3 – 9, 2026 or Last week".
    public var line: String {
        var parts = values
        if moreCount > 0, !values.isEmpty { parts.append(L10n.format("%d more", moreCount)) }
        let choices = parts.dropFirst().reduce(parts.first ?? L10n.tr("none in this folder")) { L10n.format("%@ or %@", $0, $1) }
        return L10n.format("%@: %@", ColumnCatalog.title(column), choices)
    }

    private static let maxCharacters = 40
    /// One Character can carry thousands of combining marks, so scalars are capped as well.
    private static let maxScalars = 160

    /// Makes text taken from file metadata safe to show on one short line.
    public static func displayValue(_ text: String) -> String {
        let shown = Array(text.unicodeScalars.lazy.filter(isDisplayable).prefix(maxScalars + 1))
        var view = String.UnicodeScalarView()
        view.append(contentsOf: shown.prefix(maxScalars))
        let result = String(view)
        guard shown.count > maxScalars || result.count > maxCharacters else { return result }
        return String(result.prefix(maxCharacters)) + "…"
    }

    /// Controls and line separators break a title across lines; bidi overrides make a name read differently.
    private static func isDisplayable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029: return false
        default: return scalar.properties.generalCategory != .control
        }
    }
}

public extension ColumnFilters {
    /// Active columns in `order`, then any others by id, so wording never follows dictionary order.
    func orderedColumns(_ order: [ColumnID]) -> [ColumnID] {
        let active = Set(columns)
        return order.filter(active.contains) + active.subtracting(order).sorted { $0.rawValue < $1.rawValue }
    }

    func summaries(order: [ColumnID], items: [FileItem], ctx: GroupingContext = GroupingContext(),
                   lookup: ColumnValueLookup?) -> [ColumnFilterSummary] {
        orderedColumns(order).map { column in
            let range = dateRange(column).map { $0.title(calendar: ctx.calendar) }
            let checked = selected(column)
            let present = checked.isEmpty ? [] : ColumnFilters.options(for: column, items: items, ctx: ctx, lookup: lookup)
                .filter { checked.contains($0.id) }.map { ColumnFilterSummary.displayValue($0.title) }
            let values = (range.map { [$0] } ?? []) + present
            let total = (range == nil ? 0 : 1) + checked.count
            let shown = Array(values.prefix(ColumnFilterSummary.maxValues))
            return ColumnFilterSummary(column: column, values: shown, moreCount: total - shown.count)
        }
    }
}
