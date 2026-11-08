import AppKit
import ArborCore

/// Benchmark steps for `ARBOR_SCRIPT` (driven by scripts/bench.sh; docs/PERFORMANCE.md). Every step
/// that writes appends one `key=value` line to the file it is given, so the script can parse results:
///
///     phase:browse                       label stalls and results with a workload name
///     memlog:label:/out                  footprint, peak, resident, caches, tabs, windows
///     mark:name / elapsed:name:label:/out   wall time between two points
///     nav:label:/out:<location>          navigate the active tab; wait until it is drawn; log the time
///     newtabnav:label:/out:<location>    same in a new tab
///     waitload                           wait until the active tab's last request is on screen
///     timecmd:label:/out:<command id>    perform a command synchronously (sort…) and draw; log the time
///     scroll:label:/out:<pages>          scroll the item view page by page, drawing each; log frame times
///     idle:label:/out:<seconds>          CPU used while idle
///     copy:label:/out:<source>|<folder>  copy and wait for the job; log time and peak footprint
///     thumbwait                          wait until thumbnail generation settles
///     selectcycle:label:/out:<count>:<seconds>   select the first N files one by one (preview churn)
///     searchchurn:label:/out:<count>:<final>     type N changing queries, then the final one; check results
///     newwindow:<location> / closewindow / closeothertabs
///     stalls:label:/out                  log stalls since the last `stalls:` (and reset them)
///     launchlog:/out                     time from process start to the first drawn location
enum PerformanceDebug {
    /// Tab id → load token of the last request that reached the screen.
    private static var displayedToken: [UUID: UUID] = [:]
    private static var marks: [String: CFAbsoluteTime] = [:]
    private static var waitState: [String: Any] = [:]
    private static var volumeEvents = 0

    static func register() {
        guard ProcessInfo.processInfo.environment["ARBOR_SCRIPT"] != nil else { return }
        WindowHooks.willDisplay.observe("performance.displayed-token") { _, tab, _, _ in displayedToken[tab.id] = tab.loadToken }
        // Disks mounted by other software wake the app; the idle figure says how many arrived.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            _ = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in volumeEvents += 1 }
        }

        DebugScript.registerStep("phase") { arg, _ in StallMonitor.shared.phase = arg; return 0 }
        DebugScript.registerStep("memlog") { arg, window in
            let (label, path) = split(arg)
            append("mem \(label) \(memoryLine(window))", to: path)
            return 0
        }
        DebugScript.registerStep("mark") { arg, _ in marks[arg] = CFAbsoluteTimeGetCurrent(); return 0 }
        DebugScript.registerStep("elapsed") { arg, _ in
            let (name, rest) = split(arg)
            let (label, path) = split(rest)
            let start = marks[name] ?? CFAbsoluteTimeGetCurrent()
            append(String(format: "time %@ ms=%.1f", label, (CFAbsoluteTimeGetCurrent() - start) * 1000), to: path)
            return 0
        }
        DebugScript.registerStep("launchlog") { arg, _ in
            append(String(format: "launch first_content_ms=%.0f", (LaunchTimer.firstContentSeconds ?? 0) * 1000), to: arg)
            return 0
        }
        DebugScript.registerStep("stalls") { arg, _ in
            let (label, path) = split(arg)
            let recorder = StallMonitor.shared.recorder
            append("stalls \(label) \(recorder.summary())", to: path)
            for stall in recorder.stalls().sorted(by: { $0.milliseconds > $1.milliseconds }).prefix(5) {
                append(String(format: "stall %@ ms=%.0f during=%@", label, stall.milliseconds,
                              stall.label.replacingOccurrences(of: " ", with: "_")), to: path)
            }
            recorder.reset()
            return 0
        }
        // timecmd:label:/path:command — time until the command's result is on screen; a sort that runs in the
        // background (FE-228) is waited for, and the main thread's own share is logged as `main_ms`.
        DebugScript.registerWaitStep("timecmd") { arg, window, elapsed in
            let (label, rest) = split(arg)
            let (path, command) = split(rest)
            guard let window else { return true }
            if elapsed == 0 {
                let start = CFAbsoluteTimeGetCurrent()
                window.perform(command)
                window.window?.displayIfNeeded()
                waitState["timecmd.start"] = start
                waitState["timecmd.main"] = CFAbsoluteTimeGetCurrent() - start
                if window.activeTab.isSorting { return false }
            } else if window.activeTab.isSorting, elapsed < 30 {
                return false
            }
            window.window?.displayIfNeeded()
            let start = waitState["timecmd.start"] as? CFAbsoluteTime ?? CFAbsoluteTimeGetCurrent()
            let main = waitState["timecmd.main"] as? CFAbsoluteTime ?? 0
            append(String(format: "time %@ ms=%.1f main_ms=%.1f", label, (CFAbsoluteTimeGetCurrent() - start) * 1000, main * 1000), to: path)
            return true
        }
        DebugScript.registerStep("newwindow") { arg, _ in
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.openWindow(at: DebugScript.parseLocation(arg) ?? WindowHooks.startLocation.value())
            }
            return 0
        }
        DebugScript.registerStep("closewindow") { _, window in
            window?.window?.close()
            return 0.2
        }
        DebugScript.registerStep("closeothertabs") { _, window in
            if let window { window.closeOtherTabs(except: window.activeIndex) }
            return 0.2
        }

        DebugScript.registerWaitStep("waitload") { _, window, elapsed in
            guard let window else { return true }
            return isShown(window.activeTab) || elapsed > 60
        }
        DebugScript.registerWaitStep("nav") { arg, window, elapsed in
            navigateAndTime(arg, window: window, elapsed: elapsed) { window, location in window.navigate(to: location) }
        }
        DebugScript.registerWaitStep("newtabnav") { arg, window, elapsed in
            navigateAndTime(arg, window: window, elapsed: elapsed) { window, location in window.openTab(location) }
        }
        DebugScript.registerWaitStep("scroll") { arg, window, elapsed in scroll(arg, window: window, first: elapsed == 0) }
        // A plain step that pauses the script itself: a polling wait step would wake the app 200 times a
        // second and measure its own polling.
        DebugScript.registerStep("idle") { arg, _ in
            let (label, rest) = split(arg)
            let (path, secondsText) = split(rest)
            let seconds = Double(secondsText) ?? 5
            let profiler = IdleProfiler.isRequested ? IdleProfiler() : nil
            profiler?.start()
            let cpu = ProcessMetrics.current().cpuSeconds
            let volumes = volumeEvents
            let wakeups = StallMonitor.shared.wakeups
            let start = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let report = profiler?.stop()
                // The profiler's own thread is not part of what the app does while idle.
                let used = ProcessMetrics.current().cpuSeconds - cpu - (report?.profilerCPU ?? 0)
                append(String(format: "idle %@ cpu_ms_per_s=%.2f seconds=%.1f volume_events=%d main_wakeups_per_s=%.1f", label,
                              used * 1000 / elapsed, elapsed, volumeEvents - volumes,
                              Double(StallMonitor.shared.wakeups - wakeups) / elapsed), to: path)
                for line in report?.lines ?? [] { append(line, to: path) }
            }
            return seconds + 0.05
        }
        DebugScript.registerWaitStep("copy") { arg, window, elapsed in copy(arg, window: window, elapsed: elapsed) }
        DebugScript.registerWaitStep("thumbwait") { _, _, elapsed in
            let service = ThumbnailService.shared
            let progress = service.generated + service.failures
            if elapsed == 0 { waitState["thumb"] = (progress, elapsed); return false }
            let (last, since) = waitState["thumb"] as? (Int, Double) ?? (progress, elapsed)
            if progress != last { waitState["thumb"] = (progress, elapsed); return false }
            return elapsed - since > 0.8 || elapsed > 120
        }
        DebugScript.registerWaitStep("selectcycle") { arg, window, elapsed in selectCycle(arg, window: window, elapsed: elapsed) }
        DebugScript.registerWaitStep("searchchurn") { arg, window, elapsed in searchChurn(arg, window: window, elapsed: elapsed) }
    }

    // MARK: Helpers

    private static func isShown(_ tab: TabState) -> Bool { displayedToken[tab.id] == tab.loadToken }

    private static func split(_ s: String) -> (String, String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    static func memoryLine(_ window: BrowserWindowController?) -> String {
        let m = ProcessMetrics.current()
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        let tabs = controllers.reduce(0) { $0 + $1.tabs.count }
        let listed = controllers.flatMap(\.tabs).reduce(0) { $0 + ($1.items?.count ?? 0) }
        var line = "footprint_mb=\(ProcessMetrics.megabytes(m.footprint)) peak_mb=\(ProcessMetrics.megabytes(m.peakFootprint))"
            + " resident_mb=\(ProcessMetrics.megabytes(m.resident)) windows=\(controllers.count) tabs=\(tabs) listed_rows=\(listed)"
            + String(format: " cpu_s=%.2f", m.cpuSeconds)
        for entry in CacheRegistry.shared.entries {
            line += " cache_\(entry.name)_mb=\(ProcessMetrics.megabytes(UInt64(max(0, entry.bytes()))))"
        }
        line += " searches=\(SearchSessions.debugSummary.isEmpty ? "-" : SearchSessions.debugSummary.replacingOccurrences(of: " ", with: "_"))"
        return extraMemoryFields.apply(line)
    }

    /// More `key=value` fields for `memlog` (cache sizes): each contribution appends " key=value".
    static let extraMemoryFields = Pipeline<String, Void>(
        "PerformanceDebug.extraMemoryFields", "More key=value fields for the memlog script step.", signature: "(line) -> line")

    static func append(_ line: String, to path: String) {
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Navigation timing

    private static func navigateAndTime(_ arg: String, window: BrowserWindowController?, elapsed: TimeInterval,
                                        go: (BrowserWindowController, Location) -> Void) -> Bool {
        let (label, rest) = split(arg)
        let (path, target) = split(rest)
        guard let window else { return true }
        if elapsed == 0 {
            guard let location = DebugScript.parseLocation(target) else {
                append("time \(label) error=bad_location", to: path)
                return true
            }
            waitState["nav.start"] = CFAbsoluteTimeGetCurrent()
            go(window, location)
            return false
        }
        let current = BrowserWindowController.active ?? window
        guard isShown(current.activeTab) else {
            if elapsed > 120 { append("time \(label) error=timeout", to: path); return true }
            return false
        }
        current.window?.displayIfNeeded()
        let start = waitState["nav.start"] as? CFAbsoluteTime ?? CFAbsoluteTimeGetCurrent()
        append(String(format: "time %@ ms=%.1f rows=%d", label, (CFAbsoluteTimeGetCurrent() - start) * 1000,
                      current.visibleItems.count), to: path)
        return true
    }

    // MARK: Scrolling

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.hasVerticalScroller { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    /// One page per poll; each page's scroll + layout + draw time is a frame.
    private static func scroll(_ arg: String, window: BrowserWindowController?, first: Bool) -> Bool {
        let (label, rest) = split(arg)
        let (path, pagesText) = split(rest)
        let pages = Int(pagesText) ?? 50
        guard let window, let host = window.itemView?.view, let scroll = scrollView(in: host),
              let document = scroll.documentView else {
            append("scroll \(label) error=no_scroll_view", to: path)
            return true
        }
        if first {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            waitState["scroll.frames"] = [Double]()
            return false
        }
        var frames = waitState["scroll.frames"] as? [Double] ?? []
        let clip = scroll.contentView
        let page = clip.bounds.height
        let maxY = max(0, document.frame.height - page)
        let start = CFAbsoluteTimeGetCurrent()
        var origin = clip.bounds.origin
        origin.y = min(maxY, origin.y + page)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        window.window?.displayIfNeeded()
        frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        waitState["scroll.frames"] = frames
        guard frames.count >= pages || origin.y >= maxY else { return false }
        let sorted = frames.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        append(String(format: "scroll %@ frames=%d p50_ms=%.1f p95_ms=%.1f max_ms=%.1f over50=%d", label, frames.count,
                      pct(0.5), pct(0.95), sorted.last ?? 0, frames.filter { $0 > 50 }.count), to: path)
        return true
    }

    // MARK: Copies

    private static func copy(_ arg: String, window: BrowserWindowController?, elapsed: TimeInterval) -> Bool {
        let (label, rest) = split(arg)
        let (path, pair) = split(rest)
        let parts = pair.components(separatedBy: "|")
        guard let window, parts.count == 2 else { return true }
        let footprint = ProcessMetrics.current().footprint
        if elapsed == 0 {
            waitState["copy.start"] = CFAbsoluteTimeGetCurrent()
            waitState["copy.base"] = footprint
            waitState["copy.peak"] = footprint
            window.startTransfer(.copy, [URL(fileURLWithPath: parts[0])], to: URL(fileURLWithPath: parts[1]), preflighted: true)
            return false
        }
        waitState["copy.peak"] = max(footprint, waitState["copy.peak"] as? UInt64 ?? 0)
        guard !OperationCenter.shared.hasActiveJobs || elapsed > 590 else { return false }
        let base = waitState["copy.base"] as? UInt64 ?? 0
        let peak = waitState["copy.peak"] as? UInt64 ?? 0
        let start = waitState["copy.start"] as? CFAbsoluteTime ?? 0
        append(String(format: "copy %@ ms=%.0f peak_delta_mb=%@ end_delta_mb=%@", label, (CFAbsoluteTimeGetCurrent() - start) * 1000,
                      ProcessMetrics.megabytes(peak > base ? peak - base : 0),
                      ProcessMetrics.megabytes(footprint > base ? footprint - base : 0)), to: path)
        return true
    }

    // MARK: Preview churn

    private static func selectCycle(_ arg: String, window: BrowserWindowController?, elapsed: TimeInterval) -> Bool {
        let (label, rest) = split(arg)
        let (path, params) = split(rest)
        let (countText, delayText) = split(params)
        let count = Int(countText) ?? 20
        let delay = Double(delayText) ?? 0.3
        guard let window, let view = window.itemView else { return true }
        let files = window.visibleItems.filter { !$0.isFolder }.prefix(count).map(\.name)
        if elapsed == 0 { waitState["cycle.index"] = 0; waitState["cycle.next"] = 0.0 }
        var index = waitState["cycle.index"] as? Int ?? 0
        let next = waitState["cycle.next"] as? Double ?? 0
        guard elapsed >= next else { return false }
        if index >= files.count {
            append("cycle \(label) selected=\(files.count) \(memoryLine(window))", to: path)
            return true
        }
        view.select(names: [files[index]])
        window.itemViewSelectionDidChange()
        index += 1
        waitState["cycle.index"] = index
        waitState["cycle.next"] = elapsed + delay
        return false
    }

    // MARK: Search churn

    /// Types `count` queries (mostly faster than the typing delay, every fifth slow enough to start a
    /// search that the next one cancels), then `final`; waits for the final search to finish and checks
    /// that every row matches it (no stale results from cancelled searches).
    private static func searchChurn(_ arg: String, window: BrowserWindowController?, elapsed: TimeInterval) -> Bool {
        let (label, rest) = split(arg)
        let (path, params) = split(rest)
        let (countText, final) = split(params)
        let count = Int(countText) ?? 100
        guard let window else { return true }
        func type(_ text: String) {
            window.focusSearch()
            if let editor = window.window?.firstResponder as? NSTextView {
                editor.string = text
                editor.didChangeText()
            }
        }
        if elapsed == 0 {
            waitState["churn.index"] = 0
            waitState["churn.next"] = 0.0
            waitState["churn.finalAt"] = nil
            waitState["churn.first"] = nil
            return false
        }
        var index = waitState["churn.index"] as? Int ?? 0
        let next = waitState["churn.next"] as? Double ?? 0
        if index < count {
            guard elapsed >= next else { return false }
            let words = ["file", "doc", "note", "item", "photo", "data", "log", "report"]
            type(words[index % words.count] + String(index % 7))
            index += 1
            waitState["churn.index"] = index
            waitState["churn.next"] = elapsed + (index % 5 == 0 ? 0.75 : 0.03)
            return false
        }
        if waitState["churn.finalAt"] == nil {
            guard elapsed >= next else { return false }
            type(final)
            waitState["churn.finalAt"] = elapsed
            return false
        }
        let finalAt = waitState["churn.finalAt"] as? Double ?? elapsed
        let current = BrowserWindowController.active ?? window
        guard case .search(let request) = current.location, request.query == final, isShown(current.activeTab) else {
            if elapsed - finalAt > 120 { append("search \(label) error=timeout", to: path); return true }
            return false
        }
        let rows = current.visibleItems
        if waitState["churn.first"] == nil, !rows.isEmpty { waitState["churn.first"] = elapsed }
        if let session = SearchProvider.session(for: current.location), session.isRunning { return false }
        let stale = rows.filter { $0.name.range(of: final, options: .caseInsensitive) == nil }.count
        let first = (waitState["churn.first"] as? Double).map { ($0 - finalAt) * 1000 } ?? -1
        append(String(format: "search %@ queries=%d first_ms=%.0f done_ms=%.0f rows=%d stale=%d %@", label, count + 1, first,
                      (elapsed - finalAt) * 1000, rows.count, stale, memoryLine(current)), to: path)
        return true
    }
}
