import Foundation

/// Saved per-folder views and "Apply to Folders" defaults (FE-041, FE-052, FE-248), as JSON in Application Support.
/// Keeps the `limit` most recently used; never writes inside folders. Not thread-safe.
public final class FolderViewStore {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String?
        public var path: String
        /// Template at save time ("Apply to Folders" drops views of that type).
        public var template: FolderTemplate?
        public var settings: FolderViewSettings
        public var lastUsed: Date
    }

    struct FileFormat: Codable {
        var version: Int
        var entries: [Entry]
        var templates: [String: FolderViewSettings]
    }

    public let fileURL: URL?
    public let limit: Int
    private let now: () -> Date
    private(set) public var entries: [Entry] = []
    private var templates: [FolderTemplate: FolderViewSettings] = [:]
    /// Unsaved changes exist.
    public private(set) var isDirty = false

    public init(fileURL: URL?, limit: Int = 2000, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        self.now = now
        load()
    }

    public var count: Int { entries.count }

    // MARK: Lookup

    /// Identity match wins; a path match counts only if one side lacks an identity (else the folder was replaced).
    private func index(for identity: FolderIdentity) -> Int? {
        if let id = identity.id, let i = entries.firstIndex(where: { $0.id == id }) { return i }
        return entries.firstIndex { $0.path == identity.path && ($0.id == nil || identity.id == nil) }
    }

    public func override(for identity: FolderIdentity) -> FolderViewSettings? {
        guard let i = index(for: identity) else { return nil }
        // At most daily, so browsing doesn't keep rewriting the file.
        let today = now()
        if today.timeIntervalSince(entries[i].lastUsed) > 86_400 {
            entries[i].lastUsed = today
            isDirty = true
        }
        if entries[i].path != identity.path || (entries[i].id == nil && identity.id != nil) {
            entries[i].path = identity.path     // renamed or moved within the volume
            entries[i].id = identity.id ?? entries[i].id
            isDirty = true
        }
        return entries[i].settings
    }

    /// Saves (or with nil/empty settings removes) a folder's own view.
    public func setOverride(_ settings: FolderViewSettings?, for identity: FolderIdentity, template: FolderTemplate? = nil) {
        // A stale entry at the same path with another identity is replaced.
        if let id = identity.id { entries.removeAll { $0.path == identity.path && $0.id != nil && $0.id != id } }
        let i = index(for: identity)
        guard let settings, !settings.isEmpty else {
            if let i { entries.remove(at: i); isDirty = true }
            return
        }
        let entry = Entry(id: identity.id, path: identity.path, template: template, settings: settings, lastUsed: now())
        if let i { entries[i] = entry } else { entries.append(entry) }
        isDirty = true
        prune()
    }

    /// A renamed virtual folder keeps its saved view; anything already filed under the new identity is replaced.
    public func moveOverride(from old: FolderIdentity, to new: FolderIdentity) {
        guard old != new, let i = index(for: old) else { return }
        var entry = entries.remove(at: i)
        entry.id = new.id
        entry.path = new.path
        if let existing = index(for: new) { entries.remove(at: existing) }
        entries.append(entry)
        isDirty = true
    }

    public func templateDefault(_ template: FolderTemplate) -> FolderViewSettings? { templates[template] }

    /// "Apply to Folders": every folder of this type uses `settings`; their own saved views are dropped.
    public func applyToFolders(_ settings: FolderViewSettings, template: FolderTemplate) {
        templates[template] = settings.isEmpty ? nil : settings
        entries.removeAll { $0.template == template }
        isDirty = true
    }

    public func setTemplateDefault(_ settings: FolderViewSettings?, for template: FolderTemplate) {
        templates[template] = (settings?.isEmpty ?? true) ? nil : settings
        isDirty = true
    }

    /// "Reset Folders": forget all saved views and template defaults.
    public func resetAll() {
        entries.removeAll()
        templates.removeAll()
        isDirty = true
    }

    public var appliedTemplates: [FolderTemplate] { FolderTemplate.allCases.filter { templates[$0] != nil } }

    // MARK: Bounds

    private func prune() {
        guard entries.count > limit else { return }
        // Drop to 90% of the limit so a busy session doesn't prune on every save.
        let keep = max(1, limit * 9 / 10)
        entries.sort { $0.lastUsed > $1.lastUsed }
        entries.removeSubrange(keep...)
    }

    // MARK: Persistence

    public func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(FileFormat.self, from: data) else { return }   // corrupt: start empty
        entries = file.entries
        templates = Dictionary(uniqueKeysWithValues: file.templates.compactMap { key, value in
            FolderTemplate(rawValue: key).map { ($0, value) }
        })
        prune()
        isDirty = false
    }

    /// Cheap; call on the owning thread, write the data anywhere.
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let file = FileFormat(version: 1, entries: entries,
                              templates: Dictionary(uniqueKeysWithValues: templates.map { ($0.key.rawValue, $0.value) }))
        return try? encoder.encode(file)
    }

    /// Returns the data to write and marks the store clean, or nil if nothing changed.
    public func takeChanges() -> Data? {
        guard isDirty else { return nil }
        isDirty = false
        return encoded()
    }

    public func save() throws {
        guard let fileURL, let data = encoded() else { return }
        try Self.write(data, to: fileURL)
        isDirty = false
    }

    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
