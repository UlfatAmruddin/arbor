import Foundation

/// Collects main-thread stalls: run-loop passes that kept the main thread busy longer than a threshold
/// (spec §15.4 "scroll stalls", FE-228). Labels say what was going on (a script step, a workload).
/// Main thread only.
public final class StallRecorder {
    public struct Stall: Equatable, Sendable {
        public let label: String
        public let milliseconds: Double
    }

    public let thresholdMilliseconds: Double
    /// Most recent stalls first dropped beyond this many.
    public let capacity: Int
    public private(set) var stalls: [Stall] = []
    /// Stalls seen in total (including those dropped from `stalls`).
    public private(set) var totalCount = 0
    /// Labels whose stalls are expected and excluded from summaries (snapshots, scripted pauses).
    public var ignoredLabels: Set<String> = []

    public init(thresholdMilliseconds: Double = 50, capacity: Int = 2000) {
        self.thresholdMilliseconds = thresholdMilliseconds
        self.capacity = capacity
    }

    /// Records one busy period; returns true when it counted as a stall.
    @discardableResult
    public func record(milliseconds: Double, label: String) -> Bool {
        guard milliseconds > thresholdMilliseconds else { return false }
        totalCount += 1
        stalls.append(Stall(label: label, milliseconds: milliseconds))
        if stalls.count > capacity { stalls.removeFirst(stalls.count - capacity) }
        return true
    }

    public func reset() {
        stalls.removeAll()
        totalCount = 0
    }

    /// Stalls whose label starts with `prefix` (all when empty), ignored labels left out.
    public func stalls(matching prefix: String = "") -> [Stall] {
        stalls.filter { stall in
            !ignoredLabels.contains(where: { stall.label.hasPrefix($0) }) && (prefix.isEmpty || stall.label.hasPrefix(prefix))
        }
    }

    /// `count=… max=…ms total=…ms` for stalls matching `prefix`.
    public func summary(matching prefix: String = "") -> String {
        let list = stalls(matching: prefix)
        let longest = list.map(\.milliseconds).max() ?? 0
        let total = list.reduce(0) { $0 + $1.milliseconds }
        return String(format: "count=%d max=%.0fms total=%.0fms", list.count, longest, total)
    }
}
