import Foundation
import Security

// MARK: - Apps and packages (FE-157, FE-160)

/// Version information of an app or other bundle (Explorer's Details tab for executables).
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

    /// "Universal (Apple silicon and Intel)", "Apple silicon", "Intel".
    public var architectureText: String? {
        switch architectures.count {
        case 0: return nil
        case 1: return architectures[0]
        default: return L10n.format("Universal (%@)", "\(architectures.joined(separator: " and "))")
        }
    }
}

/// Code signature of an app, tool or signed file: the Mac counterpart of Explorer's Digital
/// Signatures tab (FE-157). Validation can take a moment for large apps; run it off the main thread.
public struct CodeSignatureInfo: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case valid, unsigned, invalid(String)
    }

    public var status: Status
    public var identifier: String?
    public var teamIdentifier: String?
    /// Certificate chain names, leaf first ("Developer ID Application: Ana Lopez (ABCDE12345)", …).
    public var certificates: [String]
    public var signingDate: Date?
    public var isAdHoc: Bool

    public var signerName: String? {
        if isAdHoc { return L10n.tr("Ad hoc (no certificate)") }
        return certificates.first
    }

    public var statusText: String {
        switch status {
        case .valid: return isAdHoc ? L10n.tr("Signed locally (ad hoc). The signature is intact but doesn't identify a developer.") : L10n.tr("This digital signature is OK.")
        case .unsigned: return L10n.tr("This item isn't signed.")
        case .invalid(let reason): return L10n.format("This digital signature isn't valid: %@", "\(reason)")
        }
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
            let message = SecCopyErrorMessageString(check, nil) as String? ?? "error \(check)"
            status = .invalid(message)
        }
        return CodeSignatureInfo(status: status, identifier: identifier,
                                 teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                                 certificates: certificates,
                                 signingDate: (info[kSecCodeInfoTimestamp as String] ?? info[kSecCodeInfoTime as String]) as? Date,
                                 isAdHoc: isAdHoc)
    }
}

// MARK: - Volumes (drive Properties)

/// The facts behind a drive's General tab (name, type, file system, used/free/capacity).
public struct VolumeInfo: Equatable, Sendable {
    public var name: String
    public var typeText: String
    public var fileSystem: String
    public var capacity: Int64
    /// Free blocks right now.
    public var free: Int64
    /// Space macOS can make available for important files, which includes purgeable data (caches,
    /// local snapshots, optimized iCloud files). Never smaller than `free`.
    public var availableForImportantUsage: Int64
    public var isReadOnly: Bool
    public var isRoot: Bool
    public var canRename: Bool

    public var used: Int64 { max(capacity - free, 0) }
    public var purgeable: Int64 { max(availableForImportantUsage - free, 0) }
    /// Fraction used, 0…1 (for the pie chart).
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
            fileSystem: v.volumeLocalizedFormatDescription ?? "Unknown",
            capacity: capacity, free: free, availableForImportantUsage: important,
            isReadOnly: v.volumeIsReadOnly ?? false, isRoot: v.volumeIsRootFileSystem ?? false,
            canRename: v.volumeSupportsRenaming ?? false)
    }

    /// Explorer's drive types, in Mac terms.
    public static func typeText(local: Bool, isInternal: Bool?, removable: Bool, ejectable: Bool) -> String {
        if !local { return L10n.tr("Network Drive") }
        if removable { return L10n.tr("Removable Disk") }
        if isInternal == false || ejectable { return L10n.tr("External Disk") }
        return L10n.tr("Local Disk")
    }
}
