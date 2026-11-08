import Foundation

/// LRU byte budget for tab listings, shared by all windows (spec §15.3, FE-251); a fixed count could
/// reach ~700 MB. Listings on screen are never evicted.
public struct ListingBudget {
    public var byteLimit: Int
    /// Oldest first.
    private var order: [String] = []
    private var costs: [String: Int] = [:]
    public private(set) var totalCost = 0

    public init(byteLimit: Int) { self.byteLimit = byteLimit }

    public var count: Int { order.count }

    /// Marks a listing most recently used; returns the ids to evict.
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

    /// Evicts oldest inactive listings until at most `bytes` remain; returns their ids.
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
