import AppKit
import ArborCore

/// Export and import of preferences as one portable file, started only from the menu (FE-208, DEC-settings-9).
enum SettingsTransferFeature: ExplorerFeature {
    static let id = "settings-transfer"

    static func register() {
        CommandRegistry.shared.register([
            ExplorerCommand(
                id: "settings.export", title: "Export Settings…",
                placements: [.mainMenu("Arbor", .main, 20)],
                isEnabled: { _ in SettingsTransferFlow.canExport },
                perform: { _ in if let browser = BrowserWindowController.active { SettingsTransferFlow.chooseExportDestination(from: browser) } }),
            ExplorerCommand(
                id: "settings.import", title: "Import Settings…",
                placements: [.mainMenu("Arbor", .main, 30)],
                isEnabled: { _ in SettingsTransferFlow.canImport },
                perform: { _ in if let browser = BrowserWindowController.active { SettingsTransferFlow.chooseImportFile(from: browser) } }),
        ])
        registerScriptSteps()
    }

    /// The same flows from a path; only the panels are skipped, and they can't be driven headless.
    private static func registerScriptSteps() {
        DebugScript.registerStep("settingsexport") { path, browser in
            if let browser { SettingsTransferFlow.exportSettings(to: URL(fileURLWithPath: path), from: browser) }
            return 0.8
        }
        // Holds the script until the preview or a message is up.
        DebugScript.registerWaitStep("settingsimport") { path, browser, elapsed in
            guard let browser else { return true }
            if elapsed == 0 {
                SettingsTransferFlow.importSettings(from: URL(fileURLWithPath: path), into: browser)
                return false
            }
            return browser.window?.attachedSheet != nil || !SettingsTransferFlow.isImporting
        }
        DebugScript.registerLogger("settings-transfer.log") { browser in
            let portable = PortableSettingsCatalog.all.map { "\($0.key)=\(debugText($0.normalized(SettingsTransferStore.current($0))))" }
            let local = PortableSettingsCatalog.localOnlyFolderOptions.sorted().compactMap { key in
                SettingsTransferStore.localOnlyValue(key).map { "\(key)=\(debugText($0))" }
            }
            let lines = ["settings: \(portable.joined(separator: " "))", "settings local: \(local.joined(separator: " "))", previewFocus(browser)]
            return lines.compactMap { $0 }.joined(separator: "\n")
        }
    }

    private static func previewFocus(_ browser: BrowserWindowController?) -> String? {
        guard let sheet = browser?.window?.attachedSheet else { return nil }
        guard let list = sheet.firstResponder as? KeyboardScrollView else { return "settings preview: focus=elsewhere" }
        return "settings preview: focus=list offset=\(Int(list.contentView.bounds.minY))"
    }

    private static func debugText(_ value: PortableValue) -> String {
        switch value {
        case .bool(let flag): return flag ? "on" : "off"
        case .integer(let number): return "\(number)"
        case .string(let text): return text
        }
    }
}
