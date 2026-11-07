import Foundation

/// Runs blocking work (a listing on a network share that may hang) off the caller's thread with a
/// deadline (FE-179). The caller hears back exactly once, with the result or `.timedOut`; a result
/// that arrives after the deadline goes to `late` so the UI can still use it. Requests for the same
/// key share one in-flight job, so pressing Retry on a hung share never piles up blocked threads.
public final class SlowWorkQueue<Value>: @unchecked Sendable {
    public enum Outcome {
        case finished(Value)
        case timedOut
    }

    private struct Waiter {
        let id: UUID
        let completion: (Outcome) -> Void
        var answered: Bool
        var timedOut = false
    }

    private struct Job {
        var waiters: [Waiter]
        var late: [(Value) -> Void]
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    public init(label: String, callbackQueue: DispatchQueue = .main) {
        workQueue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.callbackQueue = callbackQueue
    }

    /// Number of distinct jobs still running (for tests and diagnostics).
    public var inFlightCount: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.count
    }

    /// Returns a token; pass it to `cancel` to stop hearing back (the work itself can't be interrupted).
    @discardableResult
    public func run(key: String, timeout: TimeInterval, work: @escaping () -> Value,
                    late: ((Value) -> Void)? = nil, completion: @escaping (Outcome) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let isNew = jobs[key] == nil
        var job = jobs[key] ?? Job(waiters: [], late: [])
        job.waiters.append(Waiter(id: id, completion: completion, answered: false))
        if let late { job.late.append(late) }
        jobs[key] = job
        lock.unlock()

        callbackQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire(key: key, id: id) }
        if isNew {
            workQueue.async { [weak self] in
                let value = work()
                self?.callbackQueue.async { self?.finish(key: key, value: value) }
            }
        }
        return id
    }

    public func cancel(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        for (key, var job) in jobs {
            guard let index = job.waiters.firstIndex(where: { $0.id == id }) else { continue }
            job.waiters[index].answered = true
            jobs[key] = job
        }
    }

    private func expire(key: String, id: UUID) {
        lock.lock()
        guard var job = jobs[key], let index = job.waiters.firstIndex(where: { $0.id == id }), !job.waiters[index].answered else {
            lock.unlock(); return
        }
        job.waiters[index].answered = true
        job.waiters[index].timedOut = true
        let completion = job.waiters[index].completion
        jobs[key] = job
        lock.unlock()
        completion(.timedOut)
    }

    private func finish(key: String, value: Value) {
        lock.lock()
        let job = jobs.removeValue(forKey: key)
        lock.unlock()
        guard let job else { return }
        let pending = job.waiters.filter { !$0.answered }
        pending.forEach { $0.completion(.finished(value)) }
        // Someone timed out earlier: offer them the late result.
        if job.waiters.contains(where: \.timedOut) { job.late.forEach { $0(value) } }
    }
}
