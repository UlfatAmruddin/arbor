import AppKit
import ArborCore

/// Finder custom icons on ordinary files, which per-type lookup (DEC-performance-3) used to drop. Only on-screen
/// rows ask; each file is checked once in the background. Bounded by `maxAge` and `capacity`.
final class CustomIcons {
    static let shared = CustomIcons()
    /// Posted (coalesced) on main when custom icons were found.
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

    /// Nil if none or not known yet (a check is then scheduled). Main thread only.
    func icon(for url: URL) -> NSImage? {
        guard Thread.isMainThread else { return nil }
        let path = url.path
        let entry = entries[path]
        if entry == nil || Date().timeIntervalSince(entry!.checked) > Self.maxAge { schedule(path) }
        return entry?.icon
    }

    /// For scripted checks: files checked, with a custom icon, waiting.
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
    func reloadVisibleIcons() {
        let rows = table.rows(in: table.visibleRect)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard rows.length > 0, column >= 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)),
                         columnIndexes: [column])
    }
}
