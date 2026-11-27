import Foundation

/// What the height of a wrapped Details row depends on (FE-055); any change means every name is measured again.
public struct NameWrapMetrics: Equatable, Sendable {
    /// Longer names are shortened in the middle, like the icon views' labels (DEC-013).
    public static let maxLines = 3

    public let fieldWidth: CGFloat
    public let lineHeight: CGFloat
    public let baseRowHeight: CGFloat
    public let showsExtensions: Bool

    public init(fieldWidth: CGFloat, lineHeight: CGFloat, baseRowHeight: CGFloat, showsExtensions: Bool) {
        self.fieldWidth = fieldWidth
        self.lineHeight = lineHeight
        self.baseRowHeight = baseRowHeight
        self.showsExtensions = showsExtensions
    }

    public var maxTextHeight: CGFloat { CGFloat(Self.maxLines) * lineHeight }

    /// One point of slack: the height of several lines isn't always a multiple of a rounded line.
    public func fitsWithinLines(_ measured: CGFloat) -> Bool { measured <= maxTextHeight + 1 }

    public func textHeight(measured: CGFloat) -> CGFloat {
        guard measured.isFinite else { return lineHeight }
        return min(max(measured, lineHeight), maxTextHeight)
    }

    /// A name on one line gets exactly the ordinary row height.
    public func rowHeight(textHeight: CGFloat) -> CGFloat { baseRowHeight + max(textHeight - lineHeight, 0) }
}

/// A name as a wrapped cell shows it. Hashable: the measured height is remembered per text.
public struct NameWrapText: Hashable, Sendable {
    public static let extensionBreak = "\u{200B}"

    public let name: String
    public let keepsExtension: Bool

    /// A file name can hold line breaks, which would push the rest of it, even its extension, out of the cell.
    public init(_ name: String, keepsExtension: Bool) {
        self.name = name.contains(where: \.isNewline) ? String(name.map { $0.isNewline ? " " : $0 }) : name
        self.keepsExtension = keepsExtension
    }

    /// The text to lay out: the break before the extension lets it move to the next line whole.
    public var display: String { Self.display(name, keepsExtension: keepsExtension) }

    /// Shortened in the middle, keeping the extension, until `fits` accepts its display text.
    public func shortened(fits: (String) -> Bool) -> String {
        let shorter = MiddleTruncation.fit(name) { fits(Self.display($0, keepsExtension: keepsExtension)) }
        return Self.display(shorter, keepsExtension: keepsExtension)
    }

    private static func display(_ name: String, keepsExtension: Bool) -> String {
        guard keepsExtension, let ext = NameRules.splitExtension(name, treatAsFolder: false).ext else { return name }
        return name.dropLast(ext.count + 1) + extensionBreak + "." + ext
    }
}

/// Measured name heights: a name is measured once, and only when the table asks for its row.
public struct NameWrapHeights: Sendable {
    /// A ceiling in case the table ever asks for every row at once; about 45 milliseconds of measuring.
    public static let measurementsPerTurn = 1000

    public enum Request: Equatable, Sendable {
        /// The first of this run loop turn: the caller schedules `endTurn`.
        case first
        case granted
        /// The allowance is spent: the caller answers one line for now.
        case refused
    }

    private var heights: [NameWrapText: Float] = [:]
    private var spent = 0
    private var refused = false

    public init() {}

    public var count: Int { heights.count }

    public func height(of text: NameWrapText) -> CGFloat? { heights[text].map { CGFloat($0) } }

    public mutating func record(_ height: CGFloat, for text: NameWrapText) { heights[text] = Float(height) }

    public mutating func removeAll() { heights.removeAll() }

    public mutating func requestMeasurement() -> Request {
        guard spent < Self.measurementsPerTurn else {
            refused = true
            return .refused
        }
        spent += 1
        return spent == 1 ? .first : .granted
    }

    /// True when a row was refused this turn and its table must ask again.
    public mutating func endTurn() -> Bool {
        defer { spent = 0; refused = false }
        return refused
    }
}
