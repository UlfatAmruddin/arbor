import Foundation

/// Where in-app updates come from (FE-259, DEC-028). It exists only for a feed and key that pass every check,
/// so a build without them has no updater at all.
public struct UpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    /// Sparkle's EdDSA public key, base64, as `generate_keys` prints it.
    public let publicKey: String

    /// `allowsLoopback`: a debug build's test feed may be plain http served from this Mac.
    public init?(feed: String?, publicKey: String?, allowsLoopback: Bool = false) {
        guard let feed, let publicKey, let url = Self.feedURL(feed, allowsLoopback: allowsLoopback),
              Self.isPublicKey(publicKey) else { return nil }
        feedURL = url
        self.publicKey = publicKey
    }

    static func feedURL(_ text: String, allowsLoopback: Bool) -> URL? {
        guard text.utf8.count <= 2048, let parts = URLComponents(string: text), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil, let url = parts.url else { return nil }
        switch parts.scheme?.lowercased() {
        case "https": return url
        case "http" where allowsLoopback && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host): return url
        default: return nil
        }
    }

    public static func isPublicKey(_ text: String) -> Bool {
        text.utf8.count == 44 && Data(base64Encoded: text)?.count == 32
    }

    /// Whether this run gets an updater, and why not.
    public enum Plan: Equatable, Sendable {
        case run(UpdateConfiguration)
        case off(Reason)
    }

    public enum Reason: String, Sendable {
        /// No feed and key in Info.plist (local, CI and fork builds), or ones that fail the checks.
        case notConfigured = "not configured"
        /// Headless runs never reach the network or show Sparkle's windows.
        case headless
        /// Scripted checks drive the app; only a debug build's test feed starts the updater for them.
        case scripted
    }

    /// `testFeed` is a debug build's override (nil in release builds); the key always comes from Info.plist.
    public static func plan(feed: String?, publicKey: String?, testFeed: String?, headless: Bool, scripted: Bool) -> Plan {
        if headless { return .off(.headless) }
        if let testFeed {
            return UpdateConfiguration(feed: testFeed, publicKey: publicKey, allowsLoopback: true).map(Plan.run) ?? .off(.notConfigured)
        }
        if scripted { return .off(.scripted) }
        return UpdateConfiguration(feed: feed, publicKey: publicKey).map(Plan.run) ?? .off(.notConfigured)
    }
}
