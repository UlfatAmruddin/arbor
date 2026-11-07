import Foundation

/// The Type column's text ("PDF document", "Folder"), asked of Launch Services once per filename
/// extension instead of once per file (spec §15.3, FE-228).
///
/// Asking each URL for `localizedTypeDescriptionKey` makes Launch Services resolve the localized kind
/// for every row: 1.3 s of the 2.5 s it took to list a 100,000-entry folder (docs/PERFORMANCE.md). The
/// kind of an ordinary file depends only on its extension, so the first file's answer is reused for the
/// others. Items whose kind can depend on the item itself (packages, symbolic links, aliases, files
/// without an extension, folders with one) are still asked one by one. Thread-safe.
public final class TypeDescriptions: @unchecked Sendable {
    public static let shared = TypeDescriptions()

    private let lock = NSLock()
    private var byExtension: [String: String] = [:]
    private var folder: String?
    private let capacity = 4096

    public init() {}

    public func describe(_ url: URL, name: String, isFolder: Bool, isPackage: Bool, isSymbolicLink: Bool,
                         isAlias: Bool = false) -> String {
        let ext = Self.pathExtension(name).lowercased()
        var shareable = !isPackage && !isSymbolicLink && !isAlias && (isFolder ? ext.isEmpty : !ext.isEmpty)
        if shareable, isFolder, MountPoints.shared.isMountPoint(url.path) { shareable = false }   // "Volume"
        let key = isFolder ? "/" : ext
        if shareable, let hit = lock.withLock({ isFolder ? folder : byExtension[key] }) { return hit }
        guard let value = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription else {
            return isFolder ? "Folder" : "Document"
        }
        if shareable {
            lock.withLock {
                if isFolder {
                    folder = value
                } else {
                    if byExtension.count >= capacity { byExtension.removeAll() }
                    byExtension[key] = value
                }
            }
        }
        return value
    }

    /// `NSString.pathExtension` without bridging: the text after the last dot, unless the dot starts the
    /// name or the text contains a space ("archive.tar.gz" → "gz", ".profile" → "", "v1. draft" → "").
    static func pathExtension(_ name: String) -> String {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return "" }
        let ext = utf8[utf8.index(after: dot)...]
        if ext.isEmpty || ext.contains(UInt8(ascii: " ")) || ext.contains(UInt8(ascii: "/")) { return "" }
        return String(Substring(ext))
    }
}
