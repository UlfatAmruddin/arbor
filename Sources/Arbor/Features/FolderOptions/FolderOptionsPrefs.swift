import AppKit
import ArborCore

/// Folder Options values in `Prefs` (FE-205: app-wide). Catalog keys are pref keys, except four older ones.
extension Prefs {
    static var openTo: Location { string("openTo", default: "home") == "thismac" ? .thisMac : .home }
    static var openFoldersInOwnWindow: Bool { string("browseFolders", default: "same") == "own" }
    static var singleClickToOpen: Bool { string("clickItems", default: "double") == "single" }
    /// "always" (like links in a browser) or "hover".
    static var underlineTitles: String { string("underlineTitles", default: "hover") }
    static var fullPathInTitleBar: Bool { bool("fullPathInTitleBar", default: false) }
    static var hideProtectedSystemFiles: Bool { bool("hideProtectedSystemFiles", default: true) }
    static var restorePreviousWindows: Bool { bool("restorePreviousWindows", default: false) }
    static var showPopupDescriptions: Bool { bool("showPopupDescriptions", default: true) }
    static var showPreviewHandlers: Bool { bool("showPreviewHandlers", default: true) }
    static var showStatusBar: Bool { bool("showStatusBar", default: true) }
    static var showSyncProviderNotifications: Bool { bool("showSyncProviderNotifications", default: true) }
    static var typeIntoSearchBox: Bool { string("typingMode", default: "select") == "search" }
    static var fileListKeyPreset: FileListKeyPreset {
        FileListKeyPreset(stored: string(FileListKeyPreset.preferenceKey, default: FileListKeyPreset.standard.rawValue))
    }
    static var navShowAvailabilityStatus: Bool { bool("navShowAvailabilityStatus", default: false) }
    static var navExpandToOpenFolder: Bool { bool("navExpandToOpenFolder", default: false) }
    static var navShowAllFolders: Bool { bool("navShowAllFolders", default: false) }
}

enum FolderOptionsPrefs {
    /// Keys stored under another name or meaning (Home's `home.*`, `thisMac.*`; icon views read `alwaysShowIcons`).
    private static let bridged: Set<String> = ["compactView", "itemCheckBoxes", "hideExtensions", "hiddenFiles",
                                               "showRecentFiles", "showFrequentFolders", "hideEmptyDrives"]

    /// The preference key a catalog key is stored under (what `Prefs.changed` reports).
    static func storageKey(_ key: String) -> String {
        switch key {
        case "hideExtensions": return "showExtensions"
        case "hiddenFiles": return "showHidden"
        case "showRecentFiles": return HomePrefKeys.showRecentFiles
        case "showFrequentFolders": return HomePrefKeys.showFrequentFolders
        case "hideEmptyDrives": return HomePrefKeys.hideEmptyDrives
        default: return key
        }
    }

    /// Current values for every available control.
    static func current() -> [String: OptionValue] {
        var values: [String: OptionValue] = [:]
        for item in FolderOptionsCatalog.all where item.isAvailable {
            guard let fallback = item.defaultValue else { continue }
            values[item.key] = read(item.key, fallback: fallback)
        }
        return values
    }

    static func read(_ key: String, fallback: OptionValue) -> OptionValue {
        switch key {
        case "compactView": return .bool(Prefs.compactView)
        case "itemCheckBoxes": return .bool(Prefs.itemCheckBoxes)
        case "hideExtensions": return .bool(!Prefs.showExtensions)
        case "hiddenFiles": return .string(Prefs.showHidden ? "show" : "hide")
        case "showRecentFiles": return .bool(Prefs.showRecentFiles)
        case "showFrequentFolders": return .bool(Prefs.showFrequentFolders)
        case "hideEmptyDrives": return .bool(Prefs.hideEmptyDrives)
        default:
            switch fallback {
            case .bool(let b): return .bool(Prefs.bool(key, default: b))
            case .string(let s):
                let stored = Prefs.string(key, default: s)
                let choices = FolderOptionsCatalog.item(key)?.choices ?? []
                // A damaged value would otherwise leave every radio unselected.
                return .string(choices.isEmpty || choices.contains { $0.value == stored } ? stored : s)
            }
        }
    }

    /// Writes changed values. Each write posts `Prefs.changed`, so open windows update.
    static func write(_ changes: [String: OptionValue]) {
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            switch (key, value) {
            case ("compactView", .bool(let b)): Prefs.compactView = b
            case ("itemCheckBoxes", .bool(let b)): Prefs.itemCheckBoxes = b
            case ("hideExtensions", .bool(let b)): Prefs.showExtensions = !b
            case ("hiddenFiles", .string(let s)): Prefs.showHidden = s == "show"
            case ("showRecentFiles", .bool(let b)): Prefs.showRecentFiles = b
            case ("showFrequentFolders", .bool(let b)): Prefs.showFrequentFolders = b
            case ("hideEmptyDrives", .bool(let b)): Prefs.hideEmptyDrives = b
            case (_, .bool(let b)) where !bridged.contains(key): Prefs.setValue(b, forKey: key)
            case (_, .string(let s)) where !bridged.contains(key): Prefs.setValue(s, forKey: key)
            default: NSLog("Folder Options: ignored \(key)=\(value)")
            }
        }
    }

    /// Keys whose control is disabled right now because a feature isn't installed.
    static var runtimeDisabledKeys: Set<String> {
        var keys: Set<String> = []
        if !librariesAvailable { keys.insert("showLibraries") }
        return keys
    }

    /// True once a real Libraries provider is registered (the placeholder page doesn't count).
    static var librariesAvailable: Bool {
        !(LocationRegistry.provider(for: .library("Documents")) is PlaceholderProvider)
    }
}
