import Foundation
import Darwin

/// Finder tags and Finder comments (FE-161). These are stored by macOS *next to* the file (extended
/// attributes), not inside it, so they never change the file's content and are lost when a file is
/// copied to a disk or service that drops extended attributes. Embedded metadata (EXIF, ID3, PDF
/// info) is separate and read-only here (`SpotlightMetadata`).
public enum FinderMetadata {
    public static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    // MARK: Tags

    public static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// Replaces the item's Finder tags. An empty list removes them.
    public static func setTags(_ tags: [String], on url: URL) throws {
        let clean = normalizedTags(tags)
        try (url as NSURL).setResourceValue(clean, forKey: .tagNamesKey)
    }

    /// Splits "Red; Work, Taxes 2026" into ["Red", "Work", "Taxes 2026"]; trims, drops empties and
    /// duplicates (case-insensitive, first spelling kept). Explorer separates tags with semicolons.
    public static func parseTags(_ text: String) -> [String] {
        normalizedTags(text.components(separatedBy: CharacterSet(charactersIn: ";,\n")))
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            result.append(t)
        }
        return result
    }

    /// "Red; Work" (the editable text form).
    public static func tagText(_ tags: [String]) -> String { tags.joined(separator: "; ") }

    // MARK: Comments

    /// The Finder comment, from the extended attribute Finder and Spotlight use.
    public static func comment(of url: URL) -> String {
        guard let data = readAttribute(commentAttribute, of: url) else { return "" }
        if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String { return value }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes (or with "" removes) the comment attribute. Finder may also cache comments in the folder's
    /// .DS_Store, which only Finder writes; Spotlight and Arbor read the attribute.
    public static func setComment(_ comment: String, on url: URL) throws {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if lremovexattr(url.path, commentAttribute) != 0, errno != ENOATTR { throw POSIXError.current }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, commentAttribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        if result != 0 { throw POSIXError.current }
    }

    static func lremovexattr(_ path: String, _ name: String) -> Int32 {
        removexattr(path, name, XATTR_NOFOLLOW)
    }

    static func readAttribute(_ name: String, of url: URL) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return read == length ? data : nil
    }

    /// Names of the item's extended attributes (for the Details tab's "Attributes" note).
    public static func attributeNames(of url: URL) -> [String] {
        let path = url.path
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(path, &buffer, length, XATTR_NOFOLLOW) == length else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    /// "Where from" for downloaded files and whether macOS quarantines it (Explorer's "This file came
    /// from another computer" note).
    public static func isQuarantined(_ url: URL) -> Bool {
        readAttribute("com.apple.quarantine", of: url) != nil
    }

    /// Explorer's "Unblock": removes macOS's quarantine mark from a downloaded file, so Gatekeeper
    /// no longer asks before it opens. Only done when the user ticks Unblock and applies.
    public static func removeQuarantine(from url: URL) throws {
        if removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR { throw POSIXError.current }
    }

    /// The download source URLs recorded by browsers ("Where from").
    public static func whereFroms(of url: URL) -> [String] {
        guard let data = readAttribute("com.apple.metadata:kMDItemWhereFroms", of: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.filter { !$0.isEmpty }
    }
}
