import Foundation

/// Which saved tabs can open now; build off the main thread, since parsing keys can touch the disk (DEC-workspaces-2).
public struct WorkspaceOpenPlan: Equatable, Sendable {
    /// What a tab needs on disk. Every other location reports its own availability when shown.
    public enum Requirement: Hashable, Sendable {
        case directory(String)
        case file(String)
    }

    /// A tab that can open, with its key already parsed so the main thread never has to.
    public struct Tab: Equatable, Sendable {
        public let saved: SessionTab
        public let location: Location
    }

    public let tabs: [Tab]
    public let activeIndex: Int
    /// Display names of the places that are gone, safe for plain alert text.
    public let unavailableNames: [String]
    /// Keys this version of Arbor can't parse; they stay in the workspace for a version that can.
    public let unreadableCount: Int

    public init(workspace: Workspace, isAvailable: (Requirement) -> Bool) {
        var unavailable: [String] = []
        var unreadable = 0
        let parsed = workspace.tabs.map { (saved: $0, location: Location(key: $0.location)) }
        let kept = Workspace.filtered(parsed, active: workspace.activeTab) { tab in
            guard let location = tab.location else {
                unreadable += 1
                return false
            }
            guard let (requirement, url) = Self.requirement(of: location), !isAvailable(requirement) else { return true }
            unavailable.append(WorkspaceName.clean(url.lastPathComponent) ?? "…")
            return false
        }
        tabs = kept.items.compactMap { tab in tab.location.map { Tab(saved: tab.saved, location: $0) } }
        activeIndex = kept.active
        unavailableNames = unavailable
        unreadableCount = unreadable
    }

    private static func requirement(of location: Location) -> (Requirement, URL)? {
        switch location {
        case .folder(let url): return (.directory(url.path), url)
        case .archive(let url, _): return (.file(url.path), url)
        default: return nil
        }
    }

    @Sendable public static func existsOnDisk(_ requirement: Requirement) -> Bool {
        var isDirectory: ObjCBool = false
        switch requirement {
        case .directory(let path):
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        case .file(let path):
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }
}

/// Builds open plans off the main thread with a deadline. Use on the main thread.
public final class WorkspaceOpenCheck {
    public typealias Outcome = SlowWorkQueue<WorkspaceOpenPlan>.Outcome

    public static let defaultDeadline: TimeInterval = 2

    private let queue = SlowWorkQueue<WorkspaceOpenPlan>(label: "arbor.workspaces.open-check")
    private let deadline: TimeInterval
    private let isAvailable: @Sendable (WorkspaceOpenPlan.Requirement) -> Bool
    private var latest: UUID?

    public init(deadline: TimeInterval = WorkspaceOpenCheck.defaultDeadline,
                isAvailable: @escaping @Sendable (WorkspaceOpenPlan.Requirement) -> Bool = WorkspaceOpenPlan.existsOnDisk) {
        self.deadline = deadline
        self.isAvailable = isAvailable
    }

    /// An answer is still due.
    public var isRunning: Bool { latest != nil }

    /// Replaces any check still waiting. A retry of the same tabs joins the running job, so a hung share blocks one thread only.
    public func run(_ workspace: Workspace, completion: @escaping (Outcome) -> Void) {
        if let latest { queue.cancel(latest) }
        let key = "\(workspace.id)#\(workspace.activeTab)#\(workspace.tabs.hashValue)"
        latest = queue.run(key: key, timeout: deadline, work: { [isAvailable] in
            WorkspaceOpenPlan(workspace: workspace, isAvailable: isAvailable)
        }, completion: { [weak self] outcome in
            self?.latest = nil
            completion(outcome)
        })
    }
}
