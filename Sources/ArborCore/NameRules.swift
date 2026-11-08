import Foundation

public enum NameValidationError: Error, Equatable, LocalizedError {
    case empty
    case reserved(String)
    case containsSlash
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .empty: return L10n.tr("A name can't be empty.")
        case .reserved(let name): return L10n.format("“%@” is reserved by the system. Choose a different name.", "\(name)")
        case .containsSlash: return L10n.tr("A name can't contain “/”.")
        case .tooLong: return L10n.tr("That name is too long. Names are limited to 255 bytes.")
        }
    }
}

/// Naming conventions. Validation uses the Mac destination's rules, not Windows'
/// (FE-086, spec §8.1): a name that Windows forbids but macOS allows stays valid.
public enum NameRules {
    /// Splits off the last extension. Dotfiles (".zshrc") and folders have none.
    public static func splitExtension(_ name: String, treatAsFolder: Bool) -> (base: String, ext: String?) {
        guard !treatAsFolder,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              name.index(after: dot) != name.endIndex else {
            return (name, nil)
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// The UTF-16 range a rename field should select initially: the base name, not the extension.
    public static func basenameSelection(_ name: String, treatAsFolder: Bool) -> NSRange {
        let base = splitExtension(name, treatAsFolder: treatAsFolder).base
        return NSRange(location: 0, length: (base as NSString).length)
    }

    private static func join(_ base: String, _ ext: String?) -> String {
        ext.map { "\(base).\($0)" } ?? base
    }

    /// Duplicate in the same folder: "Report - Copy.pdf", then "Report - Copy (2).pdf".
    public static func duplicateName(for name: String, treatAsFolder: Bool, isTaken: (String) -> Bool) -> String {
        let (base, ext) = splitExtension(name, treatAsFolder: treatAsFolder)
        let first = join("\(base) - Copy", ext)
        if !isTaken(first) { return first }
        var n = 2
        while isTaken(join("\(base) - Copy (\(n))", ext)) { n += 1 }
        return join("\(base) - Copy (\(n))", ext)
    }

    /// "Keep both" during a conflict: "Report (2).pdf", "Report (3).pdf".
    public static func keepBothName(for name: String, treatAsFolder: Bool, isTaken: (String) -> Bool) -> String {
        let (base, ext) = splitExtension(name, treatAsFolder: treatAsFolder)
        var n = 2
        while isTaken(join("\(base) (\(n))", ext)) { n += 1 }
        return join("\(base) (\(n))", ext)
    }

    /// "New folder", then "New folder (2)".
    public static func newFolderName(isTaken: (String) -> Bool) -> String {
        if !isTaken("New folder") { return L10n.tr("New folder") }
        var n = 2
        while isTaken("New folder (\(n))") { n += 1 }
        return L10n.format("New folder (%@)", "\(n)")
    }

    public static func validate(_ name: String) -> NameValidationError? {
        if name.isEmpty { return .empty }
        if name == "." || name == ".." { return .reserved(name) }
        if name.contains("/") { return .containsSlash }
        if name.contains("\u{0}") { return .reserved(name) }
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }
}
