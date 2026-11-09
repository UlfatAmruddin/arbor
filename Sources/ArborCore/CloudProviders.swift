import Foundation

/// What a CloudStorage folder name establishes about its account (FE-195).
public enum CloudAccountKind: String, Equatable, Hashable, Sendable {
    case personal, workOrSchool, unknown

    public var title: String {
        switch self {
        case .personal: return L10n.tr("Personal")
        case .workOrSchool: return L10n.tr("Work/School")
        case .unknown: return L10n.tr("Account unknown")
        }
    }
}

/// Where a hand-off goes. Every value comes from `CloudProviderCatalog`, so no folder name or path can reach a launch.
public enum CloudHandoff: Equatable, Hashable, Sendable {
    case application(bundleIdentifier: String)
    case settingsPane(URL)
}

/// One row of the provider table.
public struct CloudProviderEntry: Equatable, Hashable, Sendable {
    enum AccountRule: Hashable, Sendable {
        /// "Personal" or the organization's own name (OneDrive, Dropbox).
        case personalOrOrganization
        /// An address; only a consumer-only mail domain settles it (Google).
        case consumerMailDomain
        case alwaysOrganization
        case notEstablished
    }

    /// Lowercased name before the first separator of the CloudStorage folder.
    public let folderPrefix: String
    public let displayName: String
    /// Tried in order; empty where no identifier has been confirmed, so nothing is offered.
    public let bundleIdentifiers: [String]
    public let settingsPane: URL?
    let accountRule: AccountRule

    /// nil when neither the provider's app nor a settings pane is there to open.
    public func handoff(isInstalled: (String) -> Bool) -> CloudHandoff? {
        if let settingsPane { return .settingsPane(settingsPane) }
        return bundleIdentifiers.first(where: isInstalled).map { .application(bundleIdentifier: $0) }
    }

    public func commandTitle(needsSignIn: Bool) -> String {
        if needsSignIn { return L10n.format("Sign in to %@", displayName) }
        return settingsPane == nil ? L10n.format("Open %@", displayName) : L10n.tr("Open iCloud Settings")
    }

    func accountKind(of account: String?) -> CloudAccountKind {
        if accountRule == .alwaysOrganization { return .workOrSchool }
        guard let account = account?.lowercased() else { return .unknown }
        switch accountRule {
        case .personalOrOrganization:
            if account == "personal" { return .personal }
            // "Personal (1)" and addresses aren't the documented forms, so they settle nothing.
            return account.hasPrefix("personal") || account.contains("@") ? .unknown : .workOrSchool
        case .consumerMailDomain:
            return CloudProviderCatalog.consumerMailDomains.contains(account.components(separatedBy: "@").last ?? "") ? .personal : .unknown
        case .alwaysOrganization, .notEstablished:
            return .unknown
        }
    }
}

/// The one table of providers. Bundle identifiers are listed only where a vendor or catalog source confirms them.
public enum CloudProviderCatalog {
    public static let iCloud = CloudProviderEntry(
        folderPrefix: "", displayName: "iCloud Drive", bundleIdentifiers: [],
        settingsPane: URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud"), accountRule: .notEstablished)

    public static let entries: [CloudProviderEntry] = [
        entry("onedrive", "OneDrive", ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"], .personalOrOrganization),
        entry("googledrive", "Google Drive", ["com.google.drivefs"], .consumerMailDomain),
        entry("dropbox", "Dropbox", ["com.getdropbox.dropbox"], .personalOrOrganization),
        entry("box", "Box", ["com.box.desktop"], .notEstablished),
        entry("sharepoint", "SharePoint", [], .alwaysOrganization),
        entry("protondrive", "Proton Drive", [], .notEstablished),
        entry("synologydrive", "Synology Drive", [], .notEstablished),
        entry("pclouddrive", "pCloud Drive", [], .notEstablished),
        entry("nextcloud", "Nextcloud", [], .notEstablished),
        entry("megasync", "MEGA", [], .notEstablished),
        entry("icedrive", "Icedrive", [], .notEstablished),
    ]

    /// Google Workspace can't own these domains, so such an address is always a consumer account.
    static let consumerMailDomains: Set<String> = ["gmail.com", "googlemail.com"]

    private static func entry(_ prefix: String, _ name: String, _ identifiers: [String], _ rule: CloudProviderEntry.AccountRule) -> CloudProviderEntry {
        CloudProviderEntry(folderPrefix: prefix, displayName: name, bundleIdentifiers: identifiers, settingsPane: nil, accountRule: rule)
    }

    /// Whole-word only, so "OneDriveEvil" is not OneDrive.
    public static func entry(forFolderPrefix prefix: String) -> CloudProviderEntry? {
        let key = prefix.lowercased()
        return entries.first { $0.folderPrefix == key }
    }
}

/// What the name of a ~/Library/CloudStorage folder says.
public struct CloudFolderIdentity: Equatable, Sendable {
    public let provider: String
    public let account: String?
    public let accountKind: CloudAccountKind
    public let entry: CloudProviderEntry?
}

/// Reads a CloudStorage folder name. The name is outside input, and only ever becomes plain text or a table lookup.
public enum CloudFolderName {
    static let maxLength = 120
    private static let sharedLibraries = "sharedlibraries"

    /// "OneDrive-Personal", "OneDrive-Contoso Ltd", "GoogleDrive-a@b.org", "Dropbox", "Dropbox (Business)", "Box-Box".
    public static func parse(_ name: String) -> CloudFolderIdentity {
        let (prefix, rawAccount) = split(UntrustedText.display(name, limit: maxLength).trimmingCharacters(in: .whitespaces))
        let entry = CloudProviderCatalog.entry(forFolderPrefix: prefix)
        let provider = entry?.displayName ?? (prefix.isEmpty ? L10n.tr("Cloud storage") : prefix)
        var account = rawAccount?.trimmingCharacters(in: .whitespaces)
        if let shown = account, shown.isEmpty || shown.lowercased() == prefix.lowercased() || shown.lowercased() == provider.lowercased() {
            account = nil
        }
        // SharePoint libraries synced by OneDrive sit beside the same organization's own OneDrive folder.
        if entry?.folderPrefix == "onedrive", let shown = account, shown.lowercased().hasPrefix(sharedLibraries) {
            let organization = shown.dropFirst(sharedLibraries.count).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            let label = organization.isEmpty ? L10n.tr("Shared libraries") : L10n.format("%@ shared libraries", organization)
            return CloudFolderIdentity(provider: provider, account: label, accountKind: .workOrSchool, entry: entry)
        }
        return CloudFolderIdentity(provider: provider, account: account, accountKind: entry?.accountKind(of: account) ?? .unknown, entry: entry)
    }

    /// Whichever separator comes first, so "Dropbox (Acme-Corp)" and "OneDrive-Contoso (UK)" both keep their account whole.
    private static func split(_ name: String) -> (prefix: String, account: String?) {
        let dash = name.firstIndex(of: "-")
        if name.hasSuffix(")"), let open = name.range(of: " ("), dash.map({ open.lowerBound < $0 }) ?? true {
            return (String(name[..<open.lowerBound]), String(name[open.upperBound...].dropLast()))
        }
        guard let dash else { return (name, nil) }
        return (String(name[..<dash]), String(name[name.index(after: dash)...]))
    }
}
