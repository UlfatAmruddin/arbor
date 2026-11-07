import Foundation

/// One directory entry as shown in a listing.
///
/// `id` is the entry name, which is unique within one folder listing. It is a
/// directory-entry identity, not a permanent object identity: a rename changes it
/// and a replaced file keeps it. Never use row indexes as identity.
public struct FileItem: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    /// A container the user can navigate into (folders and symlinks to folders; not packages).
    public let isFolder: Bool
    /// A bundle such as `.app` that macOS presents as a single file.
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymbolicLink: Bool
    /// Logical size in bytes. `nil` means unknown or not applicable (folders), which is
    /// different from a zero-byte file.
    public let size: Int64?
    public let modified: Date?
    /// Localized kind from the system's type database (for example "PDF document").
    public let typeDescription: String

    public var id: String { name }

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

    public static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .typeIdentifierKey,
    ]

    /// Reads metadata for an existing item. Returns nil if the item vanished.
    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        let name = values.name ?? url.lastPathComponent
        let isSymlink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false
        var isPackage = values.isPackage ?? false
        var targetType: String?
        if isSymlink {
            // Treat a link to a folder as a folder so it can be opened, without following it during listing.
            let target = url.resolvingSymlinksInPath()
            if let targetValues = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey]) {
                isDirectory = targetValues.isDirectory ?? false
                isPackage = targetValues.isPackage ?? false
                targetType = targetValues.localizedTypeDescription
            }
        }
        let isFolder = isDirectory && !isPackage
        self.init(
            url: url,
            name: name,
            isFolder: isFolder,
            isPackage: isPackage,
            isHidden: values.isHidden ?? name.hasPrefix("."),
            isSymbolicLink: isSymlink,
            size: isFolder ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            typeDescription: ExplorerTypeName.name(localized: values.localizedTypeDescription, typeIdentifier: values.typeIdentifier,
                                                   isFolder: isFolder, isSymbolicLink: isSymlink, targetDescription: targetType)
        )
    }
}
