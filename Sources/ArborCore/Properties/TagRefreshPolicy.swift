import Foundation

/// When the Tags section may start another Spotlight run (FE-081): one at a time, at most once a minute.
public enum TagRefreshPolicy {
    public static let minimumInterval: TimeInterval = 60

    /// `now` and `lastStart` come from one monotonic clock.
    public static func mayStart(isRunning: Bool, lastStart: TimeInterval?, now: TimeInterval) -> Bool {
        guard !isRunning else { return false }
        guard let lastStart else { return true }
        return now - lastStart >= minimumInterval
    }
}
