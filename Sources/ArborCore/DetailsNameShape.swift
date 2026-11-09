import Foundation

/// Where a Details name cell draws its icon and name along x: the part of a row that counts as the item (FE-058).
public struct DetailsNameShape: Equatable, Sendable {
    public static let iconLeading: CGFloat = 6
    public static let iconLeadingWithCheckbox: CGFloat = 26
    public static let iconSize: CGFloat = 16
    public static let iconTextGap: CGFloat = 8
    public static let textTrailing: CGFloat = 2
    /// Margin past the measured text, so a press on the last glyph is never read as row space.
    public static let textMargin: CGFloat = 2

    /// How much of the rows a band's horizontal extent can touch.
    public enum Reach: Sendable {
        case none
        /// It crosses the icon strip, which every row has.
        case everyRow
        /// It depends on how long each name is.
        case measure
    }

    public let icon: ClosedRange<CGFloat>
    /// The name's text field.
    public let field: ClosedRange<CGFloat>
    private let rightToLeft: Bool

    public init(column: ClosedRange<CGFloat>, hasCheckbox: Bool, rightToLeft: Bool) {
        self.rightToLeft = rightToLeft
        let leading = hasCheckbox ? Self.iconLeadingWithCheckbox : Self.iconLeading
        let iconMinX = rightToLeft ? column.upperBound - leading - Self.iconSize : column.lowerBound + leading
        icon = iconMinX...(iconMinX + Self.iconSize)
        let fieldMinX = rightToLeft ? column.lowerBound + Self.textTrailing : icon.upperBound + Self.iconTextGap
        let fieldMaxX = rightToLeft ? icon.lowerBound - Self.iconTextGap : column.upperBound - Self.textTrailing
        field = fieldMinX...max(fieldMinX, fieldMaxX)
    }

    /// The icon and name together; `fillsField` when the text may not start at the field's leading edge.
    public func extent(textWidth: CGFloat, fillsField: Bool) -> ClosedRange<CGFloat> {
        // A right-to-left layout draws a left-to-right name at the far side of the field.
        guard !fillsField, !rightToLeft else { return Self.union(icon, field) }
        let textMaxX = min(field.upperBound, field.lowerBound + max(textWidth, 0) + Self.textMargin)
        return Self.union(icon, field.lowerBound...textMaxX)
    }

    public func reach(band: ClosedRange<CGFloat>) -> Reach {
        if icon.overlaps(band) { return .everyRow }
        return Self.union(icon, field).overlaps(band) ? .measure : .none
    }

    private static func union(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }

    /// Such names can be drawn away from the leading edge, whatever their measured width says.
    public static func containsRightToLeftScript(_ name: String) -> Bool {
        name.unicodeScalars.contains { scalar in
            scalar.value >= 0x0590 && (scalar.properties.isBidiControl || rightToLeftBlocks.contains { $0.contains(scalar.value) })
        }
    }

    private static let rightToLeftBlocks: [ClosedRange<UInt32>] = [
        0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF,
    ]
}
