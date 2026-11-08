import Foundation
import Testing
@testable import ArborCore

@Suite("Extension points (DEC-024)")
struct ExtensionPointTests {
    @Test func ordersAreComparableAndNamed() {
        #expect(ExtensionOrder.first < .early)
        #expect(ExtensionOrder.early < .normal)
        #expect(ExtensionOrder.normal < .late)
        #expect(ExtensionOrder.late < .last)
        #expect(ExtensionOrder.custom(-500) > .early && ExtensionOrder.custom(-500) < .normal)
        #expect(ExtensionOrder.early.description == "early")
        #expect(ExtensionOrder.custom(7).description == "custom(7)")
    }

    @Test func handlersReturnTheFirstAnswerInRunOrder() {
        let registry = ExtensionRegistry()
        let point = Handlers<Int, String>("Test.handlers", registry: registry)
        #expect(point.first(1) == nil)
        #expect(point.isEmpty)
        point.register("b.normal") { $0 > 0 ? "normal" : nil }
        point.register("a.late", order: .late) { _ in "late" }
        point.register("c.early", order: .early) { $0 == 2 ? "early" : nil }
        #expect(point.first(2) == "early")
        #expect(point.first(1) == "normal")
        #expect(point.first(-1) == "late")
        #expect(point.contributionIDs == ["c.early", "b.normal", "a.late"])
        #expect(registry.errors.isEmpty)
    }

    @Test func equalOrdersKeepRegistrationOrder() {
        let registry = ExtensionRegistry()
        let point = Handlers<Int, String>("Test.stable", registry: registry)
        for name in ["one", "two", "three"] { point.register(name) { _ in name } }
        point.register("zero", order: .first) { _ in nil }
        #expect(point.contributionIDs == ["zero", "one", "two", "three"])
        #expect(point.first(0) == "one")
    }

    @Test func handlersCanAskWhatTheyReplaced() {
        let registry = ExtensionRegistry()
        let point = Handlers<Int, String>("Test.after", registry: registry)
        point.register("outer", order: .early) { "outer+" + (point.first($0, after: "outer") ?? "none") }
        point.register("inner") { $0 > 0 ? "inner" : nil }
        #expect(point.first(1) == "outer+inner")
        #expect(point.first(0) == "outer+none")
        #expect(point.first(1, after: "inner") == nil)
        #expect(point.first(1, after: "unknown") == "outer+inner")
    }

    @Test func voidHandlersReportWhetherTheInputWasHandled() {
        let registry = ExtensionRegistry()
        let point = Handlers<String, Void>("Test.void", registry: registry)
        var calls: [String] = []
        point.register("zip", handles: { calls.append("zip"); return $0.hasSuffix(".zip") })
        point.register("any", order: .late, handles: { calls.append("any"); return $0 == "x" })
        #expect(point.handle("a.zip"))
        #expect(calls == ["zip"])
        #expect(point.handle("x"))
        #expect(!point.handle("y"))
        #expect(calls == ["zip", "zip", "any", "zip", "any"])
    }

    @Test func tupleInputsDestructureInClosures() {
        let registry = ExtensionRegistry()
        let point = Handlers<(Int, String), String>("Test.tuple", registry: registry)
        point.register("join") { number, text in "\(text)\(number)" }
        #expect(point.first((3, "n")) == "n3")
    }

    @Test func observersAllRunInOrder() {
        let registry = ExtensionRegistry()
        let point = Observers<Int>("Test.observers", registry: registry)
        var log: [String] = []
        point.observe("late", order: .late) { log.append("late\($0)") }
        point.observe("normal") { log.append("normal\($0)") }
        point.observe("first", order: .first) { log.append("first\($0)") }
        point.send(1)
        #expect(log == ["first1", "normal1", "late1"])
        point.remove("normal")
        point.send(2)
        #expect(log.suffix(2) == ["first2", "late2"])
    }

    @Test func pipelinesPassEachOutputToTheNext() {
        let registry = ExtensionRegistry()
        let point = Pipeline<[Int], Int>("Test.pipeline", registry: registry)
        #expect(point.apply([1, 2, 3], 0) == [1, 2, 3])
        point.add("double", order: .late) { values, _ in values.map { $0 * 2 } }
        point.add("drop") { values, limit in values.filter { $0 > limit } }
        #expect(point.apply([1, 2, 3], 1) == [4, 6])   // drop first, then double
        let plain = Pipeline<String, Void>("Test.plain", registry: registry)
        plain.add("a") { $0 + "a" }
        plain.add("b") { $0 + "b" }
        #expect(plain.apply("") == "ab")
    }

    @Test func providedHasOneProviderAndADefault() {
        let registry = ExtensionRegistry()
        let point = Provided<() -> String>("Test.provided", default: { "default" }, registry: registry)
        #expect(point.value() == "default")
        #expect(point.providerID == nil)
        #expect(point.contributions.isEmpty)
        point.provide("folder-options.start") { "provided" }
        #expect(point.value() == "provided")
        point.provide("other.start") { "second" }
        #expect(point.value() == "provided")   // the first provider stays
        #expect(registry.errors.count == 1)
        let error = registry.errors[0]
        #expect(error.problem == .secondProvider)
        #expect(error.point == "Test.provided")
        #expect(error.description.contains("folder-options.start") && error.description.contains("other.start"))
        point.reset(to: { "again" })
        #expect(point.value() == "again" && point.providerID == nil)
    }

    @Test func duplicateIDsAreRecordedWithBothContributions() {
        let registry = ExtensionRegistry()
        registry.currentFeature = "archives"
        let point = Handlers<Int, Int>("InteractionHooks.openFile", registry: registry)
        point.register("archives.open-file") { $0 }
        registry.currentFeature = "item-actions"
        point.register("archives.open-file") { $0 + 1 }
        #expect(point.contributionIDs == ["archives.open-file"])
        #expect(point.first(1) == 1)   // the duplicate isn't added
        #expect(registry.errors.count == 1)
        let text = registry.errors[0].description
        #expect(text.contains("InteractionHooks.openFile"))
        #expect(text.contains("archives") && text.contains("item-actions"))
        #expect(registry.failureMessage?.contains("1 extension registration error") == true)
        registry.removeAllErrors()
        #expect(registry.failureMessage == nil)

        let observers = Observers<Int>("Test.dupObservers", registry: registry)
        observers.observe("x") { _ in }
        observers.observe("x") { _ in }
        let pipeline = Pipeline<Int, Void>("Test.dupPipeline", registry: registry)
        pipeline.add("y") { $0 }
        pipeline.add("y") { $0 }
        #expect(registry.errors.map(\.point) == ["Test.dupObservers", "Test.dupPipeline"])
    }

    @Test func contributionsRememberTheirFeature() {
        let registry = ExtensionRegistry()
        let point = Observers<Void>("Test.features", registry: registry)
        registry.currentFeature = "search"
        point.observe("search.refresh", order: .early) {}
        registry.currentFeature = nil
        point.observe("loose") {}
        #expect(point.contributions.map(\.feature) == ["search", nil])
        #expect(point.listing == "Observers Test.features: search.refresh [early, search], loose [normal]")
        #expect(Handlers<Int, Int>("Test.empty", registry: registry).listing == "Handlers Test.empty: (none)")
    }

    @Test func otherProblemsCanBeReported() {
        let registry = ExtensionRegistry()
        registry.report(point: "commands[file.nothing]", "no command has this id.", contribution: "gallery.x")
        #expect(registry.errors.first?.description == "Extension point commands[file.nothing]: no command has this id. (refused: gallery.x)")
    }
}

@Suite("Feature registration order (DEC-024)")
struct FeatureGraphTests {
    typealias Node = FeatureGraph.Node

    @Test func keepsListedOrderWhenRequirementsAllow() throws {
        let nodes = [Node("core"), Node("search"), Node("archives"), Node("consistency", requires: ["search", "archives"])]
        #expect(try FeatureGraph.order(nodes) == ["core", "search", "archives", "consistency"])
    }

    @Test func movesAFeatureAfterWhatItRequires() throws {
        let nodes = [Node("core"), Node("extras", requires: ["archives", "properties"]), Node("archives"),
                     Node("trash", requires: ["file-operations"]), Node("properties"), Node("file-operations")]
        let order = try FeatureGraph.order(nodes)
        #expect(order == ["core", "archives", "properties", "extras", "file-operations", "trash"])
        #expect(FeatureGraph.satisfies(order, nodes))
        #expect(!FeatureGraph.satisfies(nodes.map(\.id), nodes))
    }

    @Test func isStableForIndependentFeatures() throws {
        let ids = (0..<30).map { "f\($0)" }
        #expect(try FeatureGraph.order(ids.map { Node($0) }) == ids)
        #expect(try FeatureGraph.order([]) == [])
    }

    @Test func reportsDuplicateIDs() {
        #expect(throws: FeatureGraph.Problem.duplicateID("search")) {
            try FeatureGraph.order([Node("search"), Node("core"), Node("search")])
        }
    }

    @Test func reportsMissingDependencies() {
        let problem = FeatureGraph.Problem.missingDependency(feature: "trash", missing: "file-operations")
        #expect(throws: problem) { try FeatureGraph.order([Node("core"), Node("trash", requires: ["file-operations"])]) }
        #expect(problem.description.contains("\"trash\" requires \"file-operations\""))
    }

    @Test func reportsCyclesWithThePath() {
        let nodes = [Node("core"), Node("a", requires: ["b"]), Node("b", requires: ["c"]), Node("c", requires: ["b"])]
        #expect(throws: FeatureGraph.Problem.cycle(["b", "c", "b"])) { try FeatureGraph.order(nodes) }
        #expect(throws: FeatureGraph.Problem.cycle(["x", "x"])) { try FeatureGraph.order([Node("x", requires: ["x"])]) }
        #expect(FeatureGraph.Problem.cycle(["b", "c", "b"]).description.contains("b → c → b"))
    }
}

@Suite("Extension errors name who caused them")
struct ExtensionErrorWordingTests {
    @Test func otherProblemsNameBothContributions() {
        let registry = ExtensionRegistry()
        registry.report(point: "ViewModeRegistry", "view mode largeIcons is registered twice.",
                        contribution: "new-view", existing: "icon-views")
        let text = registry.errors[0].description
        #expect(text.contains("ViewModeRegistry"))
        #expect(text.contains("refused: new-view"))
        #expect(text.contains("already there: icon-views"))
    }

    @Test func otherProblemsWithoutContributionsStayPlain() {
        let error = ExtensionError(point: "p", problem: .other("broken."), existing: "", rejected: "")
        #expect(error.description == "Extension point p: broken.")
    }
}
