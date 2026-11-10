import Foundation

/// What a PDF's properties are and where they live: the document information dictionary and the catalog's XMP stream (FE-152).
struct PDFDocumentFacts {
    static let signed = L10n.tr("This PDF is signed or has a signature field, and changing it could invalidate the signature, so its properties are read-only.")
    static let unsafeXMP = L10n.tr("This PDF's XMP metadata can't be updated safely, so its properties are read-only.")
    private static let maxFormFields = 16_384

    static let infoKeys: [(field: EmbeddedField, key: String)] = [(.title, "Title"), (.author, "Author"), (.subject, "Subject"), (.keywords, "Keywords")]

    struct Metadata {
        let id: PDFObjectID
        let dictionary: PDFDictionary
        let xml: Data
    }

    let structure: PDFStructure
    let root: PDFObjectID
    let info: (id: PDFObjectID, dictionary: PDFDictionary)?
    let metadata: Metadata?
    let fields: [EmbeddedField: EmbeddedReader.Raw]
    /// Why an otherwise readable file can't be written.
    let readOnlyReason: String?

    /// Throws `EmbeddedFailure.structure` when the file can't be read at all.
    init(_ file: EmbeddedFileReader) throws {
        structure = try PDFStructure(file)
        let trailer = structure.trailer
        guard case .reference(let root)? = trailer["Root"], let catalog = try structure.dictionary(.reference(root)),
              catalog["Type"] == .name("Catalog"), catalog["Pages"] != nil else { throw PDFStructure.damaged }
        // A classic table's ten digits can't point past here.
        guard structure.sections[0].isStream || file.size < 9_000_000_000 else { throw EmbeddedFailure.tooLarge }
        self.root = root

        switch trailer["Info"] {
        case nil: info = nil
        case .reference(let id)?:
            guard let dictionary = try structure.dictionary(.reference(id)) else { throw PDFStructure.damaged }
            info = (id, dictionary)
        default: throw PDFStructure.damaged
        }

        var reason = try Self.signatureReason(catalog, structure)
        var xmpFields: [EmbeddedField: EmbeddedReader.Raw] = [:]
        switch catalog["Metadata"] {
        case nil: metadata = nil
        case .reference(let id)?:
            guard let object = try structure.object(id), case .dictionary(let dictionary) = object.value, let start = object.streamStart else {
                throw PDFStructure.damaged
            }
            let xml = try? structure.decoded(dictionary, structure.streamRange(dictionary, start: start), limit: SafeXML.maxBytes)
            if let xml, let found = PDFXMP.fields(xml) {
                metadata = Metadata(id: id, dictionary: dictionary, xml: xml)
                xmpFields = found
            } else {
                metadata = nil
                reason = reason ?? Self.unsafeXMP
            }
        default: throw PDFStructure.damaged
        }
        readOnlyReason = reason

        var fields: [EmbeddedField: EmbeddedReader.Raw] = [:]
        for (field, key) in Self.infoKeys {
            let stored = try Self.infoText(info?.dictionary[key], structure), xmp = xmpFields[field]
            // Readers prefer XMP, so that is what is shown; an edit writes both.
            guard let shown = xmp ?? stored else { continue }
            fields[field] = EmbeddedReader.Raw(text: shown.text, canEdit: (stored?.canEdit ?? true) && (xmp?.canEdit ?? true))
        }
        self.fields = fields
    }

    private static func infoText(_ value: PDFValue?, _ structure: PDFStructure) throws -> EmbeddedReader.Raw? {
        guard let value else { return nil }
        guard case .string(let bytes)? = try structure.resolved(value) else { return EmbeddedReader.Raw(text: "", canEdit: false) }
        guard let text = PDFText.decode(bytes) else { return EmbeddedReader.Raw(text: "", canEdit: false) }
        return text.isEmpty ? nil : EmbeddedReader.Raw(text: text)
    }

    /// Any update, even appended, can invalidate a signature or break a document's change permissions.
    private static func signatureReason(_ catalog: PDFDictionary, _ structure: PDFStructure) throws -> String? {
        if catalog["Perms"] != nil { return signed }
        guard let form = try structure.dictionary(catalog["AcroForm"]) else { return nil }
        if let flags = try structure.resolved(form["SigFlags"]), flags != .integer(0), flags != .null { return signed }
        guard let list = try structure.resolved(form["Fields"]), list != .null else { return nil }
        guard case .array(var pending) = list else { throw PDFStructure.damaged }
        // Counting what is queued, not what is visited, so one Kids array shared by many fields can't multiply the list.
        var queued = pending.count
        var seen = Set<PDFObjectID>()
        while queued <= maxFormFields, let next = pending.popLast() {
            if case .reference(let id) = next, !seen.insert(id).inserted { continue }
            guard let field = try structure.dictionary(next) else { continue }
            if try structure.resolved(field["FT"]) == .name("Sig") { return signed }
            guard case .array(let kids)? = try structure.resolved(field["Kids"]) else { continue }
            queued += kids.count
            if queued <= maxFormFields { pending += kids }
        }
        return queued <= maxFormFields ? nil : signed
    }

    /// The literal markers of a signature or change permissions, searched for across the whole file.
    static func holdsSignatureMarkers(_ file: EmbeddedFileReader) -> Bool {
        let markers = [Data("/ByteRange".utf8), Data("/Perms".utf8)]
        let overlap: Int64 = 16
        var offset: Int64 = 0
        while offset < file.size {
            let count = Int(min(Int64(EmbeddedFileReader.chunkSize) + overlap, file.size - offset))
            guard let chunk = file.bytes(at: offset, count: count) else { return true }
            if markers.contains(where: { chunk.range(of: $0) != nil }) { return true }
            offset += Int64(EmbeddedFileReader.chunkSize)
        }
        return false
    }
}

/// The bytes appended to a PDF for an edit: replaced objects and a cross-reference section of the same kind as the file's newest one.
enum PDFUpdate {
    private static let streamKeys: Set<String> = ["Length", "Filter", "DecodeParms", "DL", "F", "FFilter", "FDecodeParms"]
    private static let sectionKeys: Set<String> = ["Size", "Prev", "XRefStm", "Type", "W", "Index"]

    static func bytes(_ document: PDFDocumentFacts, _ edits: [EmbeddedField: String]) throws -> Data {
        let structure = document.structure
        // At most two new objects, which must stay valid object numbers.
        guard structure.firstUnusedNumber < (1 << 31) - 2 else { throw PDFStructure.damaged }
        var next = structure.firstUnusedNumber
        var objects: [(id: PDFObjectID, body: Data)] = []
        var newInfo: PDFObjectID?

        if edits.keys.contains(where: { field in PDFDocumentFacts.infoKeys.contains { $0.field == field } }) {
            let (body, isEmpty) = infoDictionary(document.info?.dictionary, edits)
            if let id = document.info?.id {
                objects.append((id, body))
            } else if !isEmpty {
                let id = PDFObjectID(number: next, generation: 0)
                next += 1
                newInfo = id
                objects.append((id, body))
            }
        }
        if let metadata = document.metadata {
            guard let xml = PDFXMP.edited(metadata.xml, edits) else { throw EmbeddedFailure.writeFailed }
            var body = Data("<<".utf8)
            for entry in metadata.dictionary.entries where !streamKeys.contains(entry.key) { body += entry.rawKey + Data(" ".utf8) + entry.rawValue }
            body += Data("/Length \(xml.count)>>\nstream\n".utf8) + xml + Data("\nendstream".utf8)
            objects.append((metadata.id, body))
        }
        guard !objects.isEmpty else { throw EmbeddedFailure.writeFailed }

        let base = structure.file.size
        var out = Data("\n".utf8)
        var offsets: [(id: PDFObjectID, offset: Int64)] = []
        for (id, body) in objects {
            offsets.append((id, base + Int64(out.count)))
            out += Data("\(id.number) \(id.generation) obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }

        var trailer = Data()
        for entry in structure.trailer.entries where !sectionKeys.contains(entry.key) && !streamKeys.contains(entry.key) {
            trailer += entry.rawKey + Data(" ".utf8) + entry.rawValue
        }
        if let newInfo { trailer += Data("/Info \(newInfo.number) \(newInfo.generation) R".utf8) }
        trailer += Data("/Prev \(structure.start)".utf8)

        let sectionOffset = base + Int64(out.count)
        if structure.sections[0].isStream {
            let id = PDFObjectID(number: next, generation: 0)
            next += 1
            offsets.append((id, sectionOffset))
            let sorted = offsets.sorted { $0.id.number < $1.id.number }
            out += xrefStream(id, sorted, size: next, trailer: trailer)
        } else {
            let sorted = offsets.sorted { $0.id.number < $1.id.number }
            out += Data("xref\n".utf8)
            for (id, offset) in sorted { out += Data(String(format: "%d 1\n%010lld %05d n\r\n", id.number, offset, id.generation).utf8) }
            out += Data("trailer\n<</Size \(next)".utf8) + trailer + Data(">>\n".utf8)
        }
        out += Data("startxref\n\(sectionOffset)\n%%EOF\n".utf8)
        return out
    }

    /// Every entry the edit doesn't name keeps its bytes; edited values take their old place, new ones go last.
    private static func infoDictionary(_ old: PDFDictionary?, _ edits: [EmbeddedField: String]) -> (body: Data, isEmpty: Bool) {
        var body = Data("<<".utf8)
        var placed = Set<String>(), count = 0
        for entry in old?.entries ?? [] {
            if let field = PDFDocumentFacts.infoKeys.first(where: { $0.key == entry.key })?.field, let value = edits[field] {
                placed.insert(entry.key)
                guard !value.isEmpty else { continue }
                body += entry.rawKey + Data(" ".utf8) + PDFText.encoded(value)
            } else {
                body += entry.rawKey + Data(" ".utf8) + entry.rawValue
            }
            count += 1
        }
        for (field, key) in PDFDocumentFacts.infoKeys where !placed.contains(key) {
            guard let value = edits[field], !value.isEmpty else { continue }
            body += Data("/\(key) ".utf8) + PDFText.encoded(value)
            count += 1
        }
        return (body + Data(">>".utf8), count == 0)
    }

    /// Uncompressed, so the section is as plain as a table while staying the kind of section the file's readers expect.
    private static func xrefStream(_ id: PDFObjectID, _ offsets: [(id: PDFObjectID, offset: Int64)], size: Int, trailer: Data) -> Data {
        let largest = offsets.map(\.offset).max() ?? 0
        var width = 1
        while width < 8, largest >> (width * 8) != 0 { width += 1 }
        var rows = Data()
        for (object, offset) in offsets {
            rows.append(1)
            rows += Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: offset >> ($0 * 8)) })
            rows += Data.bigEndian(object.generation, bytes: 2)
        }
        let index = offsets.map { "\($0.id.number) 1" }.joined(separator: " ")
        var out = Data("\(id.number) 0 obj\n<</Type/XRef/Size \(size)/W[1 \(width) 2]/Index[\(index)]/Length \(rows.count)".utf8)
        out += trailer + Data(">>\nstream\n".utf8) + rows + Data("\nendstream\nendobj\n".utf8)
        return out
    }
}
