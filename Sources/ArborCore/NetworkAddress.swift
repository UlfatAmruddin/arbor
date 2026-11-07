import Foundation

/// A server, a share on it, or a folder inside that share (FE-014, FE-176, FE-187).
///
/// Passwords are never kept: parsing drops any password embedded in a URL, so an address can be
/// persisted and logged safely (FE-178). Identity compares scheme, host, port, share and account,
/// case-insensitively like SMB; a display name alone is never an identity.
public struct NetworkAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    /// "smb", "afp", "nfs" or "cifs" (stored as "smb").
    public var scheme: String
    public var host: String
    public var port: Int?
    /// Account name from the URL (`smb://user@host/share`), if any.
    public var user: String?
    /// Share name; nil for the server itself.
    public var share: String?
    /// Folders inside the share.
    public var path: [String]

    public init(scheme: String = "smb", host: String, port: Int? = nil, user: String? = nil, share: String? = nil, path: [String] = []) {
        let lower = scheme.lowercased()
        self.scheme = lower == "cifs" ? "smb" : lower
        self.host = host
        self.port = port
        self.user = (user?.isEmpty ?? true) ? nil : user
        self.share = (share?.isEmpty ?? true) ? nil : share
        self.path = path.filter { !$0.isEmpty }
    }

    /// From `smb://[user[:password]@]host[:port]/share/folder`. The password is discarded.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), PathResolver.networkSchemes.contains(scheme) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else { return nil }
        // URL.pathComponents decodes percent escapes ("Movies%202026" → "Movies 2026").
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        self.init(scheme: scheme, host: host, port: components.port, user: components.user?.removingPercentEncoding ?? components.user,
                  share: parts.first, path: Array(parts.dropFirst()))
    }

    /// Parses what a person types: `\\server\share\folder`, `//server/share`, `smb://server/share`,
    /// `afp://server`. Uses `PathResolver` so the address bar and Map network drive agree.
    public static func parse(_ text: String) -> NetworkAddress? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("//"), !t.hasPrefix("///") { t = "\\\\" + t.dropFirst(2).replacingOccurrences(of: "/", with: "\\") }
        guard case .success(.network(let url)) = PathResolver().resolve(t, relativeTo: nil) else { return nil }
        return NetworkAddress(url: url)
    }

    public var isServer: Bool { share == nil }

    /// The server alone (no account, share or folder).
    public var server: NetworkAddress { NetworkAddress(scheme: scheme, host: host, port: port) }

    /// The share root (keeps the account), or nil for a server.
    public var shareRoot: NetworkAddress? {
        share.map { NetworkAddress(scheme: scheme, host: host, port: port, user: user, share: $0) }
    }

    public func appending(_ component: String) -> NetworkAddress {
        var copy = self
        if copy.share == nil { copy.share = component } else { copy.path.append(component) }
        return copy
    }

    public func withUser(_ user: String?) -> NetworkAddress {
        var copy = self
        copy.user = (user?.isEmpty ?? true) ? nil : user
        return copy
    }

    /// `smb://user@host/share/folder` (never contains a password).
    public var url: URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = port
        c.user = user
        let parts = (share.map { [$0] } ?? []) + path
        c.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        return c.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Windows notation: `\\host\share\folder`.
    public var unc: String {
        (["\\\\" + host] + (share.map { [$0] } ?? []) + path).joined(separator: "\\")
    }

    /// Host without a trailing `.local` / dot, as computers are named in the Network page.
    public var hostDisplayName: String {
        var h = host
        if h.hasSuffix(".") { h.removeLast() }
        if h.lowercased().hasSuffix(".local") { h = String(h.dropLast(6)) }
        return h
    }

    /// Explorer's mapped-drive label: `Media (\\NAS-01)` (without a drive letter, DEC-019).
    public var driveLabel: String {
        guard let share else { return hostDisplayName }
        return "\(share) (\\\\\(hostDisplayName))"
    }

    public var description: String { unc }

    // MARK: Identity (FE-187)

    /// Same server: scheme, host and port, ignoring case and a trailing `.local.` dot.
    public func sameServer(as other: NetworkAddress) -> Bool {
        scheme == other.scheme && Self.normalizedHost(host) == Self.normalizedHost(other.host) && (port ?? 0) == (other.port ?? 0)
    }

    /// Same server and share (case-insensitive, like SMB). Accounts must match when both are known.
    public func sameShare(as other: NetworkAddress) -> Bool {
        guard sameServer(as: other), let a = share, let b = other.share, a.lowercased() == b.lowercased() else { return false }
        if let u1 = user, let u2 = other.user { return Self.normalizedUser(u1) == Self.normalizedUser(u2) }
        return true
    }

    /// A stable string for the share's identity: `smb://user@host:port/share`, lowercased.
    public var identityKey: String {
        var key = scheme + "://"
        if let user { key += Self.normalizedUser(user) + "@" }
        key += Self.normalizedHost(host)
        if let port { key += ":\(port)" }
        if let share { key += "/" + share.lowercased() }
        return key
    }

    static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// `DOMAIN;user` and `user` refer to the same account for matching purposes.
    static func normalizedUser(_ user: String) -> String {
        let u = user.lowercased()
        if let semicolon = u.lastIndex(of: ";") { return String(u[u.index(after: semicolon)...]) }
        return u
    }

    // MARK: Mount table

    /// Parses a mount table "from" name: smbfs `//user@host/share`, afpfs `afp_xxx`-style names are
    /// not addresses and return nil; nfs `host:/export`.
    public static func fromMountSource(_ source: String, fileSystem: String) -> NetworkAddress? {
        switch fileSystem.lowercased() {
        case "smbfs":
            guard source.hasPrefix("//") else { return nil }
            var rest = String(source.dropFirst(2))
            var user: String?
            if let at = rest.lastIndex(of: "@"), let slash = rest.firstIndex(of: "/"), at < slash {
                // "user:password@" never happens in the mount table, but "GUEST:@" does; keep the name only.
                user = String(rest[..<at]).split(separator: ":", omittingEmptySubsequences: false).first.map(String.init)?.removingPercentEncoding
                rest = String(rest[rest.index(after: at)...])
            }
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
            guard let host = parts.first else { return nil }
            var port: Int?
            var hostName = host
            if let colon = host.lastIndex(of: ":"), let p = Int(host[host.index(after: colon)...]) {
                port = p
                hostName = String(host[..<colon])
            }
            return NetworkAddress(scheme: "smb", host: hostName, port: port, user: user, share: parts.dropFirst().first,
                                  path: Array(parts.dropFirst(2)))
        case "nfs":
            guard let colon = source.firstIndex(of: ":") else { return nil }
            let host = String(source[..<colon])
            let parts = source[source.index(after: colon)...].split(separator: "/").map(String.init)
            return NetworkAddress(scheme: "nfs", host: host, share: parts.first, path: Array(parts.dropFirst()))
        default:
            return nil
        }
    }
}
