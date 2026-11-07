import Foundation

/// A shared folder offered by a server.
public struct NetworkShareInfo: Hashable, Sendable {
    public var name: String
    public var comment: String
    /// Administrative shares end in `$` (C$, IPC$); Explorer hides them from the server view.
    public var isHidden: Bool { name.hasSuffix("$") }

    public init(name: String, comment: String = "") {
        self.name = name
        self.comment = comment
    }
}

/// Reads `smbutil view` output (macOS's own SMB client). Only disk shares are kept.
///
///     Share                                           Type    Comments
///     -------------------------------
///     Media                                           Disk    Films and music
///     IPC$                                            Pipe    Remote IPC
///     2 shares listed
public enum SMBShareListParser {
    public static func parse(_ output: String) -> [NetworkShareInfo] {
        var shares: [NetworkShareInfo] = []
        var inTable = false
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("---") { inTable = true; continue }
            guard inTable, !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if line.range(of: #"^\d+ shares? listed"#, options: .regularExpression) != nil { break }
            guard let match = line.range(of: #"\s{2,}(Disk|Pipe|Printer|Device|Print Queue)(\s+|$)"#, options: .regularExpression) else { continue }
            let name = String(line[..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
            let type = line[match].trimmingCharacters(in: .whitespaces)
            let comment = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard type == "Disk", !name.isEmpty else { continue }
            shares.append(NetworkShareInfo(name: name, comment: comment))
        }
        return shares.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// One Bonjour advertisement (`_smb._tcp`, `_afpovertcp._tcp`, …).
public struct DiscoveredService: Hashable, Sendable {
    public var name: String
    public var type: String
    public var domain: String

    public init(name: String, type: String, domain: String = "local.") {
        self.name = name
        self.type = type
        self.domain = domain
    }
}

/// The Network page's groups, in Explorer's order (FE-078).
public enum NetworkCategory: String, CaseIterable, Sendable {
    case computer = "Computer"
    case mediaDevices = "Media Devices"
    case infrastructure = "Network Infrastructure"
}

/// A device on the network, merged from all its advertisements.
public struct NetworkDevice: Hashable, Sendable, Identifiable {
    public var name: String
    public var category: NetworkCategory
    /// Protocols it offers files over ("SMB", "AFP").
    public var protocols: [String]
    /// Bonjour service types seen, for resolving the host later.
    public var serviceTypes: [String]

    public var id: String { category.rawValue + "/" + name.lowercased() }

    public init(name: String, category: NetworkCategory, protocols: [String], serviceTypes: [String]) {
        self.name = name
        self.category = category
        self.protocols = protocols
        self.serviceTypes = serviceTypes
    }

    /// The preferred file protocol to connect with: SMB, else AFP.
    public var preferredScheme: String? {
        if serviceTypes.contains("_smb._tcp") { return "smb" }
        if serviceTypes.contains("_afpovertcp._tcp") { return "afp" }
        return nil
    }

    public var subtitle: String {
        switch category {
        case .computer: return protocols.isEmpty ? "Computer" : "Shared folders (" + protocols.joined(separator: ", ") + ")"
        case .mediaDevices: return "Media device"
        case .infrastructure: return "Network device"
        }
    }
}

public enum NetworkDiscoveryModel {
    /// Service types the Network page browses. Also listed in Info.plist `NSBonjourServices`.
    public static let fileServiceTypes = ["_smb._tcp", "_afpovertcp._tcp"]
    public static let infrastructureServiceTypes = ["_airport._tcp"]

    static func protocolName(_ type: String) -> String? {
        switch type {
        case "_smb._tcp": return "SMB"
        case "_afpovertcp._tcp": return "AFP"
        default: return nil
        }
    }

    /// Merges advertisements by name (a Mac advertising SMB and AFP is one computer) and sorts
    /// each group naturally. A file server is a computer even if it also advertises infrastructure.
    public static func devices(from services: Set<DiscoveredService>) -> [NetworkDevice] {
        var byName: [String: (name: String, types: Set<String>)] = [:]
        for service in services {
            let key = service.name.lowercased()
            var entry = byName[key] ?? (service.name, [])
            entry.types.insert(service.type)
            // Deterministic spelling when advertisements differ only in case.
            if service.name < entry.name { entry.name = service.name }
            byName[key] = entry
        }
        let devices = byName.values.map { entry -> NetworkDevice in
            let types = entry.types.sorted()
            let protocols = types.compactMap(protocolName)
            let category: NetworkCategory = protocols.isEmpty ? .infrastructure : .computer
            return NetworkDevice(name: entry.name, category: category, protocols: protocols, serviceTypes: types)
        }
        return devices.sorted {
            if $0.category != $1.category {
                return NetworkCategory.allCases.firstIndex(of: $0.category)! < NetworkCategory.allCases.firstIndex(of: $1.category)!
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - File system capabilities (FE-188)

/// What a volume's file system can do, from its type name and flags, so the UI never promises
/// writes, Trash or large files where the format can't deliver them.
public struct FileSystemCapabilities: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case apfs, hfsPlus, exFAT, fat, ntfs, smb, afp, nfs, webdav, other
    }

    public var kind: Kind
    public var typeName: String
    public var isReadOnly: Bool
    public var isCaseSensitive: Bool?

    public init(typeName: String, isReadOnly: Bool, isCaseSensitive: Bool? = nil) {
        self.typeName = typeName
        self.isReadOnly = isReadOnly
        self.isCaseSensitive = isCaseSensitive
        switch typeName.lowercased() {
        case "apfs": kind = .apfs
        case "hfs": kind = .hfsPlus
        case "exfat": kind = .exFAT
        case "msdos": kind = .fat
        case "ntfs": kind = .ntfs
        case "smbfs": kind = .smb
        case "afpfs": kind = .afp
        case "nfs": kind = .nfs
        case "webdav": kind = .webdav
        default: kind = .other
        }
    }

    public var isNetwork: Bool { [.smb, .afp, .nfs, .webdav].contains(kind) }

    /// Explorer's "File system" value.
    public var displayName: String {
        switch kind {
        case .apfs: return "APFS"
        case .hfsPlus: return "Mac OS Extended"
        case .exFAT: return "exFAT"
        case .fat: return "FAT32"
        case .ntfs: return "NTFS"
        case .smb: return "SMB"
        case .afp: return "AFP"
        case .nfs: return "NFS"
        case .webdav: return "WebDAV"
        case .other: return typeName.uppercased()
        }
    }

    /// FAT32 files can't reach 4 GB.
    public var maximumFileSize: Int64? { kind == .fat ? 4_294_967_295 : nil }

    public var canWrite: Bool { !isReadOnly }

    /// Plain-language limits worth telling the user, most important first.
    public var notes: [String] {
        var notes: [String] = []
        if kind == .ntfs && isReadOnly {
            notes.append("macOS can read NTFS drives but can't write to them.")
        } else if isReadOnly {
            notes.append("This drive is read-only.")
        }
        if kind == .fat { notes.append("Files larger than 4 GB can't be stored on FAT32.") }
        if kind == .exFAT || kind == .fat { notes.append("This format doesn't keep Mac permissions.") }
        if isNetwork { notes.append("Deleted items on network drives may be removed permanently instead of going to the Trash.") }
        return notes
    }
}
