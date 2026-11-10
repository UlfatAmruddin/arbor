import Foundation
import CoreGraphics
import Darwin

/// Proves a PDF update from the two files alone (FE-152): the original is an exact prefix, Arbor's reader and Quartz both see the
/// requested values and nothing else changed, and the page count is the same. Any doubt refuses the change.
enum PDFVerifier {
    private static let streamKeys: Set<String> = ["Length", "Filter", "DecodeParms", "DL"]

    static func verify(_ edits: [EmbeddedField: String], original held: EmbeddedHeldFile, written url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EmbeddedFailure.documentUnverified }
        defer { close(descriptor) }
        guard let original = EmbeddedFileReader(descriptor: held.descriptor), let written = EmbeddedFileReader(descriptor: descriptor),
              written.size > original.size, original.sameBytes(0..<original.size, as: written, 0..<original.size),
              let before = try? PDFDocumentFacts(original), let after = try? PDFDocumentFacts(written),
              before.readOnlyReason == nil, after.readOnlyReason == nil, !PDFDocumentFacts.holdsSignatureMarkers(written),
              TagRegionVerifier.fieldsMatch(before.fields, after.fields, edits: edits),
              (try? onlyTheUpdateIsNew(before, after, originalSize: original.size)) == true,
              infoKept(before, after, edits), xmpKept(before, after, edits),
              quartzAgrees(edits, original: URL(fileURLWithPath: "/dev/fd/\(held.descriptor)"), written: url, hadXMP: before.metadata != nil) else {
            throw EmbeddedFailure.documentUnverified
        }
    }

    /// One new section after the original, pointing back at the old one, defining only the replaced objects (and itself).
    private static func onlyTheUpdateIsNew(_ before: PDFDocumentFacts, _ after: PDFDocumentFacts, originalSize: Int64) throws -> Bool {
        let old = before.structure, new = after.structure
        guard new.sections.count == old.sections.count + 1, new.start >= originalSize, new.sections[0].previous == old.start,
              new.sections[0].isStream == old.sections[0].isStream, after.root == before.root,
              before.info.map({ $0.id == after.info?.id }) ?? true, before.metadata?.id == after.metadata?.id else { return false }
        let replaced = Set([before.info?.id.number, before.metadata?.id.number].compactMap { $0 })
        for number in new.sections[0].numbers where !replaced.contains(number) {
            // Anything else is new, so no earlier section may know the number, whatever its /Size says.
            guard try old.entry(number) == nil else { return false }
            if number == after.info?.id.number { continue }
            guard case .offset(let offset, _)? = try new.entry(number), offset == new.start, new.sections[0].isStream else { return false }
        }
        return true
    }

    /// Every entry of the document information dictionary the edit didn't name, byte for byte.
    private static func infoKept(_ before: PDFDocumentFacts, _ after: PDFDocumentFacts, _ edits: [EmbeddedField: String]) -> Bool {
        let edited = Set(PDFDocumentFacts.infoKeys.filter { edits[$0.field] != nil }.map(\.key))
        func kept(_ facts: PDFDocumentFacts) -> [PDFDictionary.Entry] { (facts.info?.dictionary.entries ?? []).filter { !edited.contains($0.key) } }
        return kept(before).map { [$0.rawKey, $0.rawValue] } == kept(after).map { [$0.rawKey, $0.rawValue] }
    }

    private static func xmpKept(_ before: PDFDocumentFacts, _ after: PDFDocumentFacts, _ edits: [EmbeddedField: String]) -> Bool {
        guard let old = before.metadata else { return after.metadata == nil }
        guard let new = after.metadata, PDFXMP.sameApart(from: edits, old.xml, new.xml) else { return false }
        func kept(_ metadata: PDFDocumentFacts.Metadata) -> [[Data]] {
            metadata.dictionary.entries.filter { !streamKeys.contains($0.key) }.map { [$0.rawKey, $0.rawValue] }
        }
        return kept(old) == kept(new)
    }

    /// A second reader: Quartz opens both files, counts the same pages and shows the requested values in both places.
    private static func quartzAgrees(_ edits: [EmbeddedField: String], original: URL, written: URL, hadXMP: Bool) -> Bool {
        guard let old = CGPDFDocument(original as CFURL), let new = CGPDFDocument(written as CFURL) else { return false }
        // Dictionaries and streams belong to their document, which must outlive every read of them.
        return withExtendedLifetime((old, new)) { agree(edits, old, new, hadXMP: hadXMP) }
    }

    private static func agree(_ edits: [EmbeddedField: String], _ old: CGPDFDocument, _ new: CGPDFDocument, hadXMP: Bool) -> Bool {
        guard !old.isEncrypted, !new.isEncrypted, old.numberOfPages > 0, old.numberOfPages == new.numberOfPages, let info = new.info else { return false }
        let oldInfo = old.info
        for (field, key) in PDFDocumentFacts.infoKeys {
            let found = text(info, key)
            if let wanted = edits[field] {
                guard wanted.isEmpty ? found == nil : found.map({ Array($0.utf8) == Array(wanted.utf8) }) == true else { return false }
            } else if found != oldInfo.flatMap({ text($0, key) }) {
                return false
            }
        }
        guard hadXMP else { return true }
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        guard let catalog = new.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream,
              let xml = CGPDFStreamCopyData(stream, &format) as Data?, let fields = PDFXMP.fields(xml) else { return false }
        return edits.allSatisfy { field, wanted in
            wanted.isEmpty ? fields[field] == nil : fields[field].map { Array($0.text.utf8) == Array(wanted.utf8) } == true
        }
    }

    private static func text(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &string), let string, let text = CGPDFStringCopyTextString(string) as String?,
              !text.isEmpty else { return nil }
        return text
    }
}
