import Foundation
import Darwin

/// Word, Excel and PowerPoint documents, macro-enabled ones too (FE-152): title, subject, authors, keywords, category and comments in
/// docProps/core.xml. The package is rewritten streamed: every other entry is copied byte for byte and only that part changes.
struct OfficeFormat: EmbeddedFormat {
    static let identifier = "org.openxmlformats.openxml"
    static let extensions: Set<String> = ["docx", "docm", "xlsx", "xlsm", "pptx", "pptm"]
    let typeIdentifiers: Set<String> = [identifier]
    /// Without ZIP64 no offset can go further.
    let maxFileBytes: Int64 = 0xFFFF_FFFF

    private static let oleSignature = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

    func inspect(_ url: URL, info: stat) -> EmbeddedInspection? {
        // Reading an online-only file would download it just to fill a panel.
        guard Self.extensions.contains(url.pathExtension.lowercased()), info.st_flags & UInt32(SF_DATALESS) == 0,
              let support = EmbeddedSupport.forType(Self.identifier) else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let file = EmbeddedFileReader(descriptor: descriptor) else { return nil }
        let (fields, reason) = Self.read(file)
        return EmbeddedInspection(typeIdentifier: Self.identifier, support: support, fields: fields, budgetBlock: nil,
                                  contentBlock: reason.map(EmbeddedFailure.structure))
    }

    private static func read(_ file: EmbeddedFileReader) -> (fields: [EmbeddedField: EmbeddedReader.Raw], reason: String?) {
        // Office saves a password-protected document as a compound file around the encrypted package.
        if file.bytes(at: 0, count: 8) == oleSignature {
            return ([:], L10n.tr("This document is encrypted or isn't stored as Office Open XML, so its properties are read-only."))
        }
        do {
            let package = try OfficePackage(file)
            guard let fields = OfficeCoreProperties.fields(try package.coreXML()) else { return ([:], unreadableCore) }
            return (fields, package.readOnlyReason)
        } catch {
            return ([:], (error as? EmbeddedFailure ?? OfficePackage.damaged).localizedDescription)
        }
    }

    private static let unreadableCore = L10n.tr("This Office document's core properties can't be read safely, so its properties are read-only.")

    func produce(_ edits: [EmbeddedField: String], from held: EmbeddedHeldFile, type: String, to staged: URL) throws {
        guard let file = EmbeddedFileReader(descriptor: held.descriptor) else { throw EmbeddedFailure.changedSinceRead }
        let package = try OfficePackage(file)
        if let reason = package.readOnlyReason { throw EmbeddedFailure.structure(reason) }
        guard let xml = OfficeCoreProperties.edited(try package.coreXML(), edits) else { throw EmbeddedFailure.structure(Self.unreadableCore) }
        try TagPieceWriter.write(try package.rewritten(core: xml), from: file, to: staged)
    }

    func verify(_ edits: [EmbeddedField: String], original held: EmbeddedHeldFile, written: URL, type: String) throws {
        guard let original = EmbeddedFileReader(descriptor: held.descriptor) else { throw EmbeddedFailure.changedSinceRead }
        try OfficeVerifier.verify(edits, original: original, written: written)
    }
}

/// Proves a rewritten package from the two files alone (FE-152): both directories re-read, every other entry's record, checksum and
/// bytes identical, and the new core.xml showing exactly the requested values with everything else kept. Any doubt refuses the change.
enum OfficeVerifier {
    static func verify(_ edits: [EmbeddedField: String], original: EmbeddedFileReader, written url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EmbeddedFailure.documentUnverified }
        defer { close(descriptor) }
        guard let written = EmbeddedFileReader(descriptor: descriptor),
              let before = try? OfficePackage(original), let after = try? OfficePackage(written),
              before.readOnlyReason == nil, after.readOnlyReason == nil, before.coreIndex == after.coreIndex,
              before.entries.count == after.entries.count, masked(before.end, [16..<20]) == masked(after.end, [16..<20]),
              entriesMatch(before, after), let old = try? before.coreXML(), let new = try? after.coreXML(),
              let oldFields = OfficeCoreProperties.fields(old), let newFields = OfficeCoreProperties.fields(new),
              TagRegionVerifier.fieldsMatch(oldFields, newFields, edits: edits),
              OfficeCoreProperties.sameApart(from: edits, old, new) else { throw EmbeddedFailure.documentUnverified }
    }

    /// Records equal but for their offset (and, for core.xml, its method, sizes and checksum); every other entry's bytes identical.
    private static func entriesMatch(_ before: OfficePackage, _ after: OfficePackage) -> Bool {
        zip(before.entries, after.entries).enumerated().allSatisfy { index, pair in
            let (old, new) = pair
            guard index != before.coreIndex else { return masked(old.record, [8..<12, 16..<28, 42..<46]) == masked(new.record, [8..<12, 16..<28, 42..<46]) }
            return masked(old.record, [42..<46]) == masked(new.record, [42..<46]) && old.crc == new.crc && old.extent.count == new.extent.count
                && before.file.sameBytes(old.extent, as: after.file, new.extent)
        }
    }

    private static func masked(_ data: Data, _ ranges: [Range<Int>]) -> Data {
        var copy = Data(data)
        for range in ranges where range.upperBound <= copy.count { copy.replaceSubrange(range, with: Data(count: range.count)) }
        return copy
    }
}
