import Foundation

/// For the "Change the file name extension?" warning. ".env" has no extension (NameRules), so
/// ".env.local" adds one.
public enum ExtensionChange: Equatable, Sendable {
    case unchanged
    case changed(from: String, to: String)
    case added(String)
    case removed(String)

    /// Case-insensitive ("photo.JPG" → "photo.jpg" is unchanged).
    public static func between(_ oldName: String, _ newName: String) -> ExtensionChange {
        let old = NameRules.splitExtension(oldName, treatAsFolder: false).ext
        let new = NameRules.splitExtension(newName, treatAsFolder: false).ext
        switch (old, new) {
        case (nil, nil): return .unchanged
        case (nil, let added?): return .added(added)
        case (let removed?, nil): return .removed(removed)
        case (let from?, let to?): return from.lowercased() == to.lowercased() ? .unchanged : .changed(from: from, to: to)
        }
    }
}
