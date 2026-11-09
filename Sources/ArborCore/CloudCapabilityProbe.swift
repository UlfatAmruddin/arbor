import Foundation

/// A status key a provider may answer for an item (FE-198).
public enum CloudStatusKey: String, CaseIterable, Sendable {
    case ubiquitous, download, downloading, uploading, uploaded, conflicts, downloadError, uploadError

    /// These stay empty on a healthy item, so their absence says nothing about the provider.
    public var answersOnlyOnFailure: Bool { self == .downloadError || self == .uploadError }

    func isAnswered(by info: UbiquityInfo) -> Bool {
        switch self {
        case .ubiquitous: return info.isUbiquitous != nil
        case .download: return info.download != nil
        case .downloading: return info.isDownloading != nil
        case .uploading: return info.isUploading != nil
        case .uploaded: return info.isUploaded != nil
        case .conflicts: return info.hasConflicts != nil
        case .downloadError: return info.downloadError != nil
        case .uploadError: return info.uploadError != nil
        }
    }

    var label: String {
        switch self {
        case .ubiquitous: return L10n.tr("cloud item")
        case .download: return L10n.tr("download state")
        case .downloading: return L10n.tr("downloading")
        case .uploading: return L10n.tr("uploading")
        case .uploaded: return L10n.tr("uploaded")
        case .conflicts: return L10n.tr("conflicts")
        case .downloadError: return L10n.tr("download errors")
        case .uploadError: return L10n.tr("upload errors")
        }
    }
}

/// How listing a provider's folders went.
public enum CloudEnumeration: Equatable, Sendable {
    case notChecked, succeeded, failed(String), signInRequired(String)

    public init(listingError error: Error) {
        if case ListingError.signInRequired(_, let message) = error {
            self = .signInRequired(message)
        } else {
            let message = CloudProviderError.message(error)
            self = CloudProviderError.requiresSignIn(error) ? .signInRequired(message) : .failed(message)
        }
    }
}

/// What one provider has actually been seen to report. It is fed the metadata already read for visible rows,
/// so it adds no reads and can never hydrate anything.
public struct CloudCapabilityProbe: Equatable, Sendable {
    /// Enough to cover what's on screen; later rows add nothing.
    public static let sampleLimit = 32
    /// A single odd row must not disable a provider's commands.
    public static let decisionSample = 3

    /// Each item counts once, however often its row is read again.
    private var sampledItems: Set<String> = []
    public var sampled: Int { sampledItems.count }
    public private(set) var ubiquitousItems = 0
    public private(set) var reported: Set<CloudStatusKey> = []
    public private(set) var enumeration = CloudEnumeration.notChecked
    private var itemNeedsSignIn = false

    public init() {}

    public var needsSignIn: Bool {
        if case .signInRequired = enumeration { return true }
        return itemNeedsSignIn
    }

    /// `info` is nil when the item's metadata couldn't be read, which establishes nothing.
    public mutating func observe(_ info: UbiquityInfo?, item: String) {
        guard let info else { return }
        if enumeration == .notChecked { enumeration = .succeeded }   // a row on screen means a listing worked
        if info.authenticationRequired { itemNeedsSignIn = true }
        if info.downloadError != nil { reported.insert(.downloadError) }
        if info.uploadError != nil { reported.insert(.uploadError) }
        guard sampled < Self.sampleLimit, sampledItems.insert(item).inserted else { return }
        if info.isUbiquitous == true { ubiquitousItems += 1 }
        reported.formUnion(CloudStatusKey.allCases.filter { $0.isAnswered(by: info) })
    }

    public mutating func recordListing(_ outcome: CloudEnumeration) { enumeration = outcome }

    /// Keys a healthy provider would have answered by now.
    public var notReported: [CloudStatusKey] {
        CloudStatusKey.allCases.filter { !$0.answersOnlyOnFailure && !reported.contains($0) }
    }

    /// Why Download and Free up space can't run for this provider; nil while nothing has established that.
    public func commandLimitation(provider: String) -> String? {
        if needsSignIn { return L10n.format("Sign in to %@ first.", provider) }
        guard sampled >= Self.decisionSample else { return nil }
        if ubiquitousItems == 0 {
            return L10n.format("%@ doesn't report these items to macOS as cloud items, so Arbor can't ask it to download them or free up space.", provider)
        }
        if !reported.contains(.download) {
            return L10n.format("%@ doesn't report whether items are on this Mac, so Arbor couldn't confirm the result.", provider)
        }
        return nil
    }

    /// One read-only line for where the provider's details show.
    public func summary(provider: String) -> String {
        var parts: [String] = []
        switch enumeration {
        case .notChecked: return L10n.format("What %@ reports hasn't been checked yet. Open this folder to check.", provider)
        case .succeeded: parts.append(L10n.tr("Listing works."))
        case .failed(let message): parts.append(L10n.format("Listing failed: %@", message))
        case .signInRequired: parts.append(L10n.tr("Listing needs sign-in."))
        }
        if sampled > 0 {
            let seen = CloudStatusKey.allCases.filter(reported.contains)
            parts.append(seen.isEmpty ? L10n.tr("Reports no status.") : L10n.format("Reports %@.", seen.map(\.label).joined(separator: ", ")))
            if !notReported.isEmpty, !seen.isEmpty { parts.append(L10n.format("Doesn't report %@.", notReported.map(\.label).joined(separator: ", "))) }
        }
        return parts.joined(separator: " ")
    }

    /// For scripted checks: fixed words, never a translated string or a path.
    public var logDescription: String {
        let listing: String
        switch enumeration {
        case .notChecked: listing = "not-checked"
        case .succeeded: listing = "ok"
        case .failed: listing = "failed"
        case .signInRequired: listing = "signin"
        }
        let names = CloudStatusKey.allCases.filter(reported.contains).map(\.rawValue).joined(separator: ",")
        return "listing=\(listing) sampled=\(sampled) ubiquitous=\(ubiquitousItems) reports=\(names.isEmpty ? "-" : names) signin=\(needsSignIn ? "yes" : "no")"
    }

    /// Changes something the navigation pane shows.
    func differsVisibly(from other: CloudCapabilityProbe) -> Bool {
        reported != other.reported || enumeration != other.enumeration || needsSignIn != other.needsSignIn
            || (sampled > 0) != (other.sampled > 0)
    }
}

/// One probe per provider root. A provider's behavior changes when its app updates or the user signs in,
/// so a result only lasts a few minutes.
public struct CloudCapabilityCache: Sendable {
    public static let lifetime: TimeInterval = 300

    private var entries: [String: (probe: CloudCapabilityProbe, started: Date)] = [:]

    public init() {}

    public func probe(forRoot root: String, at now: Date) -> CloudCapabilityProbe? {
        guard let entry = entries[root], now.timeIntervalSince(entry.started) <= Self.lifetime else { return nil }
        return entry.probe
    }

    /// Returns whether the change is one the navigation pane shows.
    @discardableResult
    public mutating func update(root: String, at now: Date, _ change: (inout CloudCapabilityProbe) -> Void) -> Bool {
        let current = probe(forRoot: root, at: now)
        var probe = current ?? CloudCapabilityProbe()
        change(&probe)
        entries[root] = (probe, current == nil ? now : entries[root]?.started ?? now)
        return probe.differsVisibly(from: current ?? CloudCapabilityProbe())
    }

    public var rootsNeedingSignIn: [String] { entries.filter { $0.value.probe.needsSignIn }.map(\.key) }

    public mutating func invalidate(root: String) { entries[root] = nil }

    public mutating func invalidateAll() { entries = [:] }
}

/// The tooltip of a provider's navigation pane node.
public enum CloudRootDescription {
    public static func tooltip(_ root: CloudRoot, probe: CloudCapabilityProbe?) -> String {
        var lines = [root.displayName]
        if let kind = root.accountKind { lines.append(kind == .unknown ? kind.title : L10n.format("%@ account", kind.title)) }
        if probe?.needsSignIn == true { lines.append(L10n.format("Sign in to %@", root.provider)) }
        lines.append((probe ?? CloudCapabilityProbe()).summary(provider: root.provider))
        lines.append(UntrustedText.display(root.url.path))
        return lines.joined(separator: "\n")
    }
}
