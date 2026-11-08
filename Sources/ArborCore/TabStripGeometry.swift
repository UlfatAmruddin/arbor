import CoreGraphics

/// Where a tab dragged inside the tab row lands (FE-019, FE-204). Tabs are laid out from the leading edge,
/// which is the right edge in a right-to-left layout, so positions are measured from that edge first.
public enum TabStripGeometry {
    /// - Parameters:
    ///   - tabMinX: the dragged tab view's left edge in the row's content (left-to-right coordinates).
    ///   - viewWidth: the tab view's width (the tab plus its outward "feet").
    ///   - contentWidth: the width of the row's content (all tabs plus the feet at both ends).
    /// - Returns: the slot under the tab's middle, counted from the leading edge, clamped to `0..<count`.
    public static func reorderSlot(tabMinX: CGFloat, tabWidth: CGFloat, viewWidth: CGFloat, contentWidth: CGFloat,
                                   count: Int, rightToLeft: Bool) -> Int {
        guard count > 0, tabWidth > 0 else { return 0 }
        let leading = rightToLeft ? contentWidth - tabMinX - viewWidth : tabMinX
        let index = Int(floor((leading + tabWidth / 2) / tabWidth))
        return min(max(index, 0), count - 1)
    }
}
