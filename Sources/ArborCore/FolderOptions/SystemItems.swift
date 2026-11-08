import Foundation

/// Mac stand-in for Windows' "protected operating system files" (FE-045, reference §16): macOS bookkeeping
/// files (`.DS_Store`, `._*`…) and hidden folders at the startup disk root. Only matters while hidden items show.
public enum ProtectedSystemItems {
    public static let names: Set<String> = [
        ".DS_Store", ".localized", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".VolumeIcon.icns", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
        ".MobileBackups", ".MobileBackups.trash", ".HFS+ Private Directory Data\r", ".file", ".vol", ".hotfiles.btree",
        ".journal", ".journal_info_block", ".apdisk", ".com.apple.timemachine.donotpresent",
        ".com.apple.timemachine.supported", ".disk_label", ".disk_label_2x", "Icon\r",
        // Left behind by Windows on shared drives.
        "$RECYCLE.BIN", "System Volume Information", "desktop.ini", "Thumbs.db",
    ]

    /// True for items "Hide protected operating system files" hides.
    public static func isProtected(name: String, parentPath: String, isHidden: Bool) -> Bool {
        if names.contains(name) { return true }
        if name.hasPrefix("._") { return true }
        return isHidden && Location.normalizedPath(URL(fileURLWithPath: parentPath)) == "/"
    }

    public static func filter(_ items: [FileItem]) -> [FileItem] {
        // Build the parent path only for hidden items; doing it per row dominated large listings.
        items.filter { item in
            if names.contains(item.name) || item.name.hasPrefix("._") { return false }
            guard item.isHidden else { return true }
            return !isProtected(name: item.name, parentPath: item.url.deletingLastPathComponent().path, isHidden: true)
        }
    }
}

/// The sync provider owning a folder (FE-043): iCloud Drive or a File Provider under ~/Library/CloudStorage.
public enum SyncProviderDetector {
    public struct Provider: Equatable, Sendable {
        public let name: String
        public let root: String
    }

    public static func provider(forPath path: String, home: String) -> Provider? {
        let path = Location.normalizedPath(URL(fileURLWithPath: path))
        let home = Location.normalizedPath(URL(fileURLWithPath: home))
        let iCloud = home + "/Library/Mobile Documents"
        if path == iCloud || path.hasPrefix(iCloud + "/") { return Provider(name: "iCloud Drive", root: iCloud) }
        let storage = home + "/Library/CloudStorage/"
        guard path.hasPrefix(storage) else { return nil }
        let folder = path.dropFirst(storage.count).split(separator: "/").first.map(String.init) ?? ""
        guard !folder.isEmpty else { return nil }
        return Provider(name: displayName(ofStorageFolder: folder), root: storage + folder)
    }

    /// "GoogleDrive-ana@example.com" → "Google Drive", "OneDrive-Personal" → "OneDrive", "Dropbox" → "Dropbox".
    public static func displayName(ofStorageFolder folder: String) -> String {
        let base = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        let known = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "iCloudDrive": "iCloud Drive", "pCloudDrive": "pCloud Drive"]
        if let name = known[base] { return name }
        var result = ""
        for (i, ch) in base.enumerated() {
            if i > 0, ch.isUppercase, let last = result.last, last.isLowercase { result.append(" ") }
            result.append(ch)
        }
        return result
    }
}
