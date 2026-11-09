import Foundation

public enum WorkspaceEditError: Error, Equatable, Sendable {
    case invalidName
    case duplicateName
    case notFound
    case limitReached
    /// Every tab was over the location key limit.
    case noStorableTabs
    /// The saved file would pass `WorkspaceFile.byteLimit` and could not be read back.
    case tooLarge
    case readOnly
}

/// The saved workspaces, sorted by name. Entries are always addressed by id, so a stale menu can't act on the wrong one.
public struct WorkspaceList: Equatable, Sendable {
    public static let limit = 100

    public private(set) var workspaces: [Workspace]

    public init() { workspaces = [] }

    init(validated workspaces: [Workspace]) { self.workspaces = Self.sorted(workspaces) }

    public func workspace(id: String) -> Workspace? { workspaces.first { $0.id == id } }

    public func workspace(named name: String) -> Workspace? { workspaces.first { WorkspaceName.matches($0.name, name) } }

    /// A same-named entry is replaced and keeps its id: saving again is how a workspace is updated.
    public mutating func save(name: String, tabs: [SessionTab], activeTab: Int) -> Result<Workspace, WorkspaceEditError> {
        guard let cleanName = WorkspaceName.clean(name) else { return .failure(.invalidName) }
        let existing = workspace(named: cleanName)
        if existing == nil, workspaces.count >= Self.limit { return .failure(.limitReached) }
        guard let saved = Workspace(id: existing?.id ?? UUID().uuidString, name: cleanName, tabs: tabs, activeTab: activeTab) else {
            return .failure(.noStorableTabs)
        }
        put(saved)
        return .success(saved)
    }

    /// A case-only change of the same entry is allowed.
    public mutating func rename(id: String, to name: String) -> Result<Workspace, WorkspaceEditError> {
        guard let current = workspace(id: id) else { return .failure(.notFound) }
        guard let cleanName = WorkspaceName.clean(name) else { return .failure(.invalidName) }
        if let other = workspace(named: cleanName), other.id != id { return .failure(.duplicateName) }
        let renamed = current.renamed(to: cleanName)
        put(renamed)
        return .success(renamed)
    }

    public mutating func delete(id: String) -> Result<Workspace, WorkspaceEditError> {
        guard let current = workspace(id: id) else { return .failure(.notFound) }
        workspaces.removeAll { $0.id == id }
        return .success(current)
    }

    private mutating func put(_ workspace: Workspace) {
        var updated = workspaces.filter { $0.id != workspace.id }
        updated.append(workspace)
        workspaces = Self.sorted(updated)
    }

    private static func sorted(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}
