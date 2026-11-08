import Foundation

/// Speed and time remaining (FE-114), smoothed over a sliding window. Nothing is reported until it means
/// something ("Calculating…", spec §9.2). Pausing ends the window; resuming starts a new one.
public struct TransferRateEstimator: Sendable {
    public let window: TimeInterval
    public let minimumElapsed: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var activeSince: TimeInterval?
    private var smoothed: Double?
    private var smoothedETA: Double?
    private var paused = false

    public init(window: TimeInterval = 4, minimumElapsed: TimeInterval = 1.5) {
        self.window = window
        self.minimumElapsed = minimumElapsed
    }

    /// Records the cumulative bytes transferred at `time` (seconds, any monotonic clock).
    public mutating func record(bytes: Int64, at time: TimeInterval) {
        guard !paused else { return }
        if activeSince == nil { activeSince = time }
        if let last = samples.last, bytes < last.bytes {
            samples.removeAll()   // a retried file un-counted its bytes; start over
        }
        samples.append((time, bytes))
        while let first = samples.first, time - first.time > window, samples.count > 2 { samples.removeFirst() }
        guard let first = samples.first, time - first.time >= 0.5 else { return }
        let rate = Double(bytes - first.bytes) / (time - first.time)
        smoothed = smoothed.map { $0 * 0.7 + rate * 0.3 } ?? rate
    }

    public mutating func pause() {
        paused = true
        samples.removeAll()
        activeSince = nil
        smoothedETA = nil
    }

    public mutating func resume() { paused = false }

    /// Bytes per second, or nil while still calculating.
    public func bytesPerSecond(at time: TimeInterval) -> Double? {
        // Runs of empty items decay the rate toward zero; below 1 B/s it says nothing useful.
        guard !paused, let start = activeSince, time - start >= minimumElapsed, let rate = smoothed, rate >= 1 else { return nil }
        return rate
    }

    /// Smoothed seconds left for `remaining` bytes; nil while still calculating.
    public mutating func secondsRemaining(_ remaining: Int64, at time: TimeInterval) -> TimeInterval? {
        guard let rate = bytesPerSecond(at: time) else { return nil }
        let raw = Double(max(remaining, 0)) / rate
        let value = smoothedETA.map { $0 * 0.6 + raw * 0.4 } ?? raw
        smoothedETA = value
        return value
    }

    // MARK: Wording

    /// Explorer's "Time remaining" wording: "About 10 seconds", "About 1 hour and 5 minutes"…
    public static func describeRemaining(_ seconds: TimeInterval) -> String {
        // Past about 30 years the estimate is meaningless, and far past it Int(_:) traps.
        guard seconds.isFinite, seconds < 1e9 else { return L10n.tr("Calculating…") }
        let s = max(0, seconds)
        if s < 60 {
            let rounded = max(5, Int((s / 5).rounded(.up)) * 5)
            return rounded >= 60 ? L10n.tr("About 1 minute") : L10n.format("About %@ seconds", "\(rounded)")
        }
        let minutes = Int((s / 60).rounded())
        if minutes < 60 { return minutes == 1 ? L10n.tr("About 1 minute") : L10n.format("About %@ minutes", "\(minutes)") }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 48 {
            // Whole sentences, so translations never assemble "hour(s)" and "minute(s)" themselves.
            switch (hours == 1, rest) {
            case (true, 0): return L10n.tr("About 1 hour")
            case (false, 0): return L10n.format("About %@ hours", "\(hours)")
            case (true, 1): return L10n.tr("About 1 hour and 1 minute")
            case (true, _): return L10n.format("About 1 hour and %@ minutes", "\(rest)")
            case (false, 1): return L10n.format("About %@ hours and 1 minute", "\(hours)")
            case (false, _): return L10n.format("About %@ hours and %@ minutes", "\(hours)", "\(rest)")
            }
        }
        return L10n.format("About %@ days", "\(Int((Double(hours) / 24).rounded()))")
    }

    /// "45.2 MB/s", "812 KB/s": Explorer's adaptive 1024-based units with three significant digits.
    public static func describeSpeed(_ bytesPerSecond: Double) -> String {
        // A claimed size near Int64.max can push the rate past what Int64 holds.
        ExplorerSize.adaptive(Int64(Int(checked: bytesPerSecond.rounded()) ?? (bytesPerSecond > 0 ? .max : 0))) + "/s"
    }
}
