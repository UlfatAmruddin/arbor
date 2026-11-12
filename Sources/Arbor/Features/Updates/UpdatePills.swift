import AppKit
import ArborCore

/// The quiet Update button at the trailing end of every window's tab row (FE-259). Main thread only.
enum UpdatePills {
    static let identifier = NSUserInterfaceItemIdentifier("updates.pill")
    private(set) static var notice: UpdateNotice = .none

    static func install() {
        WindowHooks.didCreate.observe("updates.pill") { show(in: $0) }
    }

    static func apply(_ event: UpdateNotice.Event) {
        notice = notice.after(event)
        (NSApp.delegate as? AppDelegate)?.controllers.forEach(show)
    }

    static func pill(in window: BrowserWindowController) -> ChromeButton? {
        window.tabStrip.trailingAccessory.flatMap { $0.identifier == identifier ? $0 : nil }
    }

    /// Without an update there is no button at all, not a hidden one.
    private static func show(in window: BrowserWindowController) {
        guard case .available(let version) = notice else {
            if pill(in: window) != nil { window.tabStrip.trailingAccessory = nil }
            return
        }
        let button = pill(in: window) ?? makePill()
        let tooltip = version.map { L10n.format("Arbor %@ is available. Click to see what's new and install it.", $0) }
            ?? L10n.tr("A new version of Arbor is available. Click to see what's new and install it.")
        button.toolTip = tooltip
        button.setAccessibilityLabel(version.map { L10n.format("Update to Arbor %@", $0) } ?? L10n.tr("Update Arbor"))
        button.setAccessibilityHelp(tooltip)
        if window.tabStrip.trailingAccessory !== button { window.tabStrip.trailingAccessory = button }
        window.tabStrip.needsLayout = true
    }

    private static func makePill() -> ChromeButton {
        let button = ChromeButton(symbol: "arrow.down.circle", title: L10n.tr("Update"))
        button.identifier = identifier
        button.titleFont = Theme.tabFont
        button.symbolSize = 12
        button.symbolTint = Theme.accent
        button.horizontalPadding = 10
        button.fixedHeight = 24
        button.cornerRadius = 12
        button.restingFill = Theme.toggled
        button.onClick = { _ in AppUpdater.shared?.checkForUpdates() }
        return button
    }
}
