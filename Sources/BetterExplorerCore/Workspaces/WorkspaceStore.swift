import Foundation

/// Owns the saved workspaces in memory and is the only writer of Workspaces.json. Use on the main thread.
public final class WorkspaceStore {
    public private(set) var list = WorkspaceList()
    public private(set) var isLoaded = false
    public private(set) var issue: WorkspaceLoad.Issue?
    /// Called on the callback queue when a write fails; memory keeps the change and the next edit rewrites the file.
    public var onWriteFailure: (() -> Void)?

    private let fileURL: URL?
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private var loadStarted = false

    /// A nil `fileURL` keeps the list in memory only (headless runs without a state folder).
    public init(fileURL: URL?, queue: DispatchQueue, callbackQueue: DispatchQueue = .main) {
        self.fileURL = fileURL
        self.queue = queue
        self.callbackQueue = callbackQueue
    }

    public var isReadOnly: Bool { issue?.isReadOnly ?? false }

    public var canEdit: Bool { isLoaded && !isReadOnly }

    /// Reads once, in order with writes on the same queue.
    public func loadIfNeeded(completion: (() -> Void)? = nil) {
        guard !loadStarted else { return }
        loadStarted = true
        guard let fileURL else {
            isLoaded = true
            completion?()
            return
        }
        queue.async { [callbackQueue] in
            let load = WorkspaceFile.load(at: fileURL)
            callbackQueue.async { [weak self] in
                self?.list = load.list
                self?.issue = load.issue
                self?.isLoaded = true
                completion?()
            }
        }
    }

    public func save(name: String, tabs: [SessionTab], activeTab: Int) -> Result<Workspace, WorkspaceEditError> {
        commit { $0.save(name: name, tabs: tabs, activeTab: activeTab) }
    }

    public func rename(id: String, to name: String) -> Result<Workspace, WorkspaceEditError> {
        commit { $0.rename(id: id, to: name) }
    }

    public func delete(id: String) -> Result<Workspace, WorkspaceEditError> {
        commit { $0.delete(id: id) }
    }

    /// Waits for queued writes (at exit).
    public func flush() { queue.sync {} }

    /// The single path every change takes: refused while read-only, and before memory changes if it can't be stored.
    private func commit(_ edit: (inout WorkspaceList) -> Result<Workspace, WorkspaceEditError>) -> Result<Workspace, WorkspaceEditError> {
        guard canEdit else { return .failure(.readOnly) }
        var draft = list
        let result = edit(&draft)
        guard case .success = result else { return result }
        guard let data = WorkspaceFile.encoded(draft) else { return .failure(.tooLarge) }
        list = draft
        write(data)
        return result
    }

    private func write(_ data: Data) {
        guard let fileURL else { return }
        queue.async { [callbackQueue] in
            do {
                try FolderViewStore.write(data, to: fileURL)
            } catch {
                callbackQueue.async { [weak self] in self?.onWriteFailure?() }
            }
        }
    }
}
