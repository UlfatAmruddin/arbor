import Foundation

/// One directory entry in a listing.
/// `id` is the entry name: a rename changes it, a replaced file keeps it. Never use row indexes as identity.
public struct FileItem: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    /// Folders and symlinks to folders; not packages.
    public let isFolder: Bool
    /// A bundle such as `.app` shown as one file.
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymbolicLink: Bool
    /// Bytes; `nil` means unknown or a folder (not the same as zero bytes).
    public let size: Int64?
    public let modified: Date?
    /// Localized kind, e.g. "PDF document".
    public let typeDescription: String

    public var id: String { name }

    /// From the name alone, so it is cheap per row. A symbolic link answers for its own name, not its target's.
    public var windowsShortcutKind: WindowsShortcutKind? {
        WindowsShortcutKind(itemName: name, isFolder: isFolder, isPackage: isPackage)
    }

    public init(
        url: URL,
        name: String,
        isFolder: Bool,
        isPackage: Bool = false,
        isHidden: Bool = false,
        isSymbolicLink: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        typeDescription: String = ""
    ) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.typeDescription = typeDescription
    }

    /// Keys `init(url:)` reads; prefetch them when enumerating. The kind is left out on purpose: per-file
    /// Launch Services lookups took half the listing time, so `TypeDescriptions` caches it per extension.
    public static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .isAliasFileKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    /// Returns nil if the item vanished.
    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { return nil }
        let name = values.name ?? url.lastPathComponent
        let isSymlink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false
        var isPackage = values.isPackage ?? false
        var targetType: String?
        if isSymlink {
            // A link to a folder opens like a folder; the listing doesn't follow it.
            let target = url.resolvingSymlinksInPath()
            if let targetValues = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey]) {
                isDirectory = targetValues.isDirectory ?? false
                isPackage = targetValues.isPackage ?? false
                targetType = targetValues.localizedTypeDescription
            }
        }
        let isFolder = isDirectory && !isPackage
        let isAlias = !isSymlink && (values.isAliasFile ?? false)   // symbolic links also report isAliasFile
        // Dropping cached resource values saves ~40 % of a row's memory; they are re-read on demand.
        var stored = url
        stored.removeAllCachedResourceValues()
        self.init(
            url: stored,
            name: name,
            isFolder: isFolder,
            isPackage: isPackage,
            isHidden: values.isHidden ?? name.hasPrefix("."),
            isSymbolicLink: isSymlink,
            size: isFolder ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            typeDescription: ExplorerTypeName.name(
                localized: TypeDescriptions.shared.describe(url, name: name, isFolder: isFolder, isPackage: isPackage,
                                                            isSymbolicLink: isSymlink, isAlias: isAlias),
                typeIdentifier: isAlias ? ExplorerTypeName.aliasTypeIdentifier : nil,
                isFolder: isFolder, isSymbolicLink: isSymlink, targetDescription: targetType,
                windowsShortcut: WindowsShortcutKind(itemName: name, isFolder: isFolder, isPackage: isPackage))
        )
    }
}
