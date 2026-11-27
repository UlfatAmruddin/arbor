import Foundation

// Typed extension points so features plug into shared code without clobbering each other
// (DEC-024, docs/EXTENSION-POINTS.md). Contributions run by order, then registration sequence;
// duplicate ids and second providers go to `ExtensionRegistry`. Configured once at launch on the
// main thread, then read-only: calling a point doesn't allocate or lock, so hot paths are fine.

/// Lower runs first.
public struct ExtensionOrder: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let rank: Int

    public init(_ rank: Int) { self.rank = rank }

    public static let first = ExtensionOrder(-2000)
    public static let early = ExtensionOrder(-1000)
    public static let normal = ExtensionOrder(0)
    public static let late = ExtensionOrder(1000)
    public static let last = ExtensionOrder(2000)
    /// E.g. `.custom(-500)` runs between `.early` and `.normal`.
    public static func custom(_ rank: Int) -> ExtensionOrder { ExtensionOrder(rank) }

    public static func < (a: ExtensionOrder, b: ExtensionOrder) -> Bool { a.rank < b.rank }

    public var description: String {
        switch rank {
        case -2000: return "first"
        case -1000: return "early"
        case 0: return "normal"
        case 1000: return "late"
        case 2000: return "last"
        default: return "custom(\(rank))"
        }
    }
}

public enum ExtensionKind: String, Sendable {
    case handlers = "Handlers", observers = "Observers", pipeline = "Pipeline", provided = "Provided"
}

/// A registration mistake: duplicate id, second provider, or another failed check.
public struct ExtensionError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Problem: Equatable, Sendable {
        case duplicateID
        case secondProvider
        case other(String)
    }

    public let point: String
    public let problem: Problem
    /// With its feature, when known.
    public let existing: String
    public let rejected: String

    public init(point: String, problem: Problem, existing: String, rejected: String) {
        self.point = point
        self.problem = problem
        self.existing = existing
        self.rejected = rejected
    }

    public var description: String {
        switch problem {
        case .duplicateID:
            return "Extension point \(point): contribution id \"\(rejected)\" is registered twice (first by \(existing)). Give each contribution its own id."
        case .secondProvider:
            return "Extension point \(point) is already provided by \"\(existing)\"; \"\(rejected)\" can't provide it too. A Provided point takes exactly one provider."
        case .other(let text):
            var parts: [String] = []
            if !rejected.isEmpty { parts.append("refused: \(rejected)") }
            if !existing.isEmpty { parts.append("already there: \(existing)") }
            return "Extension point \(point): \(text)" + (parts.isEmpty ? "" : " (" + parts.joined(separator: "; ") + ")")
        }
    }
}

/// Collects registration errors for tests and the launch check. The app uses `shared`; tests make their own.
public final class ExtensionRegistry: @unchecked Sendable {
    public static let shared = ExtensionRegistry(assertsOnError: true)

    public private(set) var errors: [ExtensionError] = []
    /// Debug builds assert on the first error; errors are always recorded.
    public var assertsOnError: Bool
    /// The feature whose `register()` is running, recorded with each contribution.
    public var currentFeature: String?

    public init(assertsOnError: Bool = false) {
        self.assertsOnError = assertsOnError
    }

    public func report(_ error: ExtensionError) {
        errors.append(error)
        if assertsOnError { assertionFailure(error.description) }
    }

    /// For problems other than duplicate ids or second providers.
    public func report(point: String, _ text: String, contribution: String = "", existing: String = "") {
        report(ExtensionError(point: point, problem: .other(text), existing: existing, rejected: contribution))
    }

    public var failureMessage: String? {
        errors.isEmpty ? nil : (["\(errors.count) extension registration error(s):"] + errors.map { "- \($0.description)" })
            .joined(separator: "\n")
    }

    public func removeAllErrors() { errors.removeAll() }
}

public struct ExtensionContribution: Equatable, Sendable, CustomStringConvertible {
    public let id: String
    public let order: ExtensionOrder
    /// Set when registered through `Features.registerAll()`.
    public let feature: String?
    let sequence: Int

    public var description: String {
        "\(id) [\(order)\(feature.map { ", \($0)" } ?? "")]"
    }
}

public protocol ExtensionPointInfo: AnyObject {
    var name: String { get }
    var kind: ExtensionKind { get }
    /// One sentence.
    var purpose: String { get }
    /// E.g. "(FileItem, Location?) -> (label, value)".
    var signature: String { get }
    /// In run order.
    var contributions: [ExtensionContribution] { get }
}

extension ExtensionPointInfo {
    public var contributionIDs: [String] { contributions.map(\.id) }

    /// "Handlers InteractionHooks.openFile: archives.open-file [early, archives], …"
    public var listing: String {
        let list = contributions.isEmpty ? "(none)" : contributions.map(\.description).joined(separator: ", ")
        return "\(kind.rawValue) \(name): \(list)"
    }
}

/// Sorted by order, then sequence; bodies in a parallel array so a call is a plain loop.
@usableFromInline
struct ContributionList<Body> {
    @usableFromInline var bodies: [Body] = []
    var entries: [ExtensionContribution] = []
    private var nextSequence = 0

    @usableFromInline init() {}

    /// Returns an error instead when the id is already used.
    mutating func insert(_ id: String, order: ExtensionOrder, feature: String?, body: Body, point: String) -> ExtensionError? {
        if let existing = entries.first(where: { $0.id == id }) {
            let who = existing.feature.map { "feature \"\($0)\"" } ?? "an earlier registration"
            let rejected = feature.map { "\(id) (feature \"\($0)\")" } ?? id
            return ExtensionError(point: point, problem: .duplicateID, existing: who, rejected: rejected)
        }
        let entry = ExtensionContribution(id: id, order: order, feature: feature, sequence: nextSequence)
        nextSequence += 1
        let index = entries.firstIndex { $0.order > order } ?? entries.count   // stable
        entries.insert(entry, at: index)
        bodies.insert(body, at: index)
        return nil
    }

    mutating func remove(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        bodies.remove(at: index)
    }

    func index(of id: String) -> Int? { entries.firstIndex { $0.id == id } }
}

// MARK: - Handlers

/// Chain of responsibility: `first(_:)` returns the first non-nil answer in run order.
public final class Handlers<Input, Output>: ExtensionPointInfo {
    public let name: String
    public let purpose: String
    public let signature: String
    public var kind: ExtensionKind { .handlers }
    @usableFromInline var list = ContributionList<(Input) -> Output?>()
    private let registry: ExtensionRegistry

    public init(_ name: String, _ purpose: String = "", signature: String = "", registry: ExtensionRegistry = .shared) {
        self.name = name
        self.purpose = purpose
        self.signature = signature
        self.registry = registry
    }

    public var contributions: [ExtensionContribution] { list.entries }

    /// Return nil to let later handlers (and the default) answer.
    public func register(_ id: String, order: ExtensionOrder = .normal, _ handler: @escaping (Input) -> Output?) {
        if let error = list.insert(id, order: order, feature: registry.currentFeature, body: handler, point: name) {
            registry.report(error)
        }
    }

    @inlinable
    public func first(_ input: Input) -> Output? {
        for handler in list.bodies {
            if let output = handler(input) { return output }
        }
        return nil
    }

    /// The answer `id` replaced, so it can "do this, then what would have happened".
    public func first(_ input: Input, after id: String) -> Output? {
        guard let index = list.index(of: id) else { return first(input) }
        for handler in list.bodies[(index + 1)...] {
            if let output = handler(input) { return output }
        }
        return nil
    }

    @inlinable
    public var isEmpty: Bool { list.bodies.isEmpty }

    /// For tests and temporary contributions.
    public func remove(_ id: String) { list.remove(id) }
}

extension Handlers where Output == Void {
    /// Return true to stop later handlers.
    public func register(_ id: String, order: ExtensionOrder = .normal, handles: @escaping (Input) -> Bool) {
        register(id, order: order) { input -> Void? in handles(input) ? () : nil }
    }

    @inlinable
    public func handle(_ input: Input) -> Bool { first(input) != nil }
}

// MARK: - Observers

/// Did/will events: `send(_:)` calls every contribution.
public final class Observers<Input>: ExtensionPointInfo {
    public let name: String
    public let purpose: String
    public let signature: String
    public var kind: ExtensionKind { .observers }
    @usableFromInline var list = ContributionList<(Input) -> Void>()
    private let registry: ExtensionRegistry

    public init(_ name: String, _ purpose: String = "", signature: String = "", registry: ExtensionRegistry = .shared) {
        self.name = name
        self.purpose = purpose
        self.signature = signature
        self.registry = registry
    }

    public var contributions: [ExtensionContribution] { list.entries }

    public func observe(_ id: String, order: ExtensionOrder = .normal, _ handler: @escaping (Input) -> Void) {
        if let error = list.insert(id, order: order, feature: registry.currentFeature, body: handler, point: name) {
            registry.report(error)
        }
    }

    @inlinable
    public func send(_ input: Input) {
        for handler in list.bodies { handler(input) }
    }

    @inlinable
    public var isEmpty: Bool { list.bodies.isEmpty }

    public func remove(_ id: String) { list.remove(id) }
}

// MARK: - Pipeline

/// `apply(_:_:)` passes the value through every contribution in run order.
public final class Pipeline<Value, Context>: ExtensionPointInfo {
    public let name: String
    public let purpose: String
    public let signature: String
    public var kind: ExtensionKind { .pipeline }
    @usableFromInline var list = ContributionList<(Value, Context) -> Value>()
    private let registry: ExtensionRegistry

    public init(_ name: String, _ purpose: String = "", signature: String = "", registry: ExtensionRegistry = .shared) {
        self.name = name
        self.purpose = purpose
        self.signature = signature
        self.registry = registry
    }

    public var contributions: [ExtensionContribution] { list.entries }

    public func add(_ id: String, order: ExtensionOrder = .normal, _ transform: @escaping (Value, Context) -> Value) {
        if let error = list.insert(id, order: order, feature: registry.currentFeature, body: transform, point: name) {
            registry.report(error)
        }
    }

    @inlinable
    public func apply(_ value: Value, _ context: Context) -> Value {
        var result = value
        for transform in list.bodies { result = transform(result, context) }
        return result
    }

    @inlinable
    public var isEmpty: Bool { list.bodies.isEmpty }

    public func remove(_ id: String) { list.remove(id) }
}

extension Pipeline where Context == Void {
    public func add(_ id: String, order: ExtensionOrder = .normal, _ transform: @escaping (Value) -> Value) {
        add(id, order: order) { value, _ in transform(value) }
    }

    @inlinable
    public func apply(_ value: Value) -> Value { apply(value, ()) }
}

// MARK: - Provided

/// One provider with a default; a second `provide` is an error and the first stays.
public final class Provided<Value>: ExtensionPointInfo {
    public let name: String
    public let purpose: String
    public let signature: String
    public var kind: ExtensionKind { .provided }
    @usableFromInline var current: Value
    private var provider: ExtensionContribution?
    private let registry: ExtensionRegistry

    public init(_ name: String, _ purpose: String = "", signature: String = "", default value: Value,
                registry: ExtensionRegistry = .shared) {
        self.name = name
        self.purpose = purpose
        self.signature = signature
        self.current = value
        self.registry = registry
    }

    public var contributions: [ExtensionContribution] { provider.map { [$0] } ?? [] }

    /// nil while the default is in use.
    public var providerID: String? { provider?.id }

    public func provide(_ id: String, _ value: Value) {
        let feature = registry.currentFeature
        if let existing = provider {
            let who = existing.id + (existing.feature.map { " (feature \"\($0)\")" } ?? "")
            registry.report(ExtensionError(point: name, problem: .secondProvider, existing: who,
                                           rejected: id + (feature.map { " (feature \"\($0)\")" } ?? "")))
            return
        }
        provider = ExtensionContribution(id: id, order: .normal, feature: feature, sequence: 0)
        current = value
    }

    @inlinable
    public var value: Value { current }

    /// For tests.
    public func reset(to value: Value) {
        provider = nil
        current = value
    }
}
