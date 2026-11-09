import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// The window side of saved workspaces (registration suite): swapping tabs, the deadline, and Clear history.
extension FeatureRegistrationTests {
    /// Owns the test windows (NSApp.delegate is weak).
    private static let workspacesApp = AppDelegate()

    private func withFolders(_ names: [String], _ body: ([URL]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("arbor-tests-workspaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let places = names.map { root.appendingPathComponent($0) }
        for place in places { try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true) }
        try await body(places)
    }

    private func openWindow(_ place: URL) -> BrowserWindowController {
        NSApp.delegate = Self.workspacesApp
        return Self.workspacesApp.openWindow(at: .folder(place))
    }

    private func plan(for places: [URL], active: Int = 0, isAvailable: (WorkspaceOpenPlan.Requirement) -> Bool = { _ in true }) throws -> WorkspaceOpenPlan {
        let tabs = places.map { SessionTab(location: Location.folder($0).key) }
        return WorkspaceOpenPlan(workspace: try #require(Workspace(name: "Test", tabs: tabs, activeTab: active)), isAvailable: isAvailable)
    }

    @Test func workspaceCommandsAreRegistered() {
        #expect(Self.problem == nil)
        #expect(CommandRegistry.shared.command("workspaces.menu")?.hasSubmenu == true)
        #expect(CommandRegistry.shared.command("workspaces.save") != nil)
    }

    @Test func replaceTabsSwapsEveryTabAndClampsTheActiveOne() async throws {
        #expect(Self.problem == nil)
        try await withFolders(["a", "b", "c"]) { places in
            let window = openWindow(places[0])
            defer { window.close() }
            let replaced = window.activeTab
            let inFlight = LoadHandle()
            replaced.pendingLoad = inFlight

            window.replaceTabs(with: [TabState(location: .folder(places[1])), TabState(location: .folder(places[2]))], activeIndex: 9)
            #expect(window.tabs.map(\.location) == [.folder(places[1]), .folder(places[2])])
            #expect(window.activeIndex == 1)
            #expect(inFlight.isCancelled)
            #expect(!window.tabs.contains { $0 === replaced })
            #expect(window.activeTab.isActive)
        }
    }

    @Test func replaceTabsIgnoresAnEmptyList() async throws {
        #expect(Self.problem == nil)
        try await withFolders(["a"]) { places in
            let window = openWindow(places[0])
            defer { window.close() }
            let before = window.activeTab
            window.replaceTabs(with: [], activeIndex: 0)
            #expect(window.tabs.count == 1)
            #expect(window.activeTab === before)
            #expect(window.activeTab.isActive)
        }
    }

    @Test func aSavedTabRestoresItsHistoryAndView() throws {
        let entry = SessionTab(location: "folder:/m/a", back: ["folder:/m/b"], forward: ["home"], viewMode: "list", sortKey: "size", ascending: false, foldersFirst: false)
        let tab = try #require(TabState(session: entry))
        #expect(tab.location == Location(key: "folder:/m/a"))
        #expect(tab.history.canGoBack && tab.history.canGoForward)
        #expect(tab.viewMode == .list)
        #expect(tab.sortOrder == entry.sortOrder)
        #expect(tab.sessionTab == entry)
    }

    @Test func aSavedTabToleratesOddValues() throws {
        #expect(TabState(session: SessionTab(location: "hologram")) == nil)
        let odd = try #require(TabState(session: SessionTab(location: "home", viewMode: "hologram", sortKey: "weight")))
        #expect(odd.viewMode == .details)
    }

    @Test func aSheetThatAppearedDuringTheCheckBlocksReplace() async throws {
        #expect(Self.problem == nil)
        try await withFolders(["a", "b"]) { places in
            let window = openWindow(places[0])
            defer { window.close() }
            let host = try #require(window.window)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: true)
            host.beginSheet(sheet)
            defer { host.endSheet(sheet) }
            #expect(host.attachedSheet != nil)

            WorkspaceOpener.apply(try plan(for: [places[1]]), name: "Test", replacing: window)
            #expect(window.tabs.map(\.location) == [.folder(places[0])])
        }
    }

    @Test func aPlanWithNothingAvailableChangesNoWindow() async throws {
        #expect(Self.problem == nil)
        try await withFolders(["a", "b"]) { places in
            let window = openWindow(places[0])
            defer { window.close() }
            let windows = Self.workspacesApp.controllers.count
            let empty = try plan(for: [places[1]]) { _ in false }
            WorkspaceOpener.apply(empty, name: "Test", replacing: window)
            WorkspaceOpener.apply(empty, name: "Test", replacing: nil)
            #expect(window.tabs.map(\.location) == [.folder(places[0])])
            #expect(Self.workspacesApp.controllers.count == windows)
        }
    }

    @Test func aSkippedTabKeepsTheOthersAndTheActivePosition() async throws {
        #expect(Self.problem == nil)
        try await withFolders(["a", "b", "c"]) { places in
            let window = openWindow(places[0])
            defer { window.close() }
            let partial = try plan(for: places, active: 1) { $0 != .directory(places[1].path) }
            WorkspaceOpener.apply(partial, name: "Test", replacing: window)
            #expect(window.tabs.map(\.location) == [.folder(places[0]), .folder(places[2])])
            #expect(window.activeIndex == 1)
        }
    }

    @Test func aHungCheckChangesNoTabs() async throws {
        #expect(Self.problem == nil)
        WorkspacesFeature.store.loadIfNeeded()
        let saved = try WorkspacesFeature.store.save(name: "Hung", tabs: [SessionTab(location: "folder:/m/hung")], activeTab: 0).get()
        defer { _ = WorkspacesFeature.store.delete(id: saved.id) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let opener = WorkspaceOpener(check: WorkspaceOpenCheck(deadline: 0.05) { _ in
            gate.wait()
            return true
        })
        try await withFolders(["a"]) { places in
            let window = openWindow(places[0])
            defer { window.close() }
            opener.open(saved.id, replacing: window)
            #expect(opener.check.isRunning)
            while opener.check.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(window.tabs.map(\.location) == [.folder(places[0])])
        }
    }

    @Test func clearHistoryLeavesWorkspacesAlone() throws {
        #expect(Self.problem == nil)
        WorkspacesFeature.store.loadIfNeeded()
        let tabs = [SessionTab(location: "home", back: ["trash"], forward: ["network"])]
        let saved = try WorkspacesFeature.store.save(name: "Kept", tabs: tabs, activeTab: 0).get()
        defer { _ = WorkspacesFeature.store.delete(id: saved.id) }
        HomeStore.clearHistory()
        let after = try #require(WorkspacesFeature.store.list.workspace(id: saved.id))
        #expect(after == saved)
        #expect(after.tabs.allSatisfy { $0.back.isEmpty && $0.forward.isEmpty })
    }
}
