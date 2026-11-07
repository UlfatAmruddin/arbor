import Foundation

/// Explorer's "Optimize this folder for:" templates (Properties › Customize, FE-154).
public enum FolderTemplate: String, CaseIterable, Sendable {
    case generalItems, documents, pictures, music, videos

    public var title: String {
        switch self {
        case .generalItems: return "General items"
        case .documents: return "Documents"
        case .pictures: return "Pictures"
        case .music: return "Music"
        case .videos: return "Videos"
        }
    }
}

/// Per-folder template choices, persisted in a `UserDefaults` dictionary.
///
/// **Shared API for other features (Folder Options, views, columns):**
/// - Storage key `folderTemplates` in the app's preferences (`Prefs.store`): a dictionary keyed by
///   the standardized folder path without a trailing slash, whose values are `["template": <FolderTemplate.rawValue>,
///   "subfolders": Bool]`.
/// - Read with `FolderTemplateStore(defaults: Prefs.store).effectiveTemplate(for: url)`; it returns
///   the folder's own choice, else the nearest ancestor's choice made with "Also apply this template
///   to all subfolders", else nil (meaning "not chosen": auto-detect or General items).
/// - The app posts `Notification.Name("ArborFolderTemplateChanged")` (object: the folder URL) after
///   a change, and `Prefs.changed` with `userInfo["key"] == "folderTemplates"`.
public struct FolderTemplateStore {
    public static let key = "folderTemplates"
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public struct Choice: Equatable, Sendable {
        public var template: FolderTemplate
        public var appliesToSubfolders: Bool
        public init(template: FolderTemplate, appliesToSubfolders: Bool) {
            self.template = template
            self.appliesToSubfolders = appliesToSubfolders
        }
    }

    private var all: [String: [String: Any]] { defaults.dictionary(forKey: Self.key) as? [String: [String: Any]] ?? [:] }

    /// The folder's own choice (not inherited).
    public func choice(for url: URL) -> Choice? {
        guard let entry = all[Location.normalizedPath(url)],
              let raw = entry["template"] as? String, let template = FolderTemplate(rawValue: raw) else { return nil }
        return Choice(template: template, appliesToSubfolders: entry["subfolders"] as? Bool ?? false)
    }

    /// The folder's choice, else the closest ancestor's that applies to subfolders.
    public func effectiveTemplate(for url: URL) -> FolderTemplate? {
        if let own = choice(for: url) { return own.template }
        var current = url.standardizedFileURL
        while current.path != "/" {
            current = current.deletingLastPathComponent()
            if let parent = choice(for: current), parent.appliesToSubfolders { return parent.template }
        }
        return nil
    }

    /// Sets (or with nil clears) a folder's template.
    public func set(_ choice: Choice?, for url: URL) {
        var dict = all
        let key = Location.normalizedPath(url)
        if let choice {
            dict[key] = ["template": choice.template.rawValue, "subfolders": choice.appliesToSubfolders]
        } else {
            dict.removeValue(forKey: key)
        }
        defaults.set(dict, forKey: Self.key)
    }
}
