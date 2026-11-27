import Foundation

public extension Int {
    /// Truncates like `Int(_:)`, but nil instead of a trap for NaN, infinity or out-of-range metadata values.
    init?(checked d: Double) {
        guard d.isFinite, d >= -0x1p63, d < 0x1p63 else { return nil }
        self.init(d)
    }
}

public extension Int64 {
    /// Clamps at the bounds instead of trapping; sizes reported by a volume or server can be anything.
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

public extension Sequence where Element == Int64 {
    /// Saturating sum of byte counts.
    func saturatingSum() -> Int64 { reduce(0) { $0.saturatingAdd($1) } }
}
