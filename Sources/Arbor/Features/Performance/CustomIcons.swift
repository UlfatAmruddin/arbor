import AppKit
import ArborCore

/// Custom Finder icons on ordinary files (a picture pasted onto a document in Get Info). File icons are looked
/// up per type for speed (DEC-performance-3), which used to drop these. Now each file whose icon is drawn is
/// checked once, in the background, for Finder's custom-icon flag; only files that have it get their own icon
/// (also read in the background), and the lists redraw. Only rows on screen ask, so a 100,000-item folder
/// costs a few dozen checks, not a scan. Results are kept for `maxAge` and at most `capacity` files.
final class CustomIcons {
    static let shared = CustomIcons()
    /// Posted (coalesced) on the main queue when custom icons were found; lists redraw their icons.
    static let found = Notification.Name("ArborCustomIconsFound")

    static let capacity = 4_096
    static let maxPending = 256
    static let maxAge: TimeInterval = 30

    private struct Entry {
        let icon: NSImage?
        let checked: Date
    }

    private var entries: [String: Entry] = [:]
    private var pending = Set<String>()
    private var notifyScheduled = false
    private let queue = DispatchQueue(label: "Arbor custom icons", qos: .utility)

    /// The file's custom icon if it has one; nil when it doesn't or isn't known yet (a check is scheduled).
    /// Main thread only.
    func icon(for url: URL) -> NSImage? {
        guard Thread.isMainThread else { return nil }
        let path = url.path
        let entry = entries[path]
        if entry == nil || Date().timeIntervalSince(entry!.checked) > Self.maxAge { schedule(path) }
        return entry?.icon
    }

    /// Checks done so far (scripted checks): files checked, files with a custom icon, checks waiting.
    var debugText: String {
        "checked=\(entries.count) custom=\(entries.values.filter { $0.icon != nil }.count) pending=\(pending.count)"
    }

    private func schedule(_ path: String) {
        guard !pending.contains(path), pending.count < Self.maxPending else { return }
        pending.insert(path)
        queue.async { [weak self] in
            // NSWorkspace icons may be made off the main thread; only flagged files pay for it.
            let icon = FinderInfo.hasCustomIcon(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
            DispatchQueue.main.async { self?.store(path, icon) }
        }
    }

    private func store(_ path: String, _ icon: NSImage?) {
        pending.remove(path)
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        let changed = (entries[path]?.icon != nil) != (icon != nil)
        entries[path] = Entry(icon: icon, checked: Date())
        guard changed, !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.notifyScheduled = false
            NotificationCenter.default.post(name: Self.found, object: nil)
        }
    }
}

extension CustomIcons {
    /// Redraws the icons of every open list when custom icons turn up.
    static func install() {
        NotificationCenter.default.addObserver(forName: found, object: nil, queue: .main) { _ in
            for controller in (NSApp.delegate as? AppDelegate)?.controllers ?? [] {
                if let details = controller.itemView as? DetailsViewController {
                    details.reloadVisibleIcons()
                } else if let view = controller.itemView?.view {
                    redraw(view)
                }
            }
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}

extension DetailsViewController {
    /// Re-fetches the icons of the rows on screen.
    func reloadVisibleIcons() {
        let rows = table.rows(in: table.visibleRect)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard rows.length > 0, column >= 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)),
                         columnIndexes: [column])
    }
}
