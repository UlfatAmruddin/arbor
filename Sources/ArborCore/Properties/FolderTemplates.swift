import Foundation

/// Explorer's "Optimize this folder for:" templates (Properties › Customize, FE-154).
public enum FolderTemplate: String, CaseIterable, Sendable {
    case generalItems, documents, pictures, music, videos

    public var title: String {
        switch self {
        case .generalItems: return L10n.tr("General items")
        case .documents: return L10n.tr("Documents")
        case .pictures: return L10n.tr("Pictures")
        case .music: return L10n.tr("Music")
        case .videos: return L10n.tr("Videos")
        }
    }
}

/// Per-folder templates in `Prefs.store` under `folderTemplates`: normalized path → `["template", "subfolders"]`.
/// Changes post `ArborFolderTemplateChanged` (object: folder URL) and `Prefs.changed`.
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

    /// Not inherited.
    public func choice(for url: URL) -> Choice? {
        guard let entry = all[Location.normalizedPath(url)],
              let raw = entry["template"] as? String, let template = FolderTemplate(rawValue: raw) else { return nil }
        return Choice(template: template, appliesToSubfolders: entry["subfolders"] as? Bool ?? false)
    }

    /// Own choice, else the nearest ancestor's that applies to subfolders; nil means not chosen.
    public func effectiveTemplate(for url: URL) -> FolderTemplate? {
        if let own = choice(for: url) { return own.template }
        var current = url.standardizedFileURL
        while current.path != "/" {
            current = current.deletingLastPathComponent()
            if let parent = choice(for: current), parent.appliesToSubfolders { return parent.template }
        }
        return nil
    }

    /// nil clears.
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
