import AppKit

/// Shared selection look: accent tint while the list has focus in the active window, else `Theme.selectionInactive`.
/// Headless runs have no key window, so they count as active unless a script sets `windowactive:0`.
enum SelectionEmphasis {
    /// Posted when a script changes `headlessWindowActive`.
    static let changed = Notification.Name("ArborSelectionEmphasisChanged")

    static var headlessWindowActive = true {
        didSet {
            guard headlessWindowActive != oldValue else { return }
            NotificationCenter.default.post(name: changed, object: nil)
            for window in NSApp.windows { window.contentView.map(redrawTree) }
        }
    }

    static func windowIsActive(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return AppDelegate.isHeadless ? headlessWindowActive : window.isKeyWindow
    }

    /// `view` or a subview (e.g. a rename field) has focus in the active window.
    static func hasFocus(_ view: NSView) -> Bool {
        guard let window = view.window, windowIsActive(window) else { return false }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// Navigation pane location while the window is inactive.
    static let navInactive = Theme.overlay(lightAlpha: 0.05, darkAlpha: 0.06)
    /// Accent marks (navigation pane bar, Gallery selection ring) while the window is inactive.
    static let inactiveMark = Theme.dynamic(light: 0x9A9A9A, dark: 0x7A7A7A)

    /// Fill for a selected item.
    static func fill(focused: Bool, hovered: Bool) -> NSColor {
        focused ? (hovered ? Theme.selectionHover : Theme.selection) : Theme.selectionInactive
    }

    /// Calls `onChange` whenever the window's active state may have changed.
    final class Observer {
        private var tokens: [NSObjectProtocol] = []
        private let onChange: () -> Void

        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

        func attach(to window: NSWindow?) {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: SelectionEmphasis.changed, object: nil, queue: .main) { [weak self] _ in self?.onChange() })
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.onChange() })
            }
        }
    }

    private static func redrawTree(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redrawTree)
    }
}
