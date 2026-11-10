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

/// Validation uses macOS rules, not Windows' (FE-086, spec §8.1).
public enum NameRules {
    /// Dotfiles (".zshrc") and folders have no extension.
    public static func splitExtension(_ name: String, treatAsFolder: Bool) -> (base: String, ext: String?) {
        guard !treatAsFolder,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              name.index(after: dot) != name.endIndex else {
            return (name, nil)
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Initial rename selection (UTF-16): the base name, not the extension.
    public static func basenameSelection(_ name: String, treatAsFolder: Bool) -> NSRange {
        let base = splitExtension(name, treatAsFolder: treatAsFolder).base
        return NSRange(location: 0, length: (base as NSString).length)
    }

    private static func join(_ base: String, _ ext: String?) -> String {
        ext.map { "\(base).\($0)" } ?? base
    }

    /// "Report - Copy.pdf", then "Report - Copy (2).pdf".
    public static func duplicateName(for name: String, treatAsFolder: Bool, isTaken: (String) -> Bool) -> String {
        let (base, ext) = splitExtension(name, treatAsFolder: treatAsFolder)
        let first = join("\(base) - Copy", ext)
        if !isTaken(first) { return first }
        var n = 2
        while isTaken(join("\(base) - Copy (\(n))", ext)) { n += 1 }
        return join("\(base) - Copy (\(n))", ext)
    }

    /// "Report (2).pdf", "Report (3).pdf".
    public static func keepBothName(for name: String, treatAsFolder: Bool, isTaken: (String) -> Bool) -> String {
        let (base, ext) = splitExtension(name, treatAsFolder: treatAsFolder)
        var n = 2
        while isTaken(join("\(base) (\(n))", ext)) { n += 1 }
        return join("\(base) (\(n))", ext)
    }

    /// "New folder", then "New folder (2)".
    public static func newFolderName(isTaken: (String) -> Bool) -> String {
        let first = L10n.tr("New folder")
        if !isTaken(first) { return first }
        var n = 2
        while isTaken(numberedNewFolder(n)) { n += 1 }
        return numberedNewFolder(n)
    }

    private static func numberedNewFolder(_ number: Int) -> String { L10n.plainFormat("New folder (%@)", "\(number)") }

    public static func validate(_ name: String) -> NameValidationError? {
        if name.isEmpty { return .empty }
        if name == "." || name == ".." { return .reserved(name) }
        if name.contains("/") { return .containsSlash }
        if name.contains("\u{0}") { return .reserved(name) }
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }
}
