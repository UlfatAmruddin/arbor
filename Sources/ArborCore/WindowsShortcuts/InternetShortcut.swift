import Foundation

/// A Windows .url file (FE-215). There is no published format, so only `[InternetShortcut]` and `URL=` are read.
public struct InternetShortcut: Equatable, Sendable {
    /// The whole address must fit in the confirmation, which never cuts text off.
    public static let maxAddressLength = UntrustedText.maxDisplayLength
    static let maxLines = 4096

    /// One value, used for both display and opening, so a second `URL=` line can't disguise the target.
    public let rawAddress: String?

    public init(rawAddress: String?) { self.rawAddress = rawAddress }

    public static func parse(_ bytes: [UInt8]) throws -> InternetShortcut {
        var text = TextContent.decode(Data(bytes))
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        // Only CR and LF end a line, as in Windows; other separators stay in the value and are refused there.
        let lines = text.split(maxSplits: maxLines, omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        var inSection = false
        for line in lines.prefix(maxLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inSection { return InternetShortcut(rawAddress: nil) }
                inSection = trimmed.caseInsensitiveCompare("[InternetShortcut]") == .orderedSame
            } else if inSection, let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("URL") == .orderedSame {
                return InternetShortcut(rawAddress: String(line[line.index(after: equals)...]))
            }
        }
        guard lines.count <= maxLines else { throw WindowsShortcutError.malformed }
        guard inSection else { throw WindowsShortcutError.notAShortcut }
        return InternetShortcut(rawAddress: nil)
    }

    /// The exact address that may be opened, or why not. `absoluteString` of the result is what the user confirms.
    public var address: Result<URL, AddressRefusal> {
        guard let raw = rawAddress, !raw.isEmpty else { return .failure(.missing) }
        guard raw.count <= Self.maxAddressLength else { return .failure(.tooLong) }
        if let scheme = Self.foreignScheme(of: raw) { return .failure(.unsupportedScheme(scheme)) }
        guard !raw.unicodeScalars.contains(where: Self.isRefused) else { return .failure(.unsafeCharacters) }
        guard let url = WebLocation.parseWebAddress(raw) else { return .failure(.notWebAddress) }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.notWebAddress) }
        guard parts.user == nil, parts.password == nil else { return .failure(.hasCredentials) }
        // An escaped host would show one name in the prompt and could reach another.
        guard parts.encodedHost?.contains("%") == false else { return .failure(.unsafeCharacters) }
        guard url.absoluteString.count <= Self.maxAddressLength else { return .failure(.tooLong) }
        guard url.absoluteString.allSatisfy(\.isASCII) else { return .failure(.unsafeCharacters) }
        return .success(url)
    }

    private static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar == "\\"
    }

    /// The scheme of an address that isn't web, so the prompt can name it; "www.x.com:80" has none.
    private static func foreignScheme(of raw: String) -> String? {
        guard let colon = raw.firstIndex(of: ":"), !raw.lowercased().hasPrefix("www.") else { return nil }
        let scheme = raw[..<colon].lowercased()
        guard let first = scheme.first, first.isASCII, first.isLetter, scheme.count <= 32,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        return scheme == "http" || scheme == "https" ? nil : scheme
    }
}

/// Why a .url address won't be opened; the UI shows `explanation`.
public enum AddressRefusal: Error, Equatable, Sendable {
    case missing, tooLong, unsafeCharacters, notWebAddress, hasCredentials
    /// Holds only a validated scheme name, so it is safe to show.
    case unsupportedScheme(String)

    public var explanation: String {
        switch self {
        case .missing:
            return L10n.tr("This Internet shortcut doesn't contain an address.")
        case .tooLong:
            return L10n.tr("This address is too long to show in full, so Arbor won't open it.")
        case .unsafeCharacters:
            return L10n.tr("This address contains characters that can disguise where it really goes, so Arbor won't open it.")
        case .notWebAddress:
            return L10n.tr("This isn't a valid web address.")
        case .hasCredentials:
            return L10n.tr("This address contains a user name or password, which can disguise where it really goes, so Arbor won't open it.")
        case .unsupportedScheme(let scheme):
            return L10n.format("This shortcut points to a “%@:” address. Arbor only opens http and https addresses from Internet shortcuts.", "\(scheme)")
        }
    }
}
