import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// Every place either lets an action run or says why it can't, before anything fails (FE-231).
/// "Runs" means `isAvailable && isEnabled` for a context with no window; commands are never performed.
@Suite("Provider capability matrix (FE-231)", .serialized)
@MainActor
struct ProviderCapabilityMatrixTests {
    private static let folder = URL(fileURLWithPath: "/Users/me/Documents")
    private static let item = FileItem(url: folder.appendingPathComponent("a.txt"), name: "a.txt", isFolder: false)

    /// Core pages a feature replaces for the same locations; every other provider must be reached by the matrix.
    private static let shadowed: Set<String> = ["HomeProvider", "ThisMacProvider", "ThisMacPageProvider", "PlaceholderProvider"]

    /// The fake network's share, connected and dropped as the tests need it.
    private static let shareAddress = NetworkAddress(host: "NAS-01", share: "Public")
    private static var shareRoot: URL? { (NetworkCenter.shared.services as? FakeNetworkServices)?.root.appendingPathComponent("NAS-01/Public") }

    /// A real location per provider type: a new provider fails the matrix until it is added here.
    private static var samples: [String: [Location]] {
        var samples: [String: [Location]] = [
            "FolderProvider": [.folder(folder)],
            "ArchiveProvider": [.archive(URL(fileURLWithPath: "/Users/me/a.zip"), innerPath: "")],
            "TrashProvider": [.trash],
            "SearchProvider": [.search(SearchRequest(query: "x", scope: folder))],
            "GalleryProvider": [.gallery],
            "LibraryProvider": [.library(LibraryLogic.rootName), .library("Documents")],
            "ExplorerHomeProvider": [.home], "HomeProvider": [.home],
            "ThisMacPageProvider": [.thisMac], "ThisMacProvider": [.thisMac], "ThisMacReloadOnNetworkChange": [.thisMac],
            "NetworkPageProvider": [.network],
            "ServerProvider": [.server(NetworkAddress(host: "server"))],
            "PlaceholderProvider": [.gallery, .network, .trash, .search(SearchRequest(query: "x", scope: folder))],
        ]
        if let root = CloudEnvironment.roots.first { samples["CloudRootProvider"] = [.folder(root.url)] }
        if let share = shareRoot { samples["NetworkFolderProvider"] = [.folder(share)] }
        return samples
    }

    /// New and Paste in a library with no save location stay enabled and explain when used (FE-238).
    private static let explainsWhenPerformed: Set<String> = ["file.newFolder", "edit.paste", "edit.pasteMove"]

    private static func typeName(_ provider: LocationProvider) -> String { String(describing: type(of: provider)) }

    /// Registers once, and only then touches the clipboard: its pasteboard is chosen from ARBOR_HEADLESS at first use.
    private func prepare() async throws {
        #expect(FeatureRegistrationTests.problem == nil)
        try #require(Automation.environment["ARBOR_HEADLESS"] != nil)
        try #require(!CloudEnvironment.roots.isEmpty, "the matrix must reach the cloud root provider")
        try await connectShare()
        FileClipboard.shared.write([Self.item.url], kind: .copy)
    }

    private func connectShare() async throws {
        let center = NetworkCenter.shared
        let share = try #require(Self.shareRoot)
        if center.share(containing: share) == nil {
            let result = await withCheckedContinuation { done in
                center.services.mount(Self.shareAddress, options: MountOptions()) { done.resume(returning: $0) }
            }
            center.invalidateMounts()
            _ = try result.get()
        }
        try #require(center.share(containing: share) != nil)
    }

    private func dropShare() throws {
        let center = NetworkCenter.shared
        let fake = try #require(center.services as? FakeNetworkServices)
        fake.dropConnection(try #require(Self.shareRoot))
        center.invalidateMounts()
    }

    private func context(_ location: Location, for commandID: String) -> CommandContext {
        // "New" as a menu entry exists only in the background menu.
        let surface: CommandSurface = commandID == "menu.new" ? .backgroundContextMenu : .commandBar
        return CommandContext(window: nil, location: location, selection: [Self.item],
                              targetFolder: LocationRegistry.provider(for: location).targetFolder(for: location), surface: surface)
    }

    private func runs(_ commandID: String, at location: Location) throws -> Bool {
        let command = try #require(CommandRegistry.shared.command(commandID), "\(commandID) isn't registered")
        let context = context(location, for: commandID)
        return command.isAvailable(context) && command.isEnabled(context)
    }

    /// Commands run at `location` exactly where its provider gives no reason.
    private func expectCommandsMatchReasons(at location: Location) throws {
        let provider = LocationRegistry.provider(for: location)
        let name = Self.typeName(provider)
        let isLibraryPage: Bool = { if case .library(let l) = location { return l != LibraryLogic.rootName }; return false }()
        for action in LocationAction.allCases {
            let reason = provider.limitation(of: action, in: location)
            for id in action.commandIDs {
                if reason != nil, isLibraryPage, Self.explainsWhenPerformed.contains(id) { continue }
                let running = try runs(id, at: location)
                #expect(running == (reason == nil), "\(name), \(location.key), \(id): runs \(running), reason \(reason ?? "none")")
            }
        }
    }

    @Test func everyActionHasACommand() throws {
        #expect(FeatureRegistrationTests.problem == nil)
        for action in LocationAction.allCases {
            #expect(!action.commandIDs.isEmpty)
            for id in action.commandIDs { #expect(CommandRegistry.shared.command(id) != nil, "\(id)") }
        }
    }

    @Test func anActionRunsExactlyWhereThereIsNoReasonItCant() async throws {
        try await prepare()
        var reached: Set<String> = []
        for (name, locations) in Self.samples {
            for location in locations {
                let found = Self.typeName(LocationRegistry.provider(for: location))
                guard found == name else {
                    if !Self.shadowed.contains(name) { Issue.record("\(name)'s sample \(location.key) goes to \(found)") }
                    continue
                }
                reached.insert(name)
                try expectCommandsMatchReasons(at: location)
            }
        }
        let expected = Set(LocationRegistry.allProviders.map(Self.typeName)).subtracting(Self.shadowed)
        #expect(reached == expected, "not reached: \(expected.subtracting(reached).sorted()); add a sample or name it in `shadowed`")
    }

    @Test func aShareRunsWhileConnectedAndExplainsOnceDisconnected() async throws {
        try await prepare()
        let share = Location.folder(try #require(Self.shareRoot))
        #expect(Self.typeName(LocationRegistry.provider(for: share)) == "NetworkFolderProvider")
        #expect(LocationRegistry.provider(for: share).limitation(of: .rename, in: share) == nil)
        try expectCommandsMatchReasons(at: share)

        try dropShare()
        #expect(Self.typeName(LocationRegistry.provider(for: share)) == "NetworkFolderProvider", "a dropped share keeps its provider")
        #expect(LocationRegistry.provider(for: share).limitation(of: .rename, in: share) == L10n.tr("This network share is disconnected. Reconnect it first."))
        #expect(LocationRegistry.provider(for: share).limitation(of: .copy, in: share) == nil)
        try expectCommandsMatchReasons(at: share)
    }

    @Test func aMissingSaveLocationIsExplainedWhenUsed() async throws {
        try await prepare()
        let library = Location.library("Documents")
        #expect(LocationRegistry.provider(for: library).limitation(of: .newItem, in: library) != nil)
        for id in Self.explainsWhenPerformed { #expect(try runs(id, at: library), "\(id) stays enabled so it can explain") }
    }

    @Test func everyReasonIsNonEmptyAndInTheStringTable() async throws {
        try await prepare()
        let table = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/en.lproj/Localizable.strings")
        let keys = try #require(NSDictionary(contentsOf: table) as? [String: String]).keys
        let samples = Self.samples
        for provider in LocationRegistry.allProviders {
            for location in samples[Self.typeName(provider)] ?? [] {
                for action in LocationAction.allCases {
                    guard let reason = provider.limitation(of: action, in: location) else { continue }
                    #expect(!reason.isEmpty)
                    #expect(keys.contains(reason), "“\(reason)” is missing from Localizable.strings")
                }
            }
        }
    }

    @Test func aCommandWithAReasonStaysListedGreyedInTheCommandBar() async throws {
        try await prepare()
        let onTheBar = LocationAction.allCases.flatMap { action in
            action.commandIDs.compactMap { CommandRegistry.shared.command($0) }
                .filter { command in command.placements.contains { $0.slot == .commandBar } }.map { (action, $0) }
        }
        #expect(!onTheBar.isEmpty)
        for location in Self.samples.values.flatMap({ $0 }) {
            let provider = LocationRegistry.provider(for: location)
            for (action, command) in onTheBar where provider.limitation(of: action, in: location) != nil {
                #expect(command.isAvailable(context(location, for: command.id)), "\(command.id) vanished at \(location.key)")
            }
        }
    }

    @Test func aMenuItemCarriesTheReasonUntilItCanRun() async throws {
        try await prepare()
        let rename = try #require(CommandRegistry.shared.command("file.rename"))
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let archive = Location.archive(URL(fileURLWithPath: "/Users/me/a.zip"), innerPath: "")
        #expect(!CommandDispatcher.shared.validate(rename, item: item, context: context(archive, for: rename.id)))
        #expect(item.toolTip == LocationRegistry.provider(for: archive).limitation(of: .rename, in: archive))
        #expect(CommandDispatcher.shared.validate(rename, item: item, context: context(.folder(Self.folder), for: rename.id)))
        #expect(item.toolTip == nil)
    }

    @Test func aCommandBarButtonShowsTheReasonThenItsOwnTooltipAgain() async throws {
        try await prepare()
        let bar = CommandBarView()
        let archive = Location.archive(URL(fileURLWithPath: "/Users/me/a.zip"), innerPath: "")
        let provider = LocationRegistry.provider(for: archive)
        let rename = try #require(CommandRegistry.shared.command("file.rename"))

        bar.update(context(archive, for: rename.id))
        var tips = bar.debugTooltips
        #expect(tips.contains("file.rename=\(provider.limitation(of: .rename, in: archive) ?? "?")"), "\(tips)")
        #expect(tips.contains("menu.new=\(provider.limitation(of: .newItem, in: archive) ?? "?")"), "\(tips)")

        bar.update(context(.folder(Self.folder), for: rename.id))
        tips = bar.debugTooltips
        #expect(tips.contains("file.rename=\(rename.tooltipText)"), "\(tips)")
        #expect(tips.contains("menu.new=\(CommandBarView.newTooltip)"), "\(tips)")
    }
}
