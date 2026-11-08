import AppKit
import DiskArbitration
import ArborCore

/// Mounted volumes, named and ordered the same way for This Mac and the navigation pane.
enum VolumeCatalog {
    private static let baseKeys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeURLForRemountingKey,
    ]
    private static let capacityKeys: [URLResourceKey] = [
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey,
    ]

    /// Features adjust the drive list (e.g. network adds disconnected mapped drives). May run off main; no I/O.
    static let adjustments = Pipeline<[VolumeSummary], Void>(
        "VolumeCatalog.adjustments", "Adjusts the drive list (mapped and disconnected network drives). May run off the main thread.",
        signature: "(volumes) -> volumes")
    /// Per-drive icon and status text overrides (network drives, disconnected mapped drives). No I/O.
    static let iconOverride = Handlers<(VolumeSummary, CGFloat), NSImage>(
        "VolumeCatalog.iconOverride", "A drive's icon on This Mac; nil = the kind's icon.", signature: "(volume, size) -> icon?")
    static let statusOverride = Handlers<VolumeSummary, String>(
        "VolumeCatalog.statusOverride", "A drive's status line on This Mac; nil = free space.", signature: "(volume) -> text?")

    /// Every visible mounted volume. `detailed` adds free space, file system and disk-image/optical kind
    /// from Disk Arbitration; call it off the main thread.
    static func summaries(detailed: Bool) -> [VolumeSummary] {
        adjustments.apply(mountedSummaries(detailed: detailed))
    }

    private static func mountedSummaries(detailed: Bool) -> [VolumeSummary] {
        let keys = baseKeys + (detailed ? capacityKeys : [])
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let session = detailed ? DASessionCreate(kCFAllocatorDefault) : nil
        return urls.map { url in
            let url = url.standardizedFileURL
            let v = try? url.resourceValues(forKeys: Set(keys))
            var kind: VolumeSummary.Kind
            if v?.volumeIsLocal == false { kind = .network }
            else if v?.volumeIsRootFileSystem == true || url.path == "/" { kind = .startup }
            else if v?.volumeIsInternal == true { kind = .internal }
            else if v?.volumeIsRemovable == true { kind = .removable }
            else { kind = .external }
            if let session, kind != .network, kind != .startup, let special = diskKind(url, session: session) { kind = special }
            let server = v?.volumeURLForRemounting?.host
            let name = VolumeSections.displayName(volumeName: v?.volumeLocalizedName ?? displayName(of: url), kind: kind, server: server)
            var free: Int64?
            if detailed {
                // "Available" includes purgeable space; fall back to the plain figure.
                if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { free = important }
                else { free = v?.volumeAvailableCapacity.map(Int64.init) }
            }
            return VolumeSummary(url: url, name: name, kind: kind, total: v?.volumeTotalCapacity.map(Int64.init), free: free,
                                 isEjectable: (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false),
                                 isReadOnly: v?.volumeIsReadOnly ?? false, fileSystem: v?.volumeLocalizedFormatDescription)
        }
    }

    /// Disk images and optical discs, which URL resource values can't tell apart from external disks.
    private static func diskKind(_ url: URL, session: DASession) -> VolumeSummary.Kind? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        let proto = (description[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        let media = (description[kDADiskDescriptionMediaKindKey as String] as? String) ?? ""
        if model.contains("Disk Image") || proto.contains("Disk Image") { return .diskImage }
        if media.contains("CD") || media.contains("DVD") || media.contains("BD") { return .optical }
        return nil
    }

    /// Nav pane rows under "This Mac": same names, order and "Hide empty drives" rule as the page.
    static func navigationNodes() -> [NavNode] {
        VolumeSections.visible(summaries(detailed: false), hideEmpty: Prefs.hideEmptyDrives).map {
            NavNode(kind: .volume, title: $0.name, location: .folder($0.url), isEjectable: $0.isEjectable)
        }
    }

    static func icon(for kind: VolumeSummary.Kind, size: CGFloat) -> NSImage {
        let p = IconProvider.shared
        switch kind {
        case .startup, .internal: return p.symbolIcon("internaldrive.fill", color: 0x6E6E6E, size: size)
        case .external: return p.symbolIcon("externaldrive.fill", color: 0x6E6E6E, size: size)
        case .removable: return p.symbolIcon("mediastick", color: 0x6E6E6E, size: size)
        case .optical: return p.symbolIcon("opticaldisc.fill", color: 0x6E6E6E, size: size)
        case .diskImage: return p.symbolIcon("shippingbox.fill", color: 0x8A6D1F, size: size)
        case .network: return p.symbolIcon("server.rack", color: 0x6E6E6E, size: size)
        }
    }
}
