import Foundation

/// One rubber-band drag (FE-058): the rules every layout shares, in the coordinates of the view it runs in.
public struct MarqueeDrag: Equatable, Sendable {
    /// Measuring more candidates than this would stall the drag, so they all count as hits.
    public static let preciseHitLimit = 3000

    public let start: CGPoint
    /// The selection the drag's hits combine with.
    public let base: IndexSet
    public let toggle: Bool
    public let add: Bool

    public init(start: CGPoint, base: IndexSet, toggle: Bool, add: Bool) {
        self.start = start
        self.base = base
        self.toggle = toggle
        self.add = add
    }

    /// The band from the start to `point`, kept inside `bounds`.
    public func band(to point: CGPoint, within bounds: CGRect) -> CGRect {
        let end = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public func selection(hits: IndexSet) -> IndexSet {
        ItemSelection.marquee(base: base, hits: hits, toggle: toggle, add: add)
    }

    /// Points to scroll along one axis for a pointer outside `low...high`; 0 inside. Faster the further out it is.
    public static func autoscrollStep(pointer: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        let overshoot = pointer < low ? pointer - low : (pointer > high ? pointer - high : 0)
        guard overshoot != 0 else { return 0 }
        return (overshoot < 0 ? -1 : 1) * min(max(abs(overshoot) * 0.6, 6), 80)
    }
}
