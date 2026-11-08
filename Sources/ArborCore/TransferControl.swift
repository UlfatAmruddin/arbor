import Foundation

/// Cancel and pause for one job, shared by the UI and the worker thread (FE-115, FE-257).
/// Pausing blocks at the next checkpoint (between files or ~1 MB copyfile chunks) and resumes at the same
/// offset; renames and APFS clones can't pause halfway. Quitting cancels; the journal records the rest.
public final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false
    /// Called on the changing thread after pause/resume/cancel.
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool { condition.withLock { cancelled } }
    public var isPaused: Bool { condition.withLock { paused && !cancelled } }

    public func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
        onChange?()
    }

    public func pause() {
        let changed = condition.withLock { () -> Bool in
            guard !paused, !cancelled else { return false }
            paused = true
            return true
        }
        if changed { onChange?() }
    }

    public func resume() {
        let changed = condition.withLock { () -> Bool in
            guard paused else { return false }
            paused = false
            condition.broadcast()
            return true
        }
        if changed { onChange?() }
    }

    /// Blocks while paused. Returns false once the job is cancelled.
    @discardableResult
    public func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }

    /// Sleeps up to `seconds`, waking early on cancel. Returns false if cancelled.
    func sleep(_ seconds: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !cancelled { _ = condition.wait(until: Date().addingTimeInterval(seconds)) }
        return !cancelled
    }
}
