import Foundation

/// The order features register in: a stable topological sort of their `requires` (DEC-024).
///
/// Features keep the order they are listed in unless a requirement forces one later, so adding a
/// feature never reshuffles the others. Problems are reported with the ids involved.
public enum FeatureGraph {
    public struct Node: Equatable, Sendable {
        public let id: String
        public let requires: [String]

        public init(_ id: String, requires: [String] = []) {
            self.id = id
            self.requires = requires
        }
    }

    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        /// Two features use the same id.
        case duplicateID(String)
        /// `feature` requires `missing`, which isn't listed.
        case missingDependency(feature: String, missing: String)
        /// The features in the cycle, ending with the first again ("a → b → a").
        case cycle([String])

        public var description: String {
            switch self {
            case .duplicateID(let id):
                return "Feature id \"\(id)\" is listed twice in Features.registerAll()."
            case .missingDependency(let feature, let missing):
                return "Feature \"\(feature)\" requires \"\(missing)\", which isn't listed in Features.registerAll()."
            case .cycle(let path):
                return "Features require each other in a cycle: \(path.joined(separator: " → "))."
            }
        }
    }

    /// The ids in registration order: every feature after the features it requires, otherwise in listed order.
    public static func order(_ nodes: [Node]) throws -> [String] {
        var seen = Set<String>()
        for node in nodes {
            guard seen.insert(node.id).inserted else { throw Problem.duplicateID(node.id) }
        }
        for node in nodes {
            for required in node.requires where !seen.contains(required) {
                throw Problem.missingDependency(feature: node.id, missing: required)
            }
        }
        var placed = Set<String>()
        var result: [String] = []
        var remaining = nodes
        while !remaining.isEmpty {
            // The first listed feature whose requirements are all placed.
            guard let index = remaining.firstIndex(where: { $0.requires.allSatisfy(placed.contains) }) else {
                throw Problem.cycle(cycle(in: remaining))
            }
            let node = remaining.remove(at: index)
            placed.insert(node.id)
            result.append(node.id)
        }
        return result
    }

    /// True when every feature comes after everything it requires.
    public static func satisfies(_ order: [String], _ nodes: [Node]) -> Bool {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return nodes.allSatisfy { node in
            guard let mine = position[node.id] else { return false }
            return node.requires.allSatisfy { position[$0].map { $0 < mine } ?? false }
        }
    }

    /// One cycle among nodes that can't be placed (each of them requires another one of them).
    private static func cycle(in nodes: [Node]) -> [String] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard var current = nodes.first?.id else { return [] }
        var path: [String] = []
        while !path.contains(current) {
            path.append(current)
            // Some requirement of a stuck node is itself stuck (otherwise the node could be placed).
            guard let next = byID[current]?.requires.first(where: { byID[$0] != nil }) else { return path }
            current = next
        }
        let start = path.firstIndex(of: current) ?? 0
        return Array(path[start...]) + [current]
    }
}
