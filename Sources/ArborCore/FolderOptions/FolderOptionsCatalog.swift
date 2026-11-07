import Foundation

/// The three pages of Folder Options, in Windows order (reference §11).
public enum FolderOptionsTab: String, CaseIterable, Sendable {
    case general, view, search

    public var title: String {
        switch self {
        case .general: return "General"
        case .view: return "View"
        case .search: return "Search"
        }
    }
}

/// A Folder Options value: a check box (bool) or the chosen radio/pop-up value (string).
public enum OptionValue: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case string(String)

    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }

    public var description: String {
        switch self {
        case .bool(let b): return b ? "1" : "0"
        case .string(let s): return s
        }
    }

    /// Parses script/debug text: "1/0/true/false/yes/no" become bools, anything else a string.
    public init(parsing text: String) {
        switch text.lowercased() {
        case "1", "true", "yes", "on": self = .bool(true)
        case "0", "false", "no", "off": self = .bool(false)
        default: self = .string(text)
        }
    }
}

public struct OptionChoice: Equatable, Sendable {
    public let value: String
    public let title: String
    /// Indentation of this choice below the parent (Windows nests the underline choices).
    public let level: Int
    /// Only enabled while another key has a given value (e.g. underline style needs single-click).
    public let enabledWhen: (key: String, value: String)?

    public init(_ value: String, _ title: String, level: Int = 0, enabledWhen: (key: String, value: String)? = nil) {
        self.value = value
        self.title = title
        self.level = level
        self.enabledWhen = enabledWhen
    }

    public static func == (a: OptionChoice, b: OptionChoice) -> Bool {
        a.value == b.value && a.title == b.title && a.level == b.level
    }
}

/// One control in Folder Options.
public struct FolderOptionItem: Sendable {
    public enum Kind: Sendable {
        /// A folder-icon node in the Advanced settings tree ("Files and Folders", "Navigation pane").
        case group
        case check
        /// A node whose children are radio buttons ("Hidden files and folders").
        case radio([OptionChoice])
        /// A pop-up menu ("Open Arbor to:").
        case popup([OptionChoice])
    }

    public let key: String
    public let title: String
    public let kind: Kind
    public let defaultValue: OptionValue?
    public let tab: FolderOptionsTab
    /// Group box (General/Search) or tree group (View) this item belongs to.
    public let section: String
    /// When set, the control is shown disabled with this one-line Mac explanation (DEC-019).
    public let unavailableReason: String?

    public init(_ key: String, _ title: String, kind: Kind = .check, default value: OptionValue?, tab: FolderOptionsTab,
                section: String, unavailable: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = value
        self.tab = tab
        self.section = section
        self.unavailableReason = unavailable
    }

    public var isAvailable: Bool { unavailableReason == nil }

    public var choices: [OptionChoice] {
        switch kind {
        case .radio(let c), .popup(let c): return c
        default: return []
        }
    }
}

/// Every control on Windows 11's Folder Options pages, in Windows order and wording, adapted to the Mac
/// (FE-042, FE-043). Items macOS can't support stay visible but disabled with an explanation.
///
/// Keys are preference names. A few map onto older preferences with the opposite meaning in the app
/// (`hideExtensions` ↔ `showExtensions`, `hiddenFiles` ↔ `showHidden`); the app bridges those.
public enum FolderOptionsCatalog {
    public static let files = "Files and Folders"
    public static let navigation = "Navigation pane"

    public static let general: [FolderOptionItem] = [
        FolderOptionItem("openTo", "Open Arbor to:", kind: .popup([OptionChoice("home", "Home"), OptionChoice("thismac", "This Mac")]),
                         default: .string("home"), tab: .general, section: ""),
        FolderOptionItem("browseFolders", "Browse folders", kind: .radio([
            OptionChoice("same", "Open each folder in the same window"),
            OptionChoice("own", "Open each folder in its own window"),
        ]), default: .string("same"), tab: .general, section: "Browse folders"),
        FolderOptionItem("clickItems", "Click items as follows", kind: .radio([
            OptionChoice("single", "Single-click to open an item (point to select)"),
            OptionChoice("double", "Double-click to open an item (single-click to select)"),
        ]), default: .string("double"), tab: .general, section: "Click items as follows"),
        // Shown nested under "Single-click to open an item" like Windows.
        FolderOptionItem("underlineTitles", "Underline icon titles", kind: .radio([
            OptionChoice("always", "Underline icon titles consistent with my browser", level: 1, enabledWhen: ("clickItems", "single")),
            OptionChoice("hover", "Underline icon titles only when I point at them", level: 1, enabledWhen: ("clickItems", "single")),
        ]), default: .string("hover"), tab: .general, section: "Click items as follows"),
        FolderOptionItem("showRecentFiles", "Show recently used files", default: .bool(true), tab: .general, section: "Privacy"),
        FolderOptionItem("showFrequentFolders", "Show frequently used folders", default: .bool(true), tab: .general, section: "Privacy"),
        FolderOptionItem("accountInsights", "Include account-based insights, recent, favorite, and recommended files",
                         default: nil, tab: .general, section: "Privacy",
                         unavailable: "Arbor doesn't connect to Microsoft accounts or Office.com."),
    ]

    public static let advanced: [FolderOptionItem] = [
        FolderOptionItem("group.files", files, kind: .group, default: nil, tab: .view, section: files),
        check("alwaysShowIcons", "Always show icons, never thumbnails", false),
        check("alwaysShowMenus", "Always show menus", nil, unavailable: "The Mac menu bar is always shown."),
        check("compactView", "Decrease space between items (compact view)", false),
        check("fileIconOnThumbnails", "Display file icon on thumbnails", nil,
              unavailable: "Arbor's thumbnails don't carry a file-type badge yet."),
        check("folderTipSizes", "Display file size information in folder tips", nil,
              unavailable: "Folder sizes need a full scan, so Arbor shows them in Properties instead."),
        check("fullPathInTitleBar", "Display the full path in the title bar", false),
        FolderOptionItem("hiddenFiles", "Hidden files and folders", kind: .radio([
            OptionChoice("hide", "Don't show hidden files, folders, or drives"),
            OptionChoice("show", "Show hidden files, folders, and drives"),
        ]), default: .string("hide"), tab: .view, section: files),
        check("hideEmptyDrives", "Hide empty drives", true),
        // Arbor shows extensions by default (DEC-008), so its default differs from Windows'.
        check("hideExtensions", "Hide extensions for known file types", false),
        check("hideFolderMergeConflicts", "Hide folder merge conflicts", true),
        check("hideProtectedSystemFiles", "Hide protected operating system files (Recommended)", true),
        check("separateProcess", "Launch folder windows in a separate process", nil,
              unavailable: "Arbor runs every window in one process to keep memory use low."),
        check("restorePreviousWindows", "Restore previous folder windows at launch", false),
        check("showDriveLetters", "Show drive letters", nil, unavailable: "Mac volumes have names, not drive letters."),
        check("showCompressedInColor", "Show encrypted or compressed NTFS files in color", nil,
              unavailable: "Mac volumes have no NTFS compression or encryption attributes."),
        check("showPopupDescriptions", "Show pop-up description for folder and desktop items", true),
        check("showPreviewHandlers", "Show preview handlers in preview pane", true),
        check("showStatusBar", "Show status bar", true),
        check("showSyncProviderNotifications", "Show sync provider notifications", true),
        check("itemCheckBoxes", "Use check boxes to select items", false),
        check("sharingWizard", "Use Sharing Wizard (Recommended)", nil,
              unavailable: "Sharing is set up in System Settings › General › Sharing."),
        FolderOptionItem("typingMode", "When typing into list view", kind: .radio([
            OptionChoice("search", "Automatically type into the Search Box"),
            OptionChoice("select", "Select the typed item in the view"),
        ]), default: .string("select"), tab: .view, section: files),
        FolderOptionItem("group.navigation", navigation, kind: .group, default: nil, tab: .view, section: navigation),
        nav("navShowAvailabilityStatus", "Always show availability status", false),
        nav("navExpandToOpenFolder", "Expand to open folder", false),
        nav("navShowAllFolders", "Show all folders", false),
        nav("showLibraries", "Show libraries", false),
    ]

    public static let search: [FolderOptionItem] = [
        FolderOptionItem("searchWithoutIndex", "Don't use the index when searching in file folders for system files (searches might take longer)",
                         default: .bool(false), tab: .search, section: "How to search"),
        FolderOptionItem("searchIncludeSystemDirectories", "Include system directories",
                         default: .bool(true), tab: .search, section: "When searching non-indexed locations"),
        FolderOptionItem("searchIncludeCompressedFiles", "Include compressed files (ZIP, CAB...)",
                         default: .bool(false), tab: .search, section: "When searching non-indexed locations"),
        FolderOptionItem("searchFileContents", "Always search file names and contents (this might take several minutes)",
                         default: .bool(false), tab: .search, section: "When searching non-indexed locations"),
    ]

    private static func check(_ key: String, _ title: String, _ value: Bool?, unavailable: String? = nil) -> FolderOptionItem {
        FolderOptionItem(key, title, default: value.map(OptionValue.bool), tab: .view, section: files, unavailable: unavailable)
    }

    private static func nav(_ key: String, _ title: String, _ value: Bool) -> FolderOptionItem {
        FolderOptionItem(key, title, default: .bool(value), tab: .view, section: navigation)
    }

    public static func items(in tab: FolderOptionsTab) -> [FolderOptionItem] {
        switch tab {
        case .general: return general
        case .view: return advanced
        case .search: return search
        }
    }

    public static var all: [FolderOptionItem] { general + advanced + search }

    public static func item(_ key: String) -> FolderOptionItem? { all.first { $0.key == key } }

    /// Keys that hold a value (not tree groups, not unavailable items).
    public static func valueKeys(in tab: FolderOptionsTab) -> [String] {
        items(in: tab).filter { $0.defaultValue != nil && $0.isAvailable }.map(\.key)
    }

    public static func defaults(for tab: FolderOptionsTab) -> [String: OptionValue] {
        var result: [String: OptionValue] = [:]
        for item in items(in: tab) where item.isAvailable { if let v = item.defaultValue { result[item.key] = v } }
        return result
    }

    public static var allDefaults: [String: OptionValue] {
        FolderOptionsTab.allCases.reduce(into: [:]) { result, tab in result.merge(defaults(for: tab)) { a, _ in a } }
    }
}

/// The dialog's working copy (OK / Cancel / Apply semantics, FE-248). Changes stay in the draft until
/// committed; Cancel simply drops the draft. "Restore Defaults" only touches the current page.
public struct FolderOptionsDraft: Sendable {
    public private(set) var committed: [String: OptionValue]
    public private(set) var values: [String: OptionValue]
    /// Keys the app reports as unavailable at run time (e.g. libraries not installed).
    public var disabledKeys: Set<String>

    public init(current: [String: OptionValue], disabledKeys: Set<String> = []) {
        committed = current
        values = current
        self.disabledKeys = disabledKeys
    }

    public subscript(key: String) -> OptionValue? { values[key] }

    public mutating func set(_ key: String, _ value: OptionValue) {
        guard !disabledKeys.contains(key) else { return }
        values[key] = value
    }

    /// Changed keys, in catalog order.
    public var changedKeys: [String] {
        let order = FolderOptionsCatalog.all.map(\.key)
        let keys = Set(values.keys).union(committed.keys).filter { values[$0] != committed[$0] }
        return keys.sorted { (order.firstIndex(of: $0) ?? Int.max, $0) < (order.firstIndex(of: $1) ?? Int.max, $1) }
    }

    public var isDirty: Bool { !changedKeys.isEmpty }

    /// Whether a control is enabled given the draft (unavailable items and dependent radios).
    public func isEnabled(_ choice: OptionChoice) -> Bool {
        guard let dependency = choice.enabledWhen else { return true }
        return values[dependency.key]?.string == dependency.value
    }

    public mutating func restoreDefaults(_ tab: FolderOptionsTab) {
        for (key, value) in FolderOptionsCatalog.defaults(for: tab) where !disabledKeys.contains(key) { values[key] = value }
    }

    /// Makes the draft the committed state and returns what changed (Apply / OK).
    @discardableResult
    public mutating func commit() -> [String: OptionValue] {
        var changes: [String: OptionValue] = [:]
        for key in changedKeys { if let v = values[key] { changes[key] = v } }
        committed = values
        return changes
    }

    /// Takes values that changed outside the dialog (menu toggles) for keys the user hasn't edited.
    public mutating func refresh(from current: [String: OptionValue]) {
        let edited = Set(changedKeys)
        for (key, value) in current where !edited.contains(key) { values[key] = value }
        committed = current
        for key in edited { if let v = values[key], current[key] == v { committed[key] = v } }
    }
}
