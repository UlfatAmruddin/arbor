import Foundation

/// How a file rename changes the name extension, for the "Change the file name extension?" warning.
/// A name that starts with a dot and has no other dot (".env") has no extension (NameRules), so renaming
/// it to ".env.local" *adds* "local" rather than changing an empty extension.
public enum ExtensionChange: Equatable, Sendable {
    case unchanged
    case changed(from: String, to: String)
    case added(String)
    case removed(String)

    /// Extensions are compared without regard to letter case ("photo.JPG" → "photo.jpg" is unchanged).
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
