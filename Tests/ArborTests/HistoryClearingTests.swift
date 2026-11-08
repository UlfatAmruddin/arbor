import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// Clear Arbor history reaches every feature, and version copies don't outlive their viewer (registration suite).
extension FeatureRegistrationTests {
    /// Owns the test window (NSApp.delegate is weak).
    private static let app = AppDelegate()

    @Test func bothClearHistoryEntryPointsEmptyEveryFeaturesHistory() throws {
        #expect(Self.problem == nil)
        NSApp.delegate = Self.app
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("arbor-tests-history-\(UUID().uuidString)")
        let places = ["a", "b", "c"].map { dir.appendingPathComponent($0) }
        for place in places { try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = Self.app.openWindow(at: .folder(places[1]))
        defer { window.close() }

        let entryPoints: [(String, () -> Void)] = [
            ("Folder Options", { FolderOptionsHistory.clear() }),
            ("Home", { HomeStore.clearHistory() }),
        ]
        for (name, clear) in entryPoints {
            seed(window, places)
            #expect(!SearchHistoryStore.history.entries.isEmpty, "\(name)")
            #expect(!OperationHistory.shared.records.isEmpty, "\(name)")
            #expect(!Self.recentLocations.isEmpty, "\(name)")
            #expect(window.tabs[0].history.canGoBack && window.tabs[0].history.canGoForward, "\(name)")
            #expect(!NSDocumentController.shared.recentDocumentURLs.isEmpty, "\(name)")

            clear()
            OperationHistory.shared.flush()
            #expect(SearchHistoryStore.history.entries.isEmpty, "\(name)")
            #expect(OperationHistory.shared.records.isEmpty, "\(name)")
            #expect(!FileManager.default.fileExists(atPath: OperationHistory.fileURL.path), "\(name)")
            #expect(Self.recentLocations.isEmpty, "\(name)")
            #expect(NSDocumentController.shared.recentDocumentURLs.isEmpty, "\(name)")
            let history = window.tabs[0].history
            #expect(!history.canGoBack && !history.canGoForward, "\(name)")
            #expect(history.current.location == .folder(places[1]), "\(name)")
            let saved = SessionRestore.snapshot().windows.flatMap(\.tabs)
            #expect(!saved.isEmpty && saved.allSatisfy { $0.back.isEmpty && $0.forward.isEmpty }, "\(name)")
        }
    }

    @Test func homesClearHistoryTooltipNamesEveryClearedList() throws {
        #expect(Self.problem == nil)
        let tooltip = try #require(CommandRegistry.shared.command("home.clearHistory")?.tooltip)
        for list in ["Recent", "frequently used folders", "recent searches", "recent locations", "recent documents",
                     "operation history", "Back/Forward"] {
            #expect(tooltip.contains(list), "\(list)")
        }
    }

    @Test func aVersionCopyNoAppShowsIsRemoved() async throws {
        #expect(Self.problem == nil)   // headless: nothing is opened, as when opening fails
        let folder = try Self.makeVersionCopy()
        VersionCopies.open(folder.appendingPathComponent("Report (version).txt"), in: folder)
        #expect(await Self.disappears(folder))
    }

    @Test func aVersionCopyIsRemovedWhenTheAppShowingItQuits() async throws {
        let folder = try Self.makeVersionCopy()
        defer { TemporaryFiles.removeTree(folder.deletingLastPathComponent()) }
        VersionCopies.opened(folder, in: .current)
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: NSWorkspace.shared,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(await Self.disappears(folder))
    }

    private func seed(_ window: BrowserWindowController, _ places: [URL]) {
        SearchHistoryStore.update { $0.record("quarterly report") }
        OperationHistory.shared.add(OperationRecord(kind: .copy, sources: [places[0].path], destination: places[2].path,
                                                    started: Date(), finished: Date(), items: []))
        NotificationCenter.default.post(name: LocationEvents.didVisit, object: nil, userInfo: ["location": Location.folder(places[0])])
        var history = NavigationHistory(start: places[0])
        history.visit(places[1])
        history.visit(places[2])
        history.goBack()
        window.tabs[0].history = history
        NSDocumentController.shared.noteNewRecentDocumentURL(places[0])
    }

    /// The address bar's ▾ list.
    private static var recentLocations: [Location] { AddressBar.recentLocations.value?() ?? [] }

    /// A read-only copy in its own folder, as Previous Versions' Open makes it.
    private static func makeVersionCopy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-tests-versions-\(UUID().uuidString)").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Report (version).txt")
        try Data("v1".utf8).write(to: file)
        try TemporaryFiles.makeVersionCopyReadOnly(file)
        return folder
    }

    /// Removal happens off the main thread.
    private static func disappears(_ url: URL) async -> Bool {
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
