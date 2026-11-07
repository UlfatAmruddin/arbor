import Foundation

/// Least-recently-used bookkeeping for listings kept by tabs (spec §15.3, FE-251): a byte budget
/// shared by every tab in every window, instead of a fixed number of listings (eight 100,000-entry
/// listings would be ~700 MB). Listings on screen are never evicted.
public struct ListingBudget {
    public var byteLimit: Int
    /// Oldest first.
    private var order: [String] = []
    private var costs: [String: Int] = [:]
    public private(set) var totalCost = 0

    public init(byteLimit: Int) { self.byteLimit = byteLimit }

    public var count: Int { order.count }

    /// Records a listing (new or replaced) as most recently used. Returns the ids to evict.
    public mutating func touch(_ id: String, cost: Int, active: Set<String>) -> [String] {
        remove(id)
        order.append(id)
        costs[id] = cost
        totalCost += cost
        return trim(toBytes: byteLimit, active: active)
    }

    public mutating func remove(_ id: String) {
        guard let cost = costs.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        totalCost -= cost
    }

    /// Evicts the oldest inactive listings until at most `bytes` remain. Returns their ids.
    public mutating func trim(toBytes bytes: Int, active: Set<String>) -> [String] {
        var evicted: [String] = []
        var index = 0
        while totalCost > bytes, index < order.count {
            let id = order[index]
            if active.contains(id) { index += 1; continue }
            order.remove(at: index)
            totalCost -= costs.removeValue(forKey: id) ?? 0
            evicted.append(id)
        }
        return evicted
    }
}
