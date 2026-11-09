import Foundation

/// The two Windows shortcut file types Arbor reads (FE-215); the one place that knows their extensions.
public enum WindowsShortcutKind: Sendable {
    case link, internet

    public init?(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "lnk": self = .link
        case "url": self = .internet
        default: return nil
        }
    }

    /// The rule for anything listed: a folder or package named x.url isn't a shortcut file.
    public init?(itemName: String, isFolder: Bool, isPackage: Bool) {
        guard !isFolder, !isPackage else { return nil }
        self.init(fileName: itemName)
    }

    /// Never "Shortcut": that word means a Mac alias in the Type column.
    public var typeName: String {
        switch self {
        case .link: return L10n.tr("Windows shortcut")
        case .internet: return L10n.tr("Internet shortcut")
        }
    }

    var maxFileBytes: Int {
        switch self {
        case .link: return 1 << 20
        case .internet: return 64 << 10
        }
    }
}
