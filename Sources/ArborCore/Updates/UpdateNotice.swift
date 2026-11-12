import Foundation

/// The quiet Update button (FE-259): shown while a scheduled check has found an update the user hasn't looked at.
public enum UpdateNotice: Equatable, Sendable {
    case none
    /// `version` is nil when the feed's version text isn't fit to show.
    case available(version: String?)

    public enum Event: Equatable, Sendable {
        /// An update was found; `shownByUpdater` when Sparkle shows its own window (a check the user asked for).
        case found(version: String, shownByUpdater: Bool)
        /// The user brought the update window up.
        case seen
        /// Installed, skipped, postponed or failed: the session is over.
        case finished
    }

    public func after(_ event: Event) -> UpdateNotice {
        switch event {
        case .found(let version, let shownByUpdater): return shownByUpdater ? .none : .available(version: Self.displayVersion(version))
        case .seen, .finished: return .none
        }
    }

    public var isAvailable: Bool { self != .none }

    /// The feed's version text when it is short and plain: it comes from the network and lands in a tooltip.
    public static func displayVersion(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+() ")
        guard !text.isEmpty, text.unicodeScalars.count <= 32, text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return text
    }
}
