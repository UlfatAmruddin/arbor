import Foundation

/// Least-recently-used cache bounded by a byte budget (spec §15.3, FE-243): each entry carries its
/// decoded cost, and inserting past the budget evicts the oldest entries first. Not thread-safe; use it
/// from one queue (the main thread for thumbnails).
public final class ByteBudgetCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var newer: Node?
        weak var older: Node?
        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    public var byteLimit: Int { didSet { evict() } }
    public private(set) var totalCost = 0
    public var count: Int { nodes.count }

    private var nodes: [Key: Node] = [:]
    /// Least recently used end.
    private var oldest: Node?
    /// Most recently used end.
    private weak var newest: Node?

    public init(byteLimit: Int) { self.byteLimit = byteLimit }

    /// Looks up an entry and marks it recently used.
    public func value(for key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        touch(node)
        return node.value
    }

    /// Looks up an entry without changing its age.
    public func peek(_ key: Key) -> Value? { nodes[key]?.value }

    public func contains(_ key: Key) -> Bool { nodes[key] != nil }

    /// Stores a value. An entry larger than the whole budget is not kept.
    public func insert(_ value: Value, for key: Key, cost: Int) {
        let cost = max(0, cost)
        if let existing = nodes[key] {
            totalCost += cost - existing.cost
            existing.value = value
            existing.cost = cost
            touch(existing)
        } else {
            guard cost <= byteLimit else { return }
            let node = Node(key: key, value: value, cost: cost)
            nodes[key] = node
            append(node)
            totalCost += cost
        }
        evict()
    }

    public func remove(_ key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        unlink(node)
        totalCost -= node.cost
    }

    public func removeAll() {
        // Break the strong chain iteratively so a long list doesn't recurse on release.
        var node = oldest
        while let current = node {
            node = current.newer
            current.newer = nil
        }
        nodes.removeAll()
        oldest = nil
        newest = nil
        totalCost = 0
    }

    /// Evicts oldest entries until at most `bytes` remain (memory pressure).
    public func trim(toBytes bytes: Int) {
        while totalCost > bytes, let victim = oldest { remove(victim.key) }
    }

    /// Keys from least to most recently used (for tests and diagnostics).
    public var keysByAge: [Key] {
        var result: [Key] = []
        var node = oldest
        while let current = node {
            result.append(current.key)
            node = current.newer
        }
        return result
    }

    private func evict() { trim(toBytes: byteLimit) }

    private func append(_ node: Node) {
        node.older = newest
        node.newer = nil
        if let newest { newest.newer = node } else { oldest = node }
        newest = node
    }

    private func unlink(_ node: Node) {
        let older = node.older, newer = node.newer
        if let older { older.newer = newer } else { oldest = newer }
        if let newer { newer.older = older } else { newest = older }
        node.older = nil
        node.newer = nil
    }

    private func touch(_ node: Node) {
        guard newest !== node else { return }
        unlink(node)
        append(node)
    }
}
