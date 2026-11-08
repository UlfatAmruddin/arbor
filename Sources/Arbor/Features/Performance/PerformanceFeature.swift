import AppKit
import ArborCore

/// Memory and responsiveness plumbing (spec §15.3–§15.4, FE-228, FE-243, FE-251, FE-252): one
/// memory-pressure listener that trims every registered cache, the main-thread stall monitor, and the
/// benchmark script steps (PerformanceDebug.swift). See docs/PERFORMANCE.md.
enum PerformanceFeature: ExplorerFeature {
    static let id = "performance"
    static func register() {
        PerformanceCaches.register()
        CustomIcons.install()
        DebugScript.registerLogger("performance.log") { _ in "custom icons: " + CustomIcons.shared.debugText }
        let environment = ProcessInfo.processInfo.environment
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

/// Watches the main run loop and records every pass that kept the main thread busy for more than
/// 50 ms, labelled with the running script step (or "app"). Costs two timestamps per run-loop pass.
final class StallMonitor {
    static let shared = StallMonitor()
    let recorder = StallRecorder(thresholdMilliseconds: 50)
    /// Workload name set by benchmark scripts (`phase:` step); prefixes stall labels.
    var phase = ""
    private var observer: CFRunLoopObserver?
    private var busySince: CFAbsoluteTime?
    private var log: FileHandle?

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
        case .beforeWaiting, .exit:
            guard let start = busySince else { return }
            busySince = nil
            let ms = (now - start) * 1000
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
