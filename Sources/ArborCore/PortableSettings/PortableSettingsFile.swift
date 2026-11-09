import Foundation

/// Why a settings file can't be used. The text is fixed and never repeats anything from the file.
public enum PortableSettingsError: LocalizedError, Equatable {
    case tooLarge, unreadable, notSettingsFile, newerVersion

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.tr("This file is too large to be an Arbor settings file.")
        case .unreadable: return L10n.tr("Arbor couldn't read this file. It may have moved, or its location may not be responding.")
        case .notSettingsFile: return L10n.tr("This isn't an Arbor settings file.")
        case .newerVersion: return L10n.tr("This settings file was made by a newer version of Arbor.")
        }
    }
}

/// What a settings file holds for one key.
enum PortableEntry: Equatable, Sendable, Decodable {
    case value(PortableValue)
    /// A null, a fractional or oversized number, an array or an object: never fatal to the rest of the file.
    case unsupported

    init(from decoder: Decoder) throws {
        if let value = try? PortableValue(from: decoder) { self = .value(value) } else { self = .unsupported }
    }
}

/// The portable settings file: `{ "format": "arbor.settings", "version": 1, "settings": { key: scalar } }`.
public struct PortableSettingsFile: Equatable, Sendable {
    public static let format = "arbor.settings"
    public static let version = 1
    /// A real file is about 1 KiB.
    public static let maxBytes = 64 * 1024

    let entries: [String: PortableEntry]

    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    private struct Body: Decodable {
        let settings: [String: PortableEntry]
    }

    private struct Contents: Encodable {
        let format: String
        let version: Int
        let settings: [String: PortableValue]
    }

    /// Walks the catalog itself, so nothing outside the allowlist can reach a file, even from a corrupted local preference.
    public static func encoded(reading read: (PortableSetting) -> PortableValue?) throws -> Data {
        var settings: [String: PortableValue] = [:]
        for setting in PortableSettingsCatalog.all { settings[setting.key] = setting.normalized(read(setting)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Contents(format: format, version: version, settings: settings))
    }

    /// Reads a regular file only, within `maxBytes`, whatever its size claims or becomes during the read.
    public static func read(from url: URL) throws -> PortableSettingsFile {
        guard let handle = FileHandle.openRegularFile(atPath: url.path) else { throw PortableSettingsError.unreadable }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw PortableSettingsError.unreadable }
        guard Int64(info.st_size) <= Int64(maxBytes) else { throw PortableSettingsError.tooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw PortableSettingsError.unreadable
        }
        guard data.count <= maxBytes else { throw PortableSettingsError.tooLarge }
        return try decode(data)
    }

    /// The header is decoded on its own, so a newer version may change the shape of `settings` and still be named as newer.
    public static func decode(_ data: Data) throws -> PortableSettingsFile {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == format else {
            throw PortableSettingsError.notSettingsFile
        }
        guard header.version <= version else { throw PortableSettingsError.newerVersion }
        guard header.version == version else { throw PortableSettingsError.notSettingsFile }
        guard let body = try? decoder.decode(Body.self, from: data) else { throw PortableSettingsError.notSettingsFile }
        return PortableSettingsFile(entries: body.settings)
    }
}
