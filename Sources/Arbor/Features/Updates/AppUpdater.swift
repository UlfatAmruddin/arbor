import AppKit
import ArborCore
import Sparkle

/// Sparkle's updater for this run (FE-259, DEC-028), and the only file that uses Sparkle. It exists only when
/// `UpdatesFeature.plan` says so; a scheduled find shows the Update button instead of a window.
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private(set) static var shared: AppUpdater?

    let configuration: UpdateConfiguration
    private var updater: SPUUpdater?
    /// The last failure, for the debug log; Sparkle itself tells the user when they asked for the check.
    private(set) var lastError: String?

    private init(configuration: UpdateConfiguration) {
        self.configuration = configuration
        super.init()
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    }

    /// Once per launch, a moment after the first window, so launch itself does no update work.
    static func startSoon(_ configuration: UpdateConfiguration) {
        guard shared == nil else { return }
        let app = AppUpdater(configuration: configuration)
        shared = app
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { app.start() }
    }

    private func start() {
        do {
            try updater?.start()
            isStarted = true
        } catch {
            // No alert: the menu item stays disabled and the next launch tries again.
            lastError = error.localizedDescription
            updater = nil
        }
    }

    private(set) var isStarted = false
    var canCheck: Bool { isStarted && updater?.canCheckForUpdates == true }

    /// Also brings an update the Update button stands for into view.
    func checkForUpdates() { updater?.checkForUpdates() }

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// Calls `handler` now and whenever the setting changes (Sparkle keeps it in the user defaults).
    func observeAutomaticChecks(_ handler: @escaping (Bool) -> Void) -> NSKeyValueObservation? {
        updater?.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { updater, _ in
            handler(updater.automaticallyChecksForUpdates)
        }
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL.absoluteString }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { lastError = error.localizedDescription }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never a window on its own: the Update button waits for the user.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        UpdatePills.apply(.found(version: update.displayVersionString, shownByUpdater: handleShowingUpdate))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { UpdatePills.apply(.seen) }

    func standardUserDriverWillFinishUpdateSession() { UpdatePills.apply(.finished) }
}
