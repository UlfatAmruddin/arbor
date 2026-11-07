import Foundation

/// Coalesces bursts of change notifications into reloads (spec §15.3, FE-229): the first change in a
/// quiet period is answered quickly, changes during a burst produce at most one reload per
/// `minimumSpacing`, and the last change of a burst always gets a reload (nothing is lost).
///
/// Before, every event restarted a 0.15 s timer: a folder that kept changing (a copy into it) never
/// refreshed until the copy ended, and each refresh of a large folder restarted the listing.
public struct EventThrottle {
    public var quietDelay: TimeInterval
    public var minimumSpacing: TimeInterval
    private var lastFire: TimeInterval = -.infinity
    private var scheduled: TimeInterval?

    public init(quietDelay: TimeInterval = 0.15, minimumSpacing: TimeInterval = 1.0) {
        self.quietDelay = quietDelay
        self.minimumSpacing = minimumSpacing
    }

    /// A change arrived at `now`. Returns the delay after which to fire, or nil when a fire is already
    /// scheduled (it will include this change).
    public mutating func event(at now: TimeInterval) -> TimeInterval? {
        guard scheduled == nil else { return nil }
        let at = max(now + quietDelay, lastFire + minimumSpacing)
        scheduled = at
        return at - now
    }

    /// The scheduled fire happened at `now`.
    public mutating func fired(at now: TimeInterval) {
        scheduled = nil
        lastFire = now
    }

    public mutating func reset() {
        scheduled = nil
        lastFire = -.infinity
    }
}
