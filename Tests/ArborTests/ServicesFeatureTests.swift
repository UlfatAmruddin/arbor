import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// The Info.plist declaration and the code that answers it can't drift (FE-218), and Arbor stays an ordinary app beside Finder.
@Suite("Services declaration (FE-218)")
struct ServicesDeclarationTests {
    private static func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    private static func service() throws -> [String: Any] {
        let services = try #require(try infoPlist()["NSServices"] as? [[String: Any]])
        #expect(services.count == 1)
        return try #require(services.first)
    }

    @Test func theServiceTakesAnyFileAndReturnsNothing() throws {
        let service = try Self.service()
        #expect(service["NSSendFileTypes"] as? [String] == ["public.item"])
        #expect(service["NSSendTypes"] == nil)
        #expect(service["NSReturnTypes"] == nil)
    }

    @Test func thePortAndForbiddenContextNameThisApp() throws {
        let info = try Self.infoPlist()
        let service = try Self.service()
        #expect(service["NSPortName"] as? String == info["CFBundleExecutable"] as? String)
        let forbidden = try #require(service["NSForbiddenContext"] as? [String: Any])
        #expect(forbidden["NSApplicationIdentifier"] as? String == info["CFBundleIdentifier"] as? String)
    }

    @Test func theRequiredContextHasNoTextFilter() throws {
        let required = try #require(try Self.service()["NSRequiredContext"] as? [String: Any])
        #expect(required.isEmpty)
    }

    @Test func theProviderAnswersTheDeclaredMessage() throws {
        let message = try #require(try Self.service()["NSMessage"] as? String)
        #expect(ServicesProvider.shared.responds(to: NSSelectorFromString(message + ":userData:error:")))
    }

    @Test func arborNeverClaimsToBeTheFolderHandler() throws {
        let types = try #require(try Self.infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
        let folder = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.folder") == true })
        #expect(folder["LSHandlerRank"] as? String == "None")
    }
}

/// Aliases from outside behave as a double-click does: a folder alias opens its target, a file alias is revealed.
@Suite("Aliases opened from outside (FE-218)")
struct ExternalOpenAliasTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("arbor-tests-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func plan(for url: URL) -> ExternalOpen.Plan {
        let found = ExternalOpen.items(for: [url])
        return ExternalOpen.plan(found.items, skipped: found.skipped, ownLocation: Shortcuts.locationForOpening)
    }

    @Test func aFolderAliasOpensItsTarget() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = try Shortcuts.createAlias(to: target, in: root, name: "alias")
        #expect(plan(for: alias).targets.map(\.location) == [.folder(target)])
    }

    @Test func aFileAliasIsRevealed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        try Data("x".utf8).write(to: target)
        let alias = try Shortcuts.createAlias(to: target, in: root, name: "alias")
        let result = plan(for: alias)
        #expect(result.targets.map(\.location) == [.folder(root)])
        #expect(result.targets.first?.select == ["alias"])
    }
}
