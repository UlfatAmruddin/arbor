import AppKit
import ArborCore

/// "Verify after copying" (FE-130): reads copies back and compares size and SHA-256 (`CopyVerifier`),
/// reported as its own state. Off by default. Moves aren't verified: the originals are gone. Main thread, except the pass.
enum JobVerification {
    private static var requested: [UUID: Bool] = [:]
    private static var running: [UUID: (done: Int64, total: Int64)] = [:]
    private(set) static var results: [UUID: VerificationResult] = [:]

    static func isRequested(_ job: OperationCenter.Job) -> Bool {
        requested[job.id] ?? (job.transfer.kind == .copy && Prefs.fileOpsVerifyByDefault)
    }

    /// The choice can change until the copy has finished.
    static func canChange(_ job: OperationCenter.Job) -> Bool {
        job.transfer.kind == .copy && running[job.id] == nil && job.progress.phase != .finishing && !job.transfer.isCancelled
    }

    static func setRequested(_ job: OperationCenter.Job, _ on: Bool) {
        guard canChange(job) else { return }
        requested[job.id] = on
        OperationCenter.shared.post()
    }

    static func progress(_ job: OperationCenter.Job) -> (done: Int64, total: Int64)? { running[job.id] }

    static func install() {
        OperationCenter.afterRun.provide("file-operations-extras.verify-after-copy") { job, report in await verify(job, report) }
    }

    /// Runs on the job's task, between the copy and its report.
    private static func verify(_ job: OperationCenter.Job, _ report: TransferReport) async {
        let wanted = await MainActor.run { isRequested(job) }
        guard wanted, report.kind == .copy, !report.wasCancelled else { return }
        let (pairs, excluded) = CopyVerifier.pairs(for: report)
        guard !pairs.isEmpty else { return }
        let total = max(job.transfer.currentProgress.bytesTotal ?? 0, 1)
        await MainActor.run {
            running[job.id] = (0, total)
            OperationCenter.shared.post()
        }
        let control = job.transfer.control
        // `ARBOR_VERIFY_THROTTLE` (bytes/s) slows headless runs so scripts can photograph "Verifying copies…".
        let throttle = AppDelegate.isHeadless ? Automation.environment["ARBOR_VERIFY_THROTTLE"].flatMap(Double.init) : nil
        // Own thread: hashing large files must not hold a shared executor thread.
        let result: VerificationResult = await withCheckedContinuation { continuation in
            let thread = Thread {
                var last = Date.distantPast
                var previous: Int64 = 0
                let result = CopyVerifier.verify(pairs, excluding: excluded, control: control) { done in
                    if let throttle, throttle > 0 { Thread.sleep(forTimeInterval: Double(done - previous) / throttle) }
                    previous = done
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    DispatchQueue.main.async {
                        running[job.id] = (done, total)
                        OperationCenter.shared.post()
                    }
                }
                continuation.resume(returning: result)
            }
            thread.name = "Arbor verify job"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        await MainActor.run {
            running[job.id] = nil
            results[job.id] = result
            OperationCenter.shared.post()
        }
    }

    /// After the job's report: a status-bar line if copies matched, else an alert listing the mismatches.
    static func report(_ job: OperationCenter.Job) {
        guard let result = results.removeValue(forKey: job.id) else { requested[job.id] = nil; return }
        requested[job.id] = nil
        let window = job.window
        DispatchQueue.main.async {
            if result.cancelled {
                BrowserWindowController.active?.statusBar.setMessage(L10n.tr("Verification was cancelled. The copies weren't checked completely."))
                return
            }
            if result.failures.isEmpty {
                BrowserWindowController.active?.statusBar.setMessage(
                    L10n.plural(one: "Verified: %lld file matches its original (size and SHA-256).", other: "Verified: %lld files match their originals (size and SHA-256).", result.filesChecked))
                return
            }
            let lines = result.failures.prefix(8).map { "• " + L10n.format("%@: %@", URL(fileURLWithPath: $0.path).lastPathComponent, $0.reason) }
            let more = result.failures.count > 8 ? "\n" + L10n.format("…and %d more (see Operation history).", result.failures.count - 8) : ""
            let message = L10n.plural(one: "%lld copy doesn't match its original.", other: "%lld copies don't match their originals.", result.failures.count)
            if AppDelegate.isHeadless {
                lastAlert = message + "\n" + lines.joined(separator: "\n")
                return
            }
            NSAlert.show(message, L10n.tr("Verification read each copy back and compared it with the original. The copies were kept; copy these files again or check the destination drive.") + "\n\n"
                + lines.joined(separator: "\n") + more, in: window)
        }
    }

    /// Headless runs record the alert instead of showing it.
    static var lastAlert: String?

    static func historyEntry(_ job: OperationCenter.Job) -> OperationRecord.Verification? {
        results[job.id].map(OperationRecord.Verification.init)
    }
}
