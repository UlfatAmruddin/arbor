import Foundation

/// PDF documents (FE-152): title, author, subject and keywords, written by an incremental update after the last original byte,
/// so the original stays in place as an exact prefix. The XMP copy, when there is one, is replaced alongside.
struct PDFFormat: TagRegionFormat {
    static let identifier = "com.adobe.pdf"
    let typeIdentifier = identifier

    /// Small enough to search for signature markers whenever the panel opens; larger files are searched when saving.
    private static let scanWhenReadingBytes: Int64 = 64 << 20

    func layout(of file: EmbeddedFileReader) -> TagLayout? {
        guard file.bytes(at: 0, count: 5) == Data("%PDF-".utf8) else { return nil }
        do {
            let document = try PDFDocumentFacts(file)
            var layout = TagLayout(region: file.size..<file.size)
            layout.fields = document.fields
            if let reason = document.readOnlyReason {
                layout.block(reason)
            } else if file.size <= Self.scanWhenReadingBytes, PDFDocumentFacts.holdsSignatureMarkers(file) {
                layout.block(PDFDocumentFacts.signed)
            }
            return layout
        } catch {
            return TagLayout(blocked: (error as? EmbeddedFailure ?? PDFStructure.damaged).localizedDescription)
        }
    }

    func regionPieces(for edits: [EmbeddedField: String], in layout: TagLayout, of file: EmbeddedFileReader) throws -> [TagPiece] {
        if PDFDocumentFacts.holdsSignatureMarkers(file) { throw EmbeddedFailure.structure(PDFDocumentFacts.signed) }
        let document = try PDFDocumentFacts(file)
        if let reason = document.readOnlyReason { throw EmbeddedFailure.structure(reason) }
        return [.bytes(try PDFUpdate.bytes(document, edits))]
    }

    func verify(_ edits: [EmbeddedField: String], original held: EmbeddedHeldFile, written: URL, type: String) throws {
        try PDFVerifier.verify(edits, original: held, written: written)
    }
}
