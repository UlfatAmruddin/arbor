import Foundation

/// Coalesces change bursts into reloads (spec §15.3, FE-229): quick first reload, then at most one per
/// `minimumSpacing`, and the last change always reloads. A restarting debounce never fired during a long copy.
public struct EventThrottle {
    public var quietDelay: TimeInterval
    public var minimumSpacing: TimeInterval
    private var lastFire: TimeInterval = -.infinity
    private var scheduled: TimeInterval?

    public init(quietDelay: TimeInterval = 0.15, minimumSpacing: TimeInterval = 1.0) {
        self.quietDelay = quietDelay
        self.minimumSpacing = minimumSpacing
    }

    /// Delay until firing, or nil when a fire is already scheduled (it covers this change).
    public mutating func event(at now: TimeInterval) -> TimeInterval? {
        guard scheduled == nil else { return nil }
        let at = max(now + quietDelay, lastFire + minimumSpacing)
        scheduled = at
        return at - now
    }

    public mutating func fired(at now: TimeInterval) {
        scheduled = nil
        lastFire = now
    }

    public mutating func reset() {
        scheduled = nil
        lastFire = -.infinity
    }
}
