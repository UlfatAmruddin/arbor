import Foundation

/// The list of libraries and its rules (FE-076). Pure data: it has no way to touch a file, which is the FE-239 guarantee.
public struct LibraryCatalog: Equatable, Sendable {
    public static let maxLibraries = 200
    /// Read and write limit, so a list the app saved can always be read back.
    public static let maxBytes = 1 << 20

    public private(set) var libraries: [LibraryDefinition]

    /// nil data gives the defaults; hostile or damaged data gives whatever survives the rules.
    public init(data: Data?, home: URL) {
        guard let data, data.count <= Self.maxBytes,
              let decoded = try? JSONDecoder().decode([Lossy].self, from: data) else {
            libraries = LibraryLogic.defaults(home: home)
            return
        }
        libraries = []
        for library in decoded.compactMap({ $0.value.flatMap(Self.sanitized) }) {
            guard libraries.count < Self.maxLibraries else { break }
            if !isTaken(library.name) { libraries.append(library) }
        }
    }

    /// Throws `tooMany` rather than saving something `init(data:home:)` would refuse.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(libraries)
        guard data.count <= Self.maxBytes else { throw LibraryEditError.tooMany }
        return data
    }

    public func definition(_ name: String) -> LibraryDefinition? { libraries.first { $0.name == name } }

    // MARK: Editing

    /// Returns the name as stored.
    @discardableResult
    public mutating func create(named raw: String) throws -> String {
        let name = try LibraryLogic.cleanedName(raw)
        guard !isTaken(name) else { throw LibraryEditError.taken(name) }
        guard libraries.count < Self.maxLibraries else { throw LibraryEditError.tooMany }
        libraries.append(LibraryDefinition(name: name, folders: []))
        return name
    }

    /// Returns the new name as stored. Changing only the case of a name is allowed.
    @discardableResult
    public mutating func rename(_ name: String, to raw: String) throws -> String {
        guard let index = libraries.firstIndex(where: { $0.name == name }) else { throw LibraryEditError.notFound(name) }
        let cleaned = try LibraryLogic.cleanedName(raw)
        guard !isTaken(cleaned, except: name) else { throw LibraryEditError.taken(cleaned) }
        libraries[index].name = cleaned
        return cleaned
    }

    /// Only forgets the list entry; its folders and files are not involved (FE-239).
    @discardableResult
    public mutating func delete(_ name: String) -> Bool {
        guard let index = libraries.firstIndex(where: { $0.name == name }) else { return false }
        libraries.remove(at: index)
        return true
    }

    /// Never inserts: an edit that outlived its library must not bring it back.
    @discardableResult
    public mutating func update(_ library: LibraryDefinition) -> Bool {
        guard let index = libraries.firstIndex(where: { $0.name == library.name }) else { return false }
        libraries[index] = library
        return true
    }

    /// Adds the default libraries that are missing and returns how many; existing ones are left as they are.
    @discardableResult
    public mutating func restoreDefaults(home: URL) -> Int {
        let missing = LibraryLogic.defaults(home: home).filter { !isTaken($0.name) }.prefix(Self.maxLibraries - libraries.count)
        libraries += missing
        return missing.count
    }

    /// `base`, or `base (2)`, `base (3)`… for the first free name.
    public func nextAvailableName(base: String) -> String {
        guard isTaken(base) else { return base }
        return NameRules.keepBothName(for: base, treatAsFolder: true) { isTaken($0) }
    }

    // MARK: Rules

    private func isTaken(_ name: String, except own: String? = nil) -> Bool {
        libraries.contains { $0.name != own && LibraryLogic.sameName($0.name, name) }
    }

    private struct Lossy: Decodable {
        let value: LibraryDefinition?
        init(from decoder: Decoder) throws { value = try? LibraryDefinition(from: decoder) }
    }

    private static func isUsablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\u{0}") && path.utf8.count <= Int(PATH_MAX)
    }

    private static func sanitized(_ raw: LibraryDefinition) -> LibraryDefinition? {
        guard let name = try? LibraryLogic.cleanedName(raw.name) else { return nil }
        let saveLocation = raw.saveLocation.flatMap { isUsablePath($0) ? URL(fileURLWithPath: $0) : nil }
        return LibraryDefinition(name: name, folders: raw.folders.filter(isUsablePath).map { URL(fileURLWithPath: $0) },
                                 saveLocation: saveLocation, template: raw.template)
    }
}
