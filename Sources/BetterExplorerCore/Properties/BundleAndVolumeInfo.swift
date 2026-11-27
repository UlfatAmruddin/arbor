import Foundation
import Security

// MARK: - Apps and packages (FE-157, FE-160)

/// Bundle version info for the Details tab.
public struct BundleInfo: Equatable, Sendable {
    public var name: String?
    public var identifier: String?
    public var version: String?
    public var build: String?
    public var copyright: String?
    public var minimumSystem: String?
    public var architectures: [String]

    public static func read(_ url: URL) -> BundleInfo? {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }
        let archs = (bundle.executableArchitectures ?? []).compactMap { arch -> String? in
            switch arch.intValue {
            case NSBundleExecutableArchitectureARM64: return L10n.tr("Apple silicon")
            case NSBundleExecutableArchitectureX86_64: return L10n.tr("Intel")
            default: return nil
            }
        }
        return BundleInfo(name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
                          identifier: bundle.bundleIdentifier,
                          version: info["CFBundleShortVersionString"] as? String,
                          build: info["CFBundleVersion"] as? String,
                          copyright: info["NSHumanReadableCopyright"] as? String,
                          minimumSystem: info["LSMinimumSystemVersion"] as? String,
                          architectures: archs)
    }

    public var architectureText: String? {
        switch architectures.count {
        case 0: return nil
        case 1: return architectures[0]
        default: return L10n.format("Universal (%@)", "\(architectures.joined(separator: " and "))")
        }
    }
}

/// Code signature for the Digital Signatures tab (FE-157). Slow for large apps; read off the main thread.
public struct CodeSignatureInfo: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case valid, unsigned, invalid(String)
    }

    /// Who vouches for an intact signature. Only the Apple-anchored cases identify a developer.
    public enum Trust: Equatable, Sendable {
        case apple, appStore, developerID(notarized: Bool), appleCertificate, untrusted, adHoc
    }

    /// Code requirements, checked against the signature's certificate chain.
    public enum Requirement: String, CaseIterable, Sendable {
        case apple = "anchor apple"
        case appleIssued = "anchor apple generic"
        case appStore = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"
        case developerID = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        case notarized = "notarized"
    }

    public var status: Status
    public var identifier: String?
    /// Only set when an Apple-issued certificate vouches for it.
    public var teamIdentifier: String?
    /// Certificate chain names, leaf first.
    public var certificates: [String]
    public var signingDate: Date?
    public var isAdHoc: Bool
    public var trust: Trust = .untrusted
    /// False when the date is only the signer's own claim, not a secure timestamp.
    public var signingDateIsTimestamped = false

    /// A valid signature from a certificate Apple issued for distributing apps.
    public var isVerified: Bool {
        guard status == .valid else { return false }
        switch trust {
        case .apple, .appStore, .developerID: return true
        case .appleCertificate, .untrusted, .adHoc: return false
        }
    }

    /// An Apple-issued certificate identifies the signer.
    public var isAppleIssued: Bool { status == .valid && trust != .untrusted && trust != .adHoc }

    public var signingTimeText: String? {
        guard let signingDate else { return nil }
        let text = PropertyFormat.longDate(signingDate)
        // An unidentified signer can claim any time.
        if signingDateIsTimestamped || isAppleIssued { return text }
        return L10n.format("%@ (stated by the signer, not verified)", "\(text)")
    }

    public var signerName: String? {
        if isAdHoc { return L10n.tr("Ad hoc (no certificate)") }
        guard let leaf = certificates.first else { return nil }
        // A self-made certificate can carry any name.
        if trust == .untrusted { return L10n.format("Unknown developer (unverified name: %@)", "\(leaf)") }
        return leaf
    }

    public var statusText: String {
        switch status {
        case .valid:
            switch trust {
            case .apple: return L10n.tr("This digital signature is OK. Signed by Apple.")
            case .appStore: return L10n.tr("This digital signature is OK. From the Mac App Store.")
            case .developerID(notarized: true): return L10n.tr("This digital signature is OK. Signed with a Developer ID and notarized by Apple.")
            case .developerID(notarized: false): return L10n.tr("This digital signature is OK. Signed with a Developer ID issued by Apple.")
            case .appleCertificate: return L10n.tr("The signature is intact, but its Apple certificate isn't one for distributing apps (for example, a development certificate).")
            case .untrusted: return L10n.tr("Unknown developer. The signature is intact, but its certificate wasn't issued by Apple, so the signer can't be verified.")
            case .adHoc: return L10n.tr("Signed locally (ad hoc). The signature is intact but doesn't identify a developer.")
            }
        case .unsigned: return L10n.tr("This item isn't signed.")
        case .invalid(let reason): return L10n.format("This digital signature isn't valid: %@", "\(reason)")
        }
    }

    /// Classifies an intact signature from the requirements it satisfies.
    public static func trust(isAdHoc: Bool, satisfies: (Requirement) -> Bool) -> Trust {
        if isAdHoc { return .adHoc }
        guard satisfies(.appleIssued) else { return .untrusted }
        if satisfies(.apple) { return .apple }
        if satisfies(.appStore) { return .appStore }
        if satisfies(.developerID) { return .developerID(notarized: satisfies(.notarized)) }
        return .appleCertificate
    }

    public static func read(_ url: URL) -> CodeSignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return CodeSignatureInfo(status: .unsigned, certificates: [], isAdHoc: false)
        }
        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? [])
            .compactMap { SecCertificateCopySubjectSummary($0) as String? }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & 0x0002 != 0   // kSecCodeSignatureAdhoc
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let check = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        let status: Status
        switch check {
        case errSecSuccess: status = .valid
        case errSecCSUnsigned: status = .unsigned
        default:
            let message = SecCopyErrorMessageString(check, nil) as String? ?? L10n.format("error %d", check)
            status = .invalid(message)
        }
        let trust: Trust = status == .valid ? trust(isAdHoc: isAdHoc) { satisfies(code, $0) } : .untrusted
        let timestamp = info[kSecCodeInfoTimestamp as String] as? Date
        var result = CodeSignatureInfo(status: status, identifier: identifier, certificates: certificates,
                                       signingDate: timestamp ?? info[kSecCodeInfoTime as String] as? Date,
                                       isAdHoc: isAdHoc, trust: trust, signingDateIsTimestamped: timestamp != nil)
        if result.isAppleIssued { result.teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String }
        return result
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: Requirement) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement.rawValue as CFString, [], &req) == errSecSuccess, let req else { return false }
        // Chain only (contents hashed above); offline, so "notarized" needs a local ticket; every slice, so none vouches for another.
        let flags = SecCSFlags(rawValue: kSecCSBasicValidateOnly | kSecCSCheckAllArchitectures).union(.noNetworkAccess)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}

// MARK: - Volumes (drive Properties)

/// A drive's General tab facts.
public struct VolumeInfo: Equatable, Sendable {
    public var name: String
    public var typeText: String
    public var fileSystem: String
    public var capacity: Int64
    public var free: Int64
    /// Includes purgeable data (caches, snapshots, iCloud); never below `free`.
    public var availableForImportantUsage: Int64
    public var isReadOnly: Bool
    public var isRoot: Bool
    public var canRename: Bool

    public var used: Int64 { max(capacity - free, 0) }
    public var purgeable: Int64 { max(availableForImportantUsage - free, 0) }
    /// 0…1.
    public var usedFraction: Double { capacity > 0 ? min(max(Double(used) / Double(capacity), 0), 1) : 0 }

    public static func read(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey,
                                         .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey,
                                         .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsLocalKey,
                                         .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeSupportsRenamingKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let capacity = Int64(v.volumeTotalCapacity ?? 0)
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let important = max(v.volumeAvailableCapacityForImportantUsage ?? free, free)
        return VolumeInfo(
            name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
            typeText: typeText(local: v.volumeIsLocal ?? true, isInternal: v.volumeIsInternal,
                               removable: v.volumeIsRemovable ?? false, ejectable: v.volumeIsEjectable ?? false),
            fileSystem: v.volumeLocalizedFormatDescription ?? L10n.tr("Unknown"),
            capacity: capacity, free: free, availableForImportantUsage: important,
            isReadOnly: v.volumeIsReadOnly ?? false, isRoot: v.volumeIsRootFileSystem ?? false,
            canRename: v.volumeSupportsRenaming ?? false)
    }

    public static func typeText(local: Bool, isInternal: Bool?, removable: Bool, ejectable: Bool) -> String {
        if !local { return L10n.tr("Network Drive") }
        if removable { return L10n.tr("Removable Disk") }
        if isInternal == false || ejectable { return L10n.tr("External Disk") }
        return L10n.tr("Local Disk")
    }
}
