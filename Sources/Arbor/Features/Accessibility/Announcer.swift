import AppKit
import ArborCore

/// VoiceOver announcements (FE-200, spec §16.2): the new location, selection counts (throttled), status
/// bar outcomes (job completed, errors) and keyboard region changes. Progress and thumbnails are never
/// announced. Every announcement is also kept in `recent` for scripted checks.
enum Announcer {
    private(set) static var recent: [String] = []
    private static var selectionThrottle = AnnouncementThrottle(interval: 0.8)
    private static var pendingSelection: DispatchWorkItem?
    private static var lastSelectionCount: [ObjectIdentifier: Int] = [:]

    static func install() {
        WindowHooks.willDisplay.append { c, tab, location, changed in
            guard changed, tab === c.activeTab else { return }
            let title = LocationRegistry.provider(for: location).title(for: location)
            DispatchQueue.main.async { [weak c] in
                guard let c else { return }
                announce(AnnouncementText.location(title, itemCount: c.activeTab.showsPage ? nil : c.visibleItems.count),
                         in: c.window, priority: .medium)
                lastSelectionCount[ObjectIdentifier(c)] = c.selectedItems.count
            }
        }
        WindowHooks.selectionChanged.append { c in selectionChanged(c) }
        StatusBarView.messageHooks.append { bar, text, isError in
            guard AnnouncementText.shouldSpeakStatus(text), let text else { return }
            announce(text, in: bar.window, priority: isError ? .high : .medium)
        }
    }

    static func selectionChanged(_ c: BrowserWindowController) {
        if let grid = c.itemView?.focusView as? ItemGridView { ItemGridAccessibility.selectionChanged(grid) }
        let key = ObjectIdentifier(c)
        let count = c.selectedItems.count
        let previous = lastSelectionCount[key] ?? 0
        lastSelectionCount[key] = count
        guard let text = AnnouncementText.selection(count: count, previous: previous) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch selectionThrottle.submit(text, at: now) {
        case .now:
            announce(text, in: c.window, priority: .low)
        case .after(let delay):
            pendingSelection?.cancel()
            let work = DispatchWorkItem { [weak c] in
                guard let c else { return }
                // Speak the count as it is when the burst settles.
                let settled = c.selectedItems.count
                guard let latest = AnnouncementText.selection(count: settled, previous: 0) else { return }
                selectionThrottle.spoke(latest, at: ProcessInfo.processInfo.systemUptime)
                announce(latest, in: c.window, priority: .low)
            }
            pendingSelection = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .skip:
            break
        }
    }

    static func focusMoved(to region: FocusRegion, in c: BrowserWindowController) {
        // VoiceOver reads the newly focused element itself; the region name gives the context.
        announce(L10n.tr(region.title), in: c.window, priority: .low)
    }

    static func announce(_ text: String, in window: NSWindow?, priority: NSAccessibilityPriorityLevel) {
        recent.append(text)
        if recent.count > 30 { recent.removeFirst(recent.count - 30) }
        let element: Any = window ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }
}
