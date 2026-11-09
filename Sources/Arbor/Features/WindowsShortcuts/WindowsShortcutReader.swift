import Foundation
import ArborCore

/// Reads and judges a shortcut off the main thread within a deadline, for the opener and the Properties tab.
enum WindowsShortcutReader {
    typealias Reading = Result<WindowsShortcutInspection, Error>
    typealias Outcome = SlowWorkQueue<Reading>.Outcome

    private static let queue = SlowWorkQueue<Reading>(label: "arbor.windows-shortcuts")
    private static let deadline: TimeInterval = 5

    /// Includes reads stuck on a hung share.
    static var inFlightCount: Int { queue.inFlightCount }

    static var timeoutMessage: String { L10n.tr("Reading the shortcut took too long. The drive it's on may not be responding.") }

    /// Same-key requests share one read; `key` defaults to the path.
    @discardableResult
    static func inspect(_ url: URL, key: String? = nil, completion: @escaping (Outcome) -> Void) -> UUID {
        queue.run(key: key ?? url.path, timeout: deadline, work: { Result { try WindowsShortcutPolicy.inspect(url) } }, completion: completion)
    }

    static func cancel(_ token: UUID) { queue.cancel(token) }
}
