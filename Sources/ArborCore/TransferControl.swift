import Foundation

/// Cancel and pause for one job, shared between the UI and the job's worker thread.
///
/// What pausing means (FE-115, FE-257): the worker blocks at its next checkpoint, which is
/// between files and between data chunks inside a file (copyfile reports roughly every 1 MB).
/// The open file stays open and the copy continues from the same byte offset on resume.
/// A same-volume move (a rename) or an APFS clone is instant and can't be paused halfway.
/// Pausing lasts only while the app runs; quitting cancels, and the journal records the rest.
public final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false
    /// Called (on the thread that changed it) after pause/resume/cancel.
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
