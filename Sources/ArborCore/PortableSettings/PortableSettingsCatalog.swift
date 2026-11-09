import Foundation

/// A value a portable setting can hold. Equality is type-strict: `.integer(1)` never matches `.bool(true)`.
public enum PortableValue: Hashable, Sendable, Codable {
    case bool(Bool)
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public init(_ option: OptionValue) {
        switch option {
        case .bool(let value): self = .bool(value)
        case .string(let value): self = .string(value)
        }
    }

    /// The Folder Options form of this value; nil for integers, which Folder Options has none of.
    public var optionValue: OptionValue? {
        switch self {
        case .bool(let value): return .bool(value)
        case .string(let value): return .string(value)
        case .integer: return nil
        }
    }
}

public struct PortableChoice: Equatable, Sendable {
    public let value: PortableValue
    public let title: String

    public init(_ value: PortableValue, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// One setting a file may carry: a key plus a closed list of values, so a path or a credential can't pass validation.
public struct PortableSetting: Equatable, Sendable {
    public enum Storage: Sendable {
        /// Read and written through Folder Options, which bridges the keys stored under another name.
        case folderOption
        /// A plain preference; `key` is both the file key and the preference key.
        case preference
    }

    public let key: String
    public let title: String
    public let choices: [PortableChoice]
    public let defaultValue: PortableValue
    public let storage: Storage

    public func allows(_ value: PortableValue) -> Bool { choices.contains { $0.value == value } }

    /// The value, or the default when it is missing or not allowed (as the preference getters fall back).
    public func normalized(_ value: PortableValue?) -> PortableValue {
        guard let value, allows(value) else { return defaultValue }
        return value
    }

    public func title(of value: PortableValue) -> String { choices.first { $0.value == value }?.title ?? "" }
}

/// The audited allowlist (FE-208, DEC-settings-2): a setting not listed here can't be exported or imported.
public enum PortableSettingsCatalog {
    public static let all: [PortableSetting] = portableFolderOptions.compactMap(folderOption) + preferences

    private static let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    public static func setting(_ key: String) -> PortableSetting? { byKey[key] }

    static let portableFolderOptions = [
        "openTo", "browseFolders", "compactView", "fullPathInTitleBar", "hiddenFiles",
        "hideEmptyDrives", "showPopupDescriptions", "showStatusBar", "showSyncProviderNotifications", "itemCheckBoxes",
        "typingMode", "navShowAvailabilityStatus", "navExpandToOpenFolder", "navShowAllFolders", "showLibraries", "navShowTags", FileListKeyPreset.preferenceKey, "wrapLongNames",
    ]

    /// Folder Options that stay on this Mac. A unit test requires every option to be here or in `portableFolderOptions`.
    public static let localOnlyFolderOptions: Set<String> = [
        // Hides a file's real type: `invoice.pdf.command` would read as `invoice.pdf`.
        "hideExtensions",
        // Changes how many clicks launch a file (DEC-settings-3); underlining shows only with single-click.
        "clickItems", "underlineTitles",
        // Removes a warning or a prompt the user relies on.
        "hideProtectedSystemFiles", "hideFolderMergeConflicts",
        // Turns activity recording on.
        "showRecentFiles", "showFrequentFolders", "restorePreviousWindows",
        // Decides which file contents Arbor parses.
        "showPreviewHandlers", "alwaysShowIcons", "searchFileContents", "searchIncludeCompressedFiles",
        // Search doesn't read these yet, so an import would change nothing (DEC-settings-4).
        "searchWithoutIndex", "searchIncludeSystemDirectories",
    ]

    private static let onOff = [PortableChoice(.bool(true), L10n.tr("On")), PortableChoice(.bool(false), L10n.tr("Off"))]

    private static func folderOption(_ key: String) -> PortableSetting? {
        guard let item = FolderOptionsCatalog.item(key), item.isAvailable, let fallback = item.defaultValue else { return nil }
        let choices = item.choices.isEmpty ? onOff : item.choices.map { PortableChoice(.string($0.value), $0.title) }
        return PortableSetting(key: key, title: item.title, choices: choices, defaultValue: PortableValue(fallback), storage: .folderOption)
    }

    private static func preference(_ key: String, _ title: String, _ choices: [PortableChoice], default value: PortableValue) -> PortableSetting {
        PortableSetting(key: key, title: title, choices: choices, defaultValue: value, storage: .preference)
    }

    private static func toggle(_ key: String, _ title: String, default value: Bool) -> PortableSetting {
        preference(key, title, onOff, default: .bool(value))
    }

    private static let concurrencyChoices = TransferScheduler.concurrencyLimitChoices.map {
        PortableChoice(.integer($0), TransferScheduler.concurrencyLimitTitle($0))
    }

    private static let preferences: [PortableSetting] = [
        toggle("navigationPaneVisible", L10n.tr("Navigation pane"), default: true),
        preference("textSize", L10n.tr("Text size"), TextSizeLevel.allCases.map { PortableChoice(.integer($0.rawValue), $0.title) },
                   default: .integer(TextSizeLevel.standard.rawValue)),
        toggle("swipeNavigation", L10n.tr("Swipe to go back and forward"), default: true),
        toggle("fileOpsQueueSameDrive", L10n.tr("Queue transfers to the same drive"), default: false),
        preference("fileOpsConcurrencyLimit", L10n.tr("Transfers to run at once"), concurrencyChoices, default: .integer(0)),
    ]
}
