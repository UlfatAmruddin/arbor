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
    /// The provider says the user must sign in; the text is its own.
    case signInRequired(String)
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
        case .signInRequired(let message): return message.isEmpty ? L10n.tr("Sign in required") : L10n.format("Sign in required: %@", "\(message)")
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
        case .signInRequired: return L10n.tr("Sign in")
        case .unknown: return L10n.tr("Unknown")
        }
    }

    public var isFailure: Bool {
        switch self {
        case .error, .signInRequired: return true
        default: return false
        }
    }

    /// The provider's own app is where this gets fixed (FE-192).
    public var needsProviderHandoff: Bool { isFailure || self == .conflict }

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
    /// A real not-signed-in code in either error key (FE-195).
    public var authenticationRequired: Bool

    public init(isUbiquitous: Bool? = nil, download: Download? = nil, isDownloading: Bool? = nil, isUploading: Bool? = nil,
                isUploaded: Bool? = nil, downloadError: String? = nil, uploadError: String? = nil, hasConflicts: Bool? = nil,
                authenticationRequired: Bool = false) {
        self.isUbiquitous = isUbiquitous
        self.download = download
        self.isDownloading = isDownloading
        self.isUploading = isUploading
        self.isUploaded = isUploaded
        self.downloadError = downloadError
        self.uploadError = uploadError
        self.hasConflicts = hasConflicts
        self.authenticationRequired = authenticationRequired
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
        authenticationRequired = [v.ubiquitousItemDownloadingError, v.ubiquitousItemUploadingError]
            .contains { $0.map(CloudProviderError.requiresSignIn) == true }
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
        if let failure = failureText(info) { return info.authenticationRequired ? .signInRequired(failure) : .error(failure) }
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

    /// The provider's text from both keys, once each and safe to show; nil without a failure.
    private static func failureText(_ info: UbiquityInfo) -> String? {
        guard info.downloadError != nil || info.uploadError != nil else { return nil }
        var texts: [String] = []
        for text in [info.downloadError, info.uploadError].compactMap({ $0 }).map(CloudProviderError.message) where !text.isEmpty && !texts.contains(text) {
            texts.append(text)
        }
        return texts.joined(separator: " · ")
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
    /// nil where there's no folder name to read (iCloud Drive, the plain test root).
    public let accountKind: CloudAccountKind?
    /// The table row; a provider that isn't in the table gets no hand-off.
    public let entry: CloudProviderEntry?

    public init(url: URL, provider: String, account: String?, kind: Kind, accountKind: CloudAccountKind? = nil, entry: CloudProviderEntry? = nil) {
        self.url = url.standardizedFileURL
        self.provider = provider
        self.account = account
        self.kind = kind
        self.accountKind = accountKind
        self.entry = entry
    }

    /// "OneDrive – Personal", "iCloud Drive".
    public var displayName: String { account.map { "\(provider) – \($0)" } ?? provider }

    /// The name, then what kind of account it is, unless the name just said so.
    public var navigationTitle: String {
        guard let accountKind, account?.lowercased() != accountKind.title.lowercased() else { return displayName }
        return L10n.format("%@ (%@)", displayName, accountKind.title)
    }

    public func contains(_ url: URL) -> Bool {
        let root = CloudRoots.normalized(self.url)
        let path = CloudRoots.normalized(url)
        return path == root || path.hasPrefix(root + "/")
    }
}

public enum CloudRoots {
    /// Never lists cloud content.
    public static func detect(home: URL, fileManager: FileManager = .default) -> [CloudRoot] {
        var roots: [CloudRoot] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: iCloud.path, isDirectory: &isDir), isDir.boolValue {
            roots.append(CloudRoot(url: iCloud, provider: CloudProviderCatalog.iCloud.displayName, account: nil, kind: .iCloud, entry: CloudProviderCatalog.iCloud))
        }
        return roots + storageRoots(in: home.appendingPathComponent("Library/CloudStorage"), kind: .fileProvider, fileManager: fileManager)
    }

    private static func storageRoots(in storage: URL, kind: CloudRoot.Kind, fileManager: FileManager) -> [CloudRoot] {
        let names = ((try? fileManager.contentsOfDirectory(atPath: storage.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.compactMap { name in
            let url = storage.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let identity = CloudFolderName.parse(name)
            return CloudRoot(url: url, provider: identity.provider, account: identity.account, kind: kind,
                             accountKind: identity.accountKind, entry: identity.entry)
        }
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

    /// `ARBOR_TEST_CLOUD_ROOT` makes a fixture folder a cloud root, and each folder in `ARBOR_TEST_CLOUD_STORAGE`
    /// stands in for one under ~/Library/CloudStorage, so tests never touch real ones.
    public static func testRoots(environment: [String: String], fileManager: FileManager = .default) -> [CloudRoot] {
        var roots: [CloudRoot] = []
        if let path = environment["ARBOR_TEST_CLOUD_ROOT"], !path.isEmpty {
            roots.append(CloudRoot(url: URL(fileURLWithPath: path), provider: "Test Cloud", account: environment["ARBOR_TEST_CLOUD_ACCOUNT"], kind: .test))
        }
        if let path = environment["ARBOR_TEST_CLOUD_STORAGE"], !path.isEmpty {
            roots += storageRoots(in: URL(fileURLWithPath: path), kind: .test, fileManager: fileManager)
        }
        return roots
    }

    /// `ARBOR_TEST_CLOUD_KEYS="ubiquitous,download"`: what a simulated provider answers; `none` answers nothing,
    /// `signin` adds a not-signed-in failure. nil when the variable isn't set.
    public static func simulatedInfo(reporting text: String?) -> UbiquityInfo? {
        guard let text, !text.isEmpty else { return nil }
        let keys = Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var info = UbiquityInfo()
        if keys.contains(CloudStatusKey.ubiquitous.rawValue) { info.isUbiquitous = true }
        if keys.contains(CloudStatusKey.download.rawValue) { info.download = .current }
        if keys.contains(CloudStatusKey.downloading.rawValue) { info.isDownloading = false }
        if keys.contains(CloudStatusKey.uploading.rawValue) { info.isUploading = false }
        if keys.contains(CloudStatusKey.uploaded.rawValue) { info.isUploaded = true }
        if keys.contains(CloudStatusKey.conflicts.rawValue) { info.hasConflicts = false }
        if keys.contains("signin") {
            info.isUbiquitous = true
            info.downloadError = "The operation couldn't be completed. Not signed in."
            info.authenticationRequired = true
        }
        return info
    }

    /// `ARBOR_TEST_CLOUD_STATUS="a.txt=online,b.txt=available"`: fake statuses for the test root.
    public static func parseTestStatuses(_ text: String) -> [String: CloudStatus] {
        var result: [String: CloudStatus] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            // "error:<text>" takes the same route as a real provider's failure text.
            if parts[1].hasPrefix("error:") {
                result[parts[0]] = CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, downloadError: String(parts[1].dropFirst("error:".count))))
                continue
            }
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
