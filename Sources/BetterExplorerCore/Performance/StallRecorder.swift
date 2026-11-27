import Foundation

/// Run-loop passes that kept the main thread busy past a threshold (spec §15.4, FE-228). Main thread only.
public final class StallRecorder {
    public struct Stall: Equatable, Sendable {
        public let label: String
        public let milliseconds: Double
    }

    public let thresholdMilliseconds: Double
    /// Oldest stalls are dropped beyond this many.
    public let capacity: Int
    public private(set) var stalls: [Stall] = []
    /// Includes stalls dropped from `stalls`.
    public private(set) var totalCount = 0
    /// Label prefixes of expected stalls, left out of summaries.
    public var ignoredLabels: Set<String> = []

    public init(thresholdMilliseconds: Double = 50, capacity: Int = 2000) {
        self.thresholdMilliseconds = thresholdMilliseconds
        self.capacity = capacity
    }

    /// Returns true when the period counted as a stall.
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

    /// Empty `prefix` matches all; ignored labels are excluded.
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
