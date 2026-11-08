import AppKit
import ArborCore

/// Cache trimming under memory pressure, the stall monitor and benchmark steps
/// (spec §15.3–§15.4, FE-228, FE-243, FE-251, FE-252; docs/PERFORMANCE.md).
enum PerformanceFeature: ExplorerFeature {
    static let id = "performance"
    static func register() {
        PerformanceCaches.register()
        CustomIcons.install()
        DebugScript.registerLogger("performance.log") { _ in "custom icons: " + CustomIcons.shared.debugText }
        let environment = Automation.environment
        #if DEBUG
        let monitor = true
        #else
        let monitor = environment["ARBOR_SCRIPT"] != nil || environment["ARBOR_STALL_LOG"] != nil
        #endif
        if monitor { StallMonitor.shared.start(logPath: environment["ARBOR_STALL_LOG"]) }
        LaunchTimer.install()
        PerformanceDebug.register()
    }
}

/// Records main run-loop passes over 50 ms, labelled with the script step (or "app"). Two timestamps per pass.
final class StallMonitor {
    static let shared = StallMonitor()
    let recorder = StallRecorder(thresholdMilliseconds: 50)
    /// Workload name set by benchmark scripts (`phase:` step); prefixes stall labels.
    var phase = ""
    private var observer: CFRunLoopObserver?
    private var busySince: CFAbsoluteTime?
    private var log: FileHandle?
    /// Run-loop passes after waiting; reported by the idle benchmark.
    private(set) var wakeups = 0

    var isRunning: Bool { observer != nil }

    func start(logPath: String?) {
        guard observer == nil else { return }
        if let logPath {
            if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
            log = FileHandle(forWritingAtPath: logPath)
            log?.seekToEndOfFile()
        }
        recorder.ignoredLabels = ["snapshot", "log:", "memlog"]
        let activities: CFRunLoopActivity = [.entry, .afterWaiting, .beforeWaiting, .exit]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [weak self] _, activity in
            self?.note(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        switch activity {
        case .entry, .afterWaiting:
            busySince = now
            if activity == .afterWaiting { wakeups += 1 }
        case .beforeWaiting, .exit:
            guard let start = busySince else { return }
            busySince = nil
            let ms = (now - start) * 1000
            // Runs on every pass: bail out before building any text.
            guard ms > recorder.thresholdMilliseconds else { return }
            let label = (phase.isEmpty ? "" : phase + "/") + (DebugScript.currentStep.isEmpty ? "app" : DebugScript.currentStep)
            if recorder.record(milliseconds: ms, label: label) {
                let line = String(format: "stall %.0fms during %@", ms, label)
                if let log { log.write(Data((line + "\n").utf8)) }
                #if DEBUG
                if log == nil, DebugScript.currentStep.isEmpty { NSLog("Arbor: main thread %@", line) }
                #endif
            }
        default:
            break
        }
    }
}

/// Time from process start to the first location drawn in a window ("time to useful UI", §15.4).
enum LaunchTimer {
    private(set) static var firstContentSeconds: Double?

    static func install() {
        WindowHooks.willDisplay.observe("performance.first-content") { controller, _, _, _ in
            guard firstContentSeconds == nil else { return }
            firstContentSeconds = 0
            // After this pass's layout and drawing.
            DispatchQueue.main.async {
                controller.window?.displayIfNeeded()
                firstContentSeconds = ProcessMetrics.secondsSinceLaunch()
            }
        }
    }
}
