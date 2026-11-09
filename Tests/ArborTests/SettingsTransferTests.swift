import AppKit
import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// Applying an import reaches the real preferences (registration suite: throwaway preferences domain).
extension FeatureRegistrationTests {
    private func importPlan(_ settings: String) throws -> PortableImportPlan {
        let data = Data(#"{"format":"arbor.settings","version":1,"settings":\#(settings)}"#.utf8)
        return PortableImportPlan.make(file: try PortableSettingsFile.decode(data), current: SettingsTransferStore.current)
    }

    private func forgetPreferences(_ keys: [String]) {
        for key in keys { Prefs.setValue(nil, forKey: key) }
    }

    @Test func settingsCommandsSitInTheAppMenu() throws {
        #expect(Self.problem == nil)
        let exported = try #require(CommandRegistry.shared.command("settings.export"))
        let imported = try #require(CommandRegistry.shared.command("settings.import"))
        #expect(exported.placements.contains { $0.slot == .mainMenu("Arbor") })
        #expect(imported.placements.contains { $0.slot == .mainMenu("Arbor") })
    }

    @Test func folderOptionsKeepTheirBridgedStorage() throws {
        #expect(Self.problem == nil)
        defer { forgetPreferences(["showHidden"]) }
        let setting = try #require(PortableSettingsCatalog.setting("hiddenFiles"))

        Prefs.showHidden = true
        #expect(SettingsTransferStore.current(setting) == .string("show"))

        SettingsTransferStore.apply(try importPlan(#"{"hiddenFiles":"hide"}"#))
        #expect(Prefs.showHidden == false)
        #expect(SettingsTransferStore.current(setting) == .string("hide"))
    }

    /// Each plain preference with the getter its owner reads; a new catalog entry fails below until it is listed here.
    private var preferenceOwners: [String: () -> PortableValue] {
        [
            "navigationPaneVisible": { .bool(Prefs.navigationPaneVisible) },
            TextSize.key: { .integer(TextSize.level.rawValue) },
            PointerNavigation.prefKey: { .bool(PointerNavigation.swipeEnabled) },
            "fileOpsQueueSameDrive": { .bool(Prefs.fileOpsQueueSameDrive) },
            "fileOpsConcurrencyLimit": { .integer(Prefs.fileOpsConcurrencyLimit) },
        ]
    }

    private var catalogPreferences: [PortableSetting] { PortableSettingsCatalog.all.filter { $0.storage == .preference } }

    @Test func everyCatalogPreferenceHasAKnownOwner() {
        #expect(Self.problem == nil)
        #expect(Set(preferenceOwners.keys) == Set(catalogPreferences.map(\.key)))
    }

    @Test func catalogDefaultsMatchWhatOwnersReturn() {
        #expect(Self.problem == nil)
        forgetPreferences(Array(preferenceOwners.keys))
        for setting in catalogPreferences { #expect(preferenceOwners[setting.key]?() == setting.defaultValue, "\(setting.key)") }
    }

    @Test func everyPreferenceKeyMatchesTheOneItsOwnerReads() throws {
        #expect(Self.problem == nil)
        defer { forgetPreferences(Array(preferenceOwners.keys)) }
        let imported = try Dictionary(uniqueKeysWithValues: catalogPreferences.map { setting in
            (setting.key, try #require(setting.choices.first { $0.value != setting.defaultValue }).value)
        })

        SettingsTransferStore.apply(try importPlan(String(decoding: try JSONEncoder().encode(imported), as: UTF8.self)))

        for (key, value) in imported { #expect(preferenceOwners[key]?() == value, "\(key)") }
    }

    @Test func applyingAnnouncesTheStorageKey() throws {
        #expect(Self.problem == nil)
        defer { forgetPreferences(["showHidden", "fileOpsQueueSameDrive"]) }
        var announced: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: nil) { note in
            if let key = note.userInfo?["key"] as? String { announced.append(key) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        SettingsTransferStore.apply(try importPlan(#"{"hiddenFiles":"show","fileOpsQueueSameDrive":true}"#))
        #expect(Set(announced) == ["showHidden", "fileOpsQueueSameDrive"])
    }

    @Test func theQueueMenuOffersTheSameTransferLimitsAsTheFile() throws {
        #expect(Self.problem == nil)
        let setting = try #require(PortableSettingsCatalog.setting("fileOpsConcurrencyLimit"))
        let offered = QueueOptionsMenu.items().filter { $0.indentationLevel == 1 }.map(\.title)
        #expect(offered == setting.choices.map(\.title))
    }

    @Test func anExportNeverReadsPastTheAllowlist() throws {
        #expect(Self.problem == nil)
        defer { forgetPreferences([TextSize.key, "quickAccessPaths"]) }
        Prefs.setValue("/Users/me/private", forKey: TextSize.key)
        Prefs.setValue(["/Users/me/private"], forKey: "quickAccessPaths")

        let text = String(decoding: try PortableSettingsFile.encoded(reading: SettingsTransferStore.current), as: UTF8.self)
        #expect(!text.contains("/Users/me"))
        #expect(text.contains(#""textSize" : 100"#))
        #expect(!text.contains("quickAccessPaths"))
    }

    @Test func aClosedWindowsLateReplyLeavesANewerImportRunning() {
        #expect(Self.problem == nil)
        let first = NSWindow()
        let second = NSWindow()
        defer { SettingsTransferFlow.endImport(on: second) }

        SettingsTransferFlow.beginImport(on: first)
        SettingsTransferFlow.beginImport(on: second)
        SettingsTransferFlow.endImport(on: first)
        #expect(SettingsTransferFlow.importHost === second)

        SettingsTransferFlow.endImport(on: second)
        #expect(SettingsTransferFlow.importHost == nil)
    }

    @Test func thePreviewAnswersEscapeButNotReturn() throws {
        #expect(Self.problem == nil)
        let alert = SettingsImportPreview.alert(for: try importPlan(#"{"compactView":true}"#))
        #expect(alert.buttons.map(\.keyEquivalent) == ["", "\u{1b}"])
        #expect(alert.window.initialFirstResponder === alert.accessoryView)
    }

    private func press(_ key: NSEvent.SpecialKey, on list: KeyboardScrollView) throws {
        let text = String(key.unicodeScalar)
        list.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0, windowNumber: 0,
                                                         context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)))
    }

    @Test func thePreviewListScrollsFromTheKeyboardAndStopsAtItsEnds() throws {
        let list = KeyboardScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        list.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        var offset: CGFloat { list.contentView.bounds.minY }
        #expect(list.acceptsFirstResponder && list.becomeFirstResponder())

        try press(.pageDown, on: list)
        #expect(offset == 100 - list.verticalPageScroll)
        try press(.downArrow, on: list)
        #expect(offset == 100 - list.verticalPageScroll + list.verticalLineScroll)
        try press(.end, on: list)
        #expect(offset == 900)
        try press(.pageDown, on: list)
        #expect(offset == 900)
        try press(.upArrow, on: list)
        #expect(offset == 900 - list.verticalLineScroll)
        try press(.home, on: list)
        #expect(offset == 0)
        try press(.pageUp, on: list)
        #expect(offset == 0)
    }
}
