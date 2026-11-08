import Foundation

/// Type column text cached per extension (spec §15.3, FE-228): per-file lookups were 1.3 s of a 2.5 s
/// 100,000-entry listing. Packages, links, aliases and extensionless files are still asked per item. Thread-safe.
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
            return isFolder ? L10n.tr("Folder") : L10n.tr("Document")
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

    /// Bridging-free `pathExtension`: ".profile" → "", "v1. draft" → "" (no spaces allowed).
    static func pathExtension(_ name: String) -> String {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return "" }
        let ext = utf8[utf8.index(after: dot)...]
        if ext.isEmpty || ext.contains(UInt8(ascii: " ")) || ext.contains(UInt8(ascii: "/")) { return "" }
        return String(Substring(ext))
    }
}
