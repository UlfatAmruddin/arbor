import CoreGraphics

/// Drop slot for a tab dragged within the row (FE-019, FE-204), counted from the leading edge (right in RTL).
public enum TabStripGeometry {
    /// `tabMinX`: tab view's left edge in content (LTR) coordinates; `viewWidth` includes its "feet";
    /// `contentWidth` spans all tabs plus end feet. Returns the slot under the tab's middle, clamped to `0..<count`.
    public static func reorderSlot(tabMinX: CGFloat, tabWidth: CGFloat, viewWidth: CGFloat, contentWidth: CGFloat,
                                   count: Int, rightToLeft: Bool) -> Int {
        guard count > 0, tabWidth > 0 else { return 0 }
        let leading = rightToLeft ? contentWidth - tabMinX - viewWidth : tabMinX
        let index = Int(floor((leading + tabWidth / 2) / tabWidth))
        return min(max(index, 0), count - 1)
    }
}
