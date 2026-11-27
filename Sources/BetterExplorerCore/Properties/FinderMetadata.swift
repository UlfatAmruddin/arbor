import Foundation
import Darwin

/// One Finder tag. `colorIndex` is the position in `NSWorkspace.fileLabels`; 0 means no colour.
public struct FinderTag: Hashable, Sendable {
    public static let colorRange = 0...7

    public let name: String
    public let colorIndex: Int

    public init(name: String, colorIndex: Int = 0) {
        self.name = name
        self.colorIndex = Self.colorRange.contains(colorIndex) ? colorIndex : 0
    }

    /// Finder stores "Name\nN"; a missing or invalid number means no colour.
    public init(storedEntry entry: String) {
        guard let newline = entry.lastIndex(of: "\n") else {
            self.init(name: entry)
            return
        }
        self.init(name: String(entry[..<newline]), colorIndex: Int(entry[entry.index(after: newline)...]) ?? 0)
    }
}

/// Finder tags and comments (FE-161), stored in extended attributes, so lost on copies that drop xattrs.
/// Embedded metadata is separate (`SpotlightMetadata`).
public enum FinderMetadata {
    public static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    // MARK: Tags

    public static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// An empty list removes them.
    public static func setTags(_ tags: [String], on url: URL) throws {
        let clean = normalizedTags(tags)
        try (url as NSURL).setResourceValue(clean, forKey: .tagNamesKey)
    }

    /// Splits on ; , or newline; trims and drops empties and case-insensitive duplicates.
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

    public static func tagText(_ tags: [String]) -> String { tags.joined(separator: "; ") }

    // MARK: Tag colours (FE-081)

    public static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
    public static let tagAttributeByteLimit = 64 * 1024
    /// A small plist can still hold tens of thousands of array entries that share a few objects.
    public static let maxTagsPerFile = 64

    public static func finderTags(fromStored entries: [String]) -> [FinderTag] {
        entries.prefix(maxTagsPerFile).map(FinderTag.init(storedEntry:)).filter { !$0.name.isEmpty }
    }

    public static func parseTagAttribute(_ data: Data) -> [FinderTag] {
        guard let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return finderTags(fromStored: entries)
    }

    /// Reads the attribute itself because no public API returns tag colours. Missing or oversized gives [].
    public static func finderTags(of url: URL) -> [FinderTag] {
        readAttribute(tagAttribute, of: url, limit: tagAttributeByteLimit).map(parseTagAttribute) ?? []
    }

    // MARK: Comments

    public static func comment(of url: URL) -> String {
        guard let data = readAttribute(commentAttribute, of: url) else { return "" }
        if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String { return value }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// "" removes it. Finder may also cache comments in .DS_Store, which only Finder writes.
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

    static func readAttribute(_ name: String, of url: URL, limit: Int = .max) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length <= limit else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return read == length ? data : nil
    }

    public static func attributeNames(of url: URL) -> [String] {
        let path = url.path
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(path, &buffer, length, XATTR_NOFOLLOW) == length else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    public static func isQuarantined(_ url: URL) -> Bool {
        readAttribute("com.apple.quarantine", of: url) != nil
    }

    /// Download sources recorded by browsers.
    public static func whereFroms(of url: URL) -> [String] {
        guard let data = readAttribute("com.apple.metadata:kMDItemWhereFroms", of: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.filter { !$0.isEmpty }
    }
}
