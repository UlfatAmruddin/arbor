import Foundation

/// Cloud sync state of one item (FE-190), from ubiquitous-item keys; never guessed, else `.unknown`.
public enum CloudStatus: Equatable, Hashable, Sendable {
    case availableOnDevice
    /// Placeholder only; opening downloads it.
    case onlineOnly
    case downloading
    case uploading
    /// Local changes not uploaded, no upload running.
    case syncPending
    case conflict
    case error(String)
    case unknown

    /// Windows wording where one exists.
    public var title: String {
        switch self {
        case .availableOnDevice: return L10n.tr("Available on this device")
        case .onlineOnly: return L10n.tr("Available when online")
        case .downloading: return L10n.tr("Syncing (downloading)")
        case .uploading: return L10n.tr("Syncing (uploading)")
        case .syncPending: return L10n.tr("Sync pending")
        case .conflict: return L10n.tr("Sync conflict")
        case .error(let message): return message.isEmpty ? L10n.tr("Sync error") : L10n.format("Sync error: %@", "\(message)")
        case .unknown: return L10n.tr("Status unknown")
        }
    }

    public var shortTitle: String {
        switch self {
        case .availableOnDevice: return L10n.tr("Available")
        case .onlineOnly: return L10n.tr("Online-only")
        case .downloading, .uploading: return L10n.tr("Syncing")
        case .syncPending: return L10n.tr("Sync pending")
        case .conflict: return L10n.tr("Conflict")
        case .error: return L10n.tr("Error")
        case .unknown: return L10n.tr("Unknown")
        }
    }

    /// nil when not known.
    public var isLocal: Bool? {
        switch self {
        case .availableOnDevice, .uploading, .syncPending: return true
        case .onlineOnly: return false
        default: return nil
        }
    }
}

/// Testable copy of the `URLResourceValues` the mapping uses.
public struct UbiquityInfo: Equatable, Sendable {
    public enum Download: Equatable, Sendable { case current, downloaded, notDownloaded, other(String) }

    public var isUbiquitous: Bool?
    public var download: Download?
    public var isDownloading: Bool?
    public var isUploading: Bool?
    public var isUploaded: Bool?
    public var downloadError: String?
    public var uploadError: String?
    public var hasConflicts: Bool?

    public init(isUbiquitous: Bool? = nil, download: Download? = nil, isDownloading: Bool? = nil, isUploading: Bool? = nil,
                isUploaded: Bool? = nil, downloadError: String? = nil, uploadError: String? = nil, hasConflicts: Bool? = nil) {
        self.isUbiquitous = isUbiquitous
        self.download = download
        self.isDownloading = isDownloading
        self.isUploading = isUploading
        self.isUploaded = isUploaded
        self.downloadError = downloadError
        self.uploadError = uploadError
        self.hasConflicts = hasConflicts
    }

    public static let resourceKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemUploadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey,
    ]

    public init(_ v: URLResourceValues) {
        isUbiquitous = v.isUbiquitousItem
        switch v.ubiquitousItemDownloadingStatus {
        case .some(.current): download = .current
        case .some(.downloaded): download = .downloaded
        case .some(.notDownloaded): download = .notDownloaded
        case .some(let other): download = .other(other.rawValue)
        case .none: download = nil
        }
        isDownloading = v.ubiquitousItemIsDownloading
        isUploading = v.ubiquitousItemIsUploading
        isUploaded = v.ubiquitousItemIsUploaded
        downloadError = v.ubiquitousItemDownloadingError?.localizedDescription
        uploadError = v.ubiquitousItemUploadingError?.localizedDescription
        hasConflicts = v.ubiquitousItemHasUnresolvedConflicts
    }

    /// Can block on slow volumes: call off the main thread.
    public static func read(_ url: URL) -> UbiquityInfo? {
        (try? url.resourceValues(forKeys: resourceKeys)).map(UbiquityInfo.init)
    }
}

public enum CloudStatusMapper {
    /// Priority: errors, conflicts, transfers, then download state.
    public static func status(_ info: UbiquityInfo) -> CloudStatus {
        guard info.isUbiquitous == true else { return .unknown }
        if let error = info.downloadError ?? info.uploadError { return .error(error) }
        if info.hasConflicts == true { return .conflict }
        if info.isDownloading == true { return .downloading }
        if info.isUploading == true { return .uploading }
        switch info.download {
        case .current?, .downloaded?:
            return info.isUploaded == false ? .syncPending : .availableOnDevice
        case .notDownloaded?:
            return .onlineOnly
        case .other?, nil:
            return info.isUploaded == false ? .syncPending : .unknown
        }
    }
}

// MARK: - Cloud roots (FE-189, FE-197, FE-198)

/// iCloud Drive or a File Provider folder under ~/Library/CloudStorage (one per account).
public struct CloudRoot: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case iCloud, fileProvider, test }
    public let url: URL
    public let provider: String
    /// Account or domain label, if the folder has one.
    public let account: String?
    public let kind: Kind

    public init(url: URL, provider: String, account: String?, kind: Kind) {
        self.url = url.standardizedFileURL
        self.provider = provider
        self.account = account
        self.kind = kind
    }

    /// "OneDrive – Personal", "iCloud Drive".
    public var displayName: String { account.map { "\(provider) – \($0)" } ?? provider }

    public func contains(_ url: URL) -> Bool {
        let root = CloudRoots.normalized(self.url)
        let path = CloudRoots.normalized(url)
        return path == root || path.hasPrefix(root + "/")
    }
}

public enum CloudRoots {
    /// Display names for CloudStorage folder prefixes.
    static let knownProviders: [String: String] = [
        "onedrive": "OneDrive", "googledrive": "Google Drive", "dropbox": "Dropbox", "box": "Box",
        "protondrive": "Proton Drive", "synologydrive": "Synology Drive", "pclouddrive": "pCloud Drive",
        "nextcloud": "Nextcloud", "megasync": "MEGA", "icedrive": "Icedrive", "sharepoint": "SharePoint",
    ]

    /// "OneDrive-Personal" → ("OneDrive", "Personal"); "Box-Box" → ("Box", nil); unknown prefixes kept.
    public static func providerAndAccount(forCloudStorageFolder name: String) -> (provider: String, account: String?) {
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let rawProvider = parts.first ?? name
        let provider = knownProviders[rawProvider.lowercased()] ?? rawProvider
        var account = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        if let a = account, a.isEmpty || a.lowercased() == rawProvider.lowercased() || a.lowercased() == provider.lowercased() {
            account = nil
        }
        return (provider, account)
    }

    /// Never lists cloud content.
    public static func detect(home: URL, fileManager: FileManager = .default) -> [CloudRoot] {
        var roots: [CloudRoot] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: iCloud.path, isDirectory: &isDir), isDir.boolValue {
            roots.append(CloudRoot(url: iCloud, provider: "iCloud Drive", account: nil, kind: .iCloud))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let names = ((try? fileManager.contentsOfDirectory(atPath: storage.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for name in names {
            let url = storage.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let (provider, account) = providerAndAccount(forCloudStorageFolder: name)
            roots.append(CloudRoot(url: url, provider: provider, account: account, kind: .fileProvider))
        }
        return roots
    }

    public static func root(containing url: URL, in roots: [CloudRoot]) -> CloudRoot? {
        roots.filter { $0.contains(url) }.max { $0.url.path.count < $1.url.path.count }
    }

    static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Test overrides (headless scripted runs only)

    /// `ARBOR_TEST_CLOUD_ROOT` makes a fixture folder a cloud root, so tests never touch real ones.
    public static func testRoots(environment: [String: String]) -> [CloudRoot] {
        guard let path = environment["ARBOR_TEST_CLOUD_ROOT"], !path.isEmpty else { return [] }
        return [CloudRoot(url: URL(fileURLWithPath: path), provider: "Test Cloud", account: environment["ARBOR_TEST_CLOUD_ACCOUNT"], kind: .test)]
    }

    /// `ARBOR_TEST_CLOUD_STATUS="a.txt=online,b.txt=available"`: fake statuses for the test root.
    public static func parseTestStatuses(_ text: String) -> [String: CloudStatus] {
        var result: [String: CloudStatus] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let status: CloudStatus?
            switch parts[1].lowercased() {
            case "available", "local": status = .availableOnDevice
            case "online", "cloud": status = .onlineOnly
            case "downloading", "syncing": status = .downloading
            case "uploading": status = .uploading
            case "pending": status = .syncPending
            case "conflict": status = .conflict
            case "error": status = .error("The provider reported an error.")
            case "unknown": status = .unknown
            default: status = nil
            }
            if let status { result[parts[0]] = status }
        }
        return result
    }
}
