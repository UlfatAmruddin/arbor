import ArborCore
import Foundation

/// The only code that touches preferences for export and import (FE-208). Main thread only.
enum SettingsTransferStore {
    static func current(_ setting: PortableSetting) -> PortableValue? {
        switch setting.storage {
        case .folderOption:
            guard let fallback = setting.defaultValue.optionValue else { return nil }
            return PortableValue(FolderOptionsPrefs.read(setting.key, fallback: fallback))
        case .preference:
            let stored = Prefs.store.object(forKey: setting.key)
            switch setting.defaultValue {
            case .bool: return (stored as? Bool).map(PortableValue.bool)
            case .integer: return (stored as? Int).map(PortableValue.integer)
            case .string: return (stored as? String).map(PortableValue.string)
            }
        }
    }

    /// What a key off the allowlist holds, so scripted checks can show an import left it alone.
    static func localOnlyValue(_ key: String) -> PortableValue? {
        FolderOptionsCatalog.item(key)?.defaultValue.map { PortableValue(FolderOptionsPrefs.read(key, fallback: $0)) }
    }

    /// Both writers post `Prefs.changed` per key, so open windows and an open Folder Options dialog update themselves.
    static func apply(_ plan: PortableImportPlan) {
        var options: [String: OptionValue] = [:]
        for change in plan.changes {
            switch change.setting.storage {
            case .folderOption: options[change.setting.key] = change.new.optionValue
            case .preference: Prefs.setValue(preferenceValue(change.new), forKey: change.setting.key)
            }
        }
        FolderOptionsPrefs.write(options)
    }

    private static func preferenceValue(_ value: PortableValue) -> Any {
        switch value {
        case .bool(let flag): return flag
        case .integer(let number): return number
        case .string(let text): return text
        }
    }
}
