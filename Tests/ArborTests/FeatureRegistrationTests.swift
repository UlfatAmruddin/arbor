import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// Registering every feature as at launch gives no extension errors and satisfies each `requires` (DEC-024).
@Suite("Feature registration (DEC-024)", .serialized)
@MainActor
struct FeatureRegistrationTests {
    /// Registers once per test process (registration isn't repeatable: ids would be duplicates).
    static let problem: String? = {
        setenv("ARBOR_HEADLESS", "1", 1)   // a throwaway preferences domain; nothing opens
        _ = NSApplication.shared   // features observe the app; no window is created
        ExtensionRegistry.shared.assertsOnError = false   // collect every error, report them below
        return Features.registerFeatures()
    }()

    @Test func everyFeatureRegistersWithoutExtensionErrors() {
        #expect(Self.problem == nil, "\(Self.problem ?? "")")
        #expect(ExtensionRegistry.shared.errors.isEmpty)
    }

    @Test func theOrderSatisfiesEveryRequirement() throws {
        _ = Self.problem
        let order = try Features.order().map { $0.id }
        #expect(FeatureGraph.satisfies(order, Features.graph))
        #expect(Features.registeredOrder == order)
        #expect(order.first == "core")
        #expect(Set(order).count == Features.all.count)
    }

    @Test func requirementsNameListedFeatures() {
        let ids = Set(Features.all.map { $0.id })
        for feature in Features.all {
            for required in feature.requires {
                #expect(ids.contains(required), "\(feature.id) requires unknown feature \(required)")
            }
        }
    }

    @Test func contributionIDsStartWithTheirFeature() {
        _ = Self.problem
        let ids = Set(Features.all.map { $0.id })
        let points = ExtensionCatalog.points + CommandRegistry.shared.extensionPoints
        for point in points {
            for contribution in point.contributions {
                guard let feature = contribution.feature, ids.contains(feature) else { continue }
                #expect(contribution.id.hasPrefix(feature + "."), "\(point.name): \(contribution.id) (feature \(feature))")
            }
        }
    }

    @Test func theListingNamesEveryPointOnce() {
        _ = Self.problem
        let names = ExtensionCatalog.points.map(\.name)
        #expect(Set(names).count == names.count)
        let listing = ExtensionCatalog.listing()
        #expect(listing.contains("errors: none"))
        #expect(listing.contains("Handlers InteractionHooks.openFile: archives.open-file [early, archives], item-actions.shortcuts"))
    }
}

/// Every declared extension point is in `ExtensionCatalog` (feeds docs/EXTENSION-POINTS.md), named by its Swift path.
@Suite("Extension catalog (DEC-024)")
struct ExtensionCatalogTests {
    @Test func everyDeclaredPointIsCatalogued() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let declaration = try NSRegularExpression(
            pattern: #"static let (\w+) = (?:Handlers|Observers|Pipeline|Provided)<[^\n]*\(\s*"([\w.]+)""#)
        var declared: [String] = []
        for folder in ["Sources/Arbor", "Sources/ArborCore"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for match in declaration.matches(in: text, range: range) {
                    let property = String(text[Range(match.range(at: 1), in: text)!])
                    let name = String(text[Range(match.range(at: 2), in: text)!])
                    #expect(name.hasSuffix("." + property), "\(url.lastPathComponent): \(name) should end in .\(property)")
                    declared.append(name)
                }
            }
        }
        #expect(declared.count > 50)
        let catalog = try String(contentsOf: root.appendingPathComponent("Sources/Arbor/Support/ExtensionCatalog.swift"), encoding: .utf8)
        for name in declared {
            #expect(catalog.contains(name + ",") || catalog.contains(name + "\n"), "\(name) is missing from ExtensionCatalog.points")
        }
    }
}
