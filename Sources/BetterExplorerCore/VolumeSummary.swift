import Foundation

// This Mac logic (FE-074): drive kinds, sections, names and Explorer-style capacity text.

/// One mounted volume as This Mac shows it.
public struct VolumeSummary: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case startup, `internal`, external, removable, optical, diskImage, network

        /// Explorer's "Type" wording adapted to Mac volumes.
        public var typeName: String {
            switch self {
            case .startup: return L10n.tr("Startup disk")
            case .internal: return L10n.tr("Local disk")
            case .external: return L10n.tr("External disk")
            case .removable: return L10n.tr("Removable disk")
            case .optical: return L10n.tr("CD/DVD drive")
            case .diskImage: return L10n.tr("Disk image")
            case .network: return L10n.tr("Network drive")
            }
        }

        /// Order: startup disk, other internal, attached (external, removable, optical, images), then network.
        public var sortRank: Int {
            switch self {
            case .startup: return 0
            case .internal: return 1
            case .external, .removable, .optical, .diskImage: return 2
            case .network: return 3
            }
        }
    }

    public var url: URL
    public var name: String
    public var kind: Kind
    public var total: Int64?
    public var free: Int64?
    public var isEjectable: Bool
    public var isReadOnly: Bool
    public var fileSystem: String?

    public init(url: URL, name: String, kind: Kind, total: Int64? = nil, free: Int64? = nil,
                isEjectable: Bool = false, isReadOnly: Bool = false, fileSystem: String? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.total = total
        self.free = free
        self.isEjectable = isEjectable
        self.isReadOnly = isReadOnly
        self.fileSystem = fileSystem
    }

    /// No media (empty card reader or disc drive). Network shares often report nothing, so never count as empty.
    public var isEmptyDrive: Bool { kind != .network && (total ?? 0) <= 0 }
}

public enum VolumeSections {
    public static let devicesAndDrives = L10n.tr("Devices and drives")
    public static let networkLocations = L10n.tr("Network locations")

    public static func sorted(_ volumes: [VolumeSummary]) -> [VolumeSummary] {
        volumes.sorted { a, b in
            if a.kind.sortRank != b.kind.sortRank { return a.kind.sortRank < b.kind.sortRank }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.url.path < b.url.path
        }
    }

    /// Listed volumes ("Hide empty drives" drops those without media).
    public static func visible(_ volumes: [VolumeSummary], hideEmpty: Bool) -> [VolumeSummary] {
        sorted(hideEmpty ? volumes.filter { !$0.isEmptyDrive } : volumes)
    }

    /// Explorer's This PC groups: "Devices and drives", then "Network locations" when there are any.
    public static func sections(_ volumes: [VolumeSummary], hideEmpty: Bool) -> [(title: String, volumes: [VolumeSummary])] {
        let shown = visible(volumes, hideEmpty: hideEmpty)
        let local = shown.filter { $0.kind != .network }
        let network = shown.filter { $0.kind == .network }
        var result: [(title: String, volumes: [VolumeSummary])] = []
        if !local.isEmpty { result.append((devicesAndDrives, local)) }
        if !network.isEmpty { result.append((networkLocations, network)) }
        return result
    }

    /// The volume name; network shares add the server, like Explorer's `share (\\server)` (no drive letter, reference §16).
    public static func displayName(volumeName: String, kind: VolumeSummary.Kind, server: String?) -> String {
        guard kind == .network, let server, !server.isEmpty,
              server.caseInsensitiveCompare(volumeName) != .orderedSame else { return volumeName }
        return "\(volumeName) (\(server))"
    }
}

/// Capacity text and bar state for drive tiles.
public enum CapacityText {
    /// Three significant digits, truncated so free space is never overstated ("15.9 GB", "512 bytes").
    /// Decimal units (1 GB = 1,000,000,000 bytes), like the rest of macOS.
    public static func size(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return L10n.plural(one: "%lld byte", other: "%lld bytes", Int(clamping: max(0, bytes))) }
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000, unit < SizeUnit.last { value /= 1000; unit += 1 }
        let decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        let factor = pow(10, Double(decimals))
        // Small epsilon so 15.9 doesn't become 15.8 through binary rounding.
        let truncated = (value * factor + 1e-9).rounded(.down) / factor
        return SizeUnit.text(SizeUnit.number(truncated, decimals: decimals), unit: unit)
    }

    /// "120 GB free of 476 GB" (Windows 11 This PC wording).
    public static func freeOfTotal(free: Int64, total: Int64) -> String {
        L10n.format("%@ free of %@", "\(size(max(0, free)))", "\(size(max(0, total)))")
    }

    /// Fraction of the drive in use, 0…1 (0 when unknown).
    public static func usedFraction(free: Int64?, total: Int64?) -> Double {
        guard let total, total > 0, let free else { return 0 }
        return min(1, max(0, Double(total - free) / Double(total)))
    }

    /// Explorer turns the bar red when less than 10% is free.
    public static func isNearlyFull(free: Int64?, total: Int64?) -> Bool {
        guard let total, total > 0, let free else { return false }
        return Double(free) / Double(total) < 0.10
    }
}
