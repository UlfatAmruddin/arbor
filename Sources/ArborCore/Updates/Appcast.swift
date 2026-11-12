import CryptoKit
import Foundation

/// The update feed a release publishes (FE-259): one item, this release, in Sparkle's appcast format.
public struct AppcastItem: Equatable, Sendable {
    /// CFBundleShortVersionString (VERSION), shown to people.
    public var shortVersion: String
    /// CFBundleVersion (the commit count), which Sparkle compares.
    public var build: String
    public var minimumSystemVersion: String
    public var downloadURL: URL
    public var length: Int
    /// Base64 EdDSA signature of the archive, as `sign_update -p` prints it.
    public var edSignature: String
    public var notesHTML: String
    public var published: Date

    public init(shortVersion: String, build: String, minimumSystemVersion: String, downloadURL: URL, length: Int,
                edSignature: String, notesHTML: String, published: Date) {
        self.shortVersion = shortVersion
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.downloadURL = downloadURL
        self.length = length
        self.edSignature = edSignature
        self.notesHTML = notesHTML
        self.published = published
    }
}

public enum AppcastError: Error, Equatable, CustomStringConvertible {
    case unpublishable(String)

    public var description: String {
        switch self { case .unpublishable(let what): return what }
    }
}

public enum Appcast {
    /// The feed's XML. Throws for a value Sparkle would misread or XML can't carry, rather than writing it.
    public static func xml(_ item: AppcastItem, title: String = "Arbor") throws -> String {
        for (name, value) in [("version", item.shortVersion), ("build", item.build), ("minimum macOS", item.minimumSystemVersion)] {
            guard isDottedNumber(value) else { throw AppcastError.unpublishable("\(name) “\(value)” is not a dotted number") }
        }
        guard isDownloadURL(item.downloadURL) else {
            throw AppcastError.unpublishable("the download address must be https (or http to this Mac, for tests)")
        }
        guard item.length > 0 else { throw AppcastError.unpublishable("the archive is empty") }
        guard Data(base64Encoded: item.edSignature)?.count == 64 else { throw AppcastError.unpublishable("the EdDSA signature is not 64 bytes of base64") }
        let lines = [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            #"<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">"#,
            "  <channel>",
            "    <title>\(try text(title))</title>",
            "    <item>",
            "      <title>\(try text("\(title) \(item.shortVersion)"))</title>",
            "      <pubDate>\(rfc822(item.published))</pubDate>",
            "      <sparkle:version>\(item.build)</sparkle:version>",
            "      <sparkle:shortVersionString>\(item.shortVersion)</sparkle:shortVersionString>",
            "      <sparkle:minimumSystemVersion>\(item.minimumSystemVersion)</sparkle:minimumSystemVersion>",
            "      <description>\(try text(item.notesHTML))</description>",
            "      <enclosure url=\"\(try text(item.downloadURL.absoluteString))\" length=\"\(item.length)\""
                + " type=\"application/octet-stream\" sparkle:edSignature=\"\(item.edSignature)\"/>",
            "    </item>",
            "  </channel>",
            "</rss>",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes text and attribute values; refuses characters XML 1.0 can't carry at all.
    static func text(_ value: String) throws -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                guard scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF else {
                    throw AppcastError.unpublishable(String(format: "the text holds U+%04X, which XML can't carry", scalar.value))
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func isDottedNumber(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 32 && !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
    }

    static func isDownloadURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        switch parts.scheme {
        case "https": return true
        case "http": return host == "127.0.0.1" || host == "localhost"
        default: return false
        }
    }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

/// Sparkle's archive signature: Ed25519 over the archive's bytes, keys and signature in base64.
public enum UpdateSignature {
    /// Checked before a feed is published, so a key mismatch fails the release instead of every update.
    public static func isValid(_ signature: String, of data: Data, publicKey: String) -> Bool {
        guard let raw = Data(base64Encoded: signature), raw.count == 64, let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(raw, for: data)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
