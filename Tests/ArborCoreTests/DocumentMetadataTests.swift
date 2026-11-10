import Foundation
import CoreGraphics
import Testing
@testable import ArborCore

/// FE-152: PDF and Office round trips. Built bytes in disposable folders; "Trash" is a folder inside the fixture.
@Suite struct DocumentMetadataTests {
    private typealias F = DocumentFixtures

    private func write(_ bytes: Data, _ name: String, in fixture: Fixture) throws -> URL {
        let url = fixture.url(name)
        try bytes.write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> EmbeddedSnapshot { try #require(EmbeddedSnapshot.read(url)) }

    @discardableResult
    private func save(_ edits: [EmbeddedField: String], _ url: URL, in fixture: Fixture) throws -> EmbeddedMetadataEditor.Revert {
        try EmbeddedMetadataEditor.save(edits, over: try read(url), dispose: AudioFixtures.dispose(into: fixture))
    }

    private func quartzInfo(_ url: URL, _ key: String) -> String? {
        // The dictionary belongs to the document, which must outlive the read.
        guard let document = CGPDFDocument(url as CFURL), let info = document.info else { return nil }
        defer { withExtendedLifetime(document) {} }
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, key, &string), let string else { return nil }
        return CGPDFStringCopyTextString(string) as String?
    }

    private let pdfEdits: [EmbeddedField: String] = [.title: "New (title) \\ 写真 🌳", .author: "Ünï Çödé", .subject: "Line one\nline two", .keywords: "alpha, beta"]

    private func expectPDFRoundTrip(_ original: Data, name: String = "a.pdf", in fixture: Fixture) throws -> URL {
        let url = try write(original, name, in: fixture)
        let before = try read(url)
        #expect(before.typeIdentifier == PDFFormat.identifier)
        #expect(before.blocked == nil, "\(String(describing: before.blocked?.localizedDescription))")
        #expect(before.editable == [.title, .subject, .author, .keywords])
        let pages = CGPDFDocument(url as CFURL)?.numberOfPages
        try save(pdfEdits, url, in: fixture)
        let after = try read(url)
        for (field, value) in pdfEdits { #expect(after.values[field] == value, "\(field)") }
        let written = try Data(contentsOf: url)
        #expect(written.prefix(original.count) == original)
        #expect(CGPDFDocument(url as CFURL)?.numberOfPages == pages)
        #expect(quartzInfo(url, "Title") == pdfEdits[.title])
        #expect(quartzInfo(url, "Subject") == pdfEdits[.subject])
        #expect(after.blocked == nil)
        return url
    }

    // MARK: PDF

    @Test func classicTablePDFRoundTripsAsAnAppendedUpdate() throws {
        let fixture = try Fixture()
        let url = try expectPDFRoundTrip(F.pdf(), in: fixture)
        let written = try Data(contentsOf: url)
        #expect(quartzInfo(url, "Producer") == "Fixture producer")
        #expect(written.range(of: Data("/CreationDate (D:20240102030405Z)".utf8), in: F.pdf().count..<written.count) != nil)
        #expect(written.range(of: Data("/Type/XRef".utf8)) == nil)
        // A second edit chains another update onto the first.
        try save([.title: "Third"], url, in: fixture)
        #expect(try read(url).values[.title] == "Third")
        #expect(try read(url).values[.author] == pdfEdits[.author])
    }

    @Test func aPDFWithoutInformationGetsANewDictionary() throws {
        let fixture = try Fixture()
        let url = try write(F.pdf(info: nil), "a.pdf", in: fixture)
        #expect(try read(url).values.isEmpty)
        try save([.title: "Fresh"], url, in: fixture)
        #expect(try read(url).values[.title] == "Fresh")
        #expect(quartzInfo(url, "Title") == "Fresh")
    }

    @Test func objectAndCrossReferenceStreamsRoundTripWithAStreamUpdate() throws {
        let fixture = try Fixture()
        let original = F.pdfWithObjectStreams()
        let url = try expectPDFRoundTrip(original, in: fixture)
        let written = try Data(contentsOf: url)
        #expect(written.range(of: Data("/Type/XRef".utf8), in: original.count..<written.count) != nil)
        #expect(written.range(of: Data("\nxref\n".utf8), in: original.count..<written.count) == nil)
    }

    @Test func anIncrementallyUpdatedPDFReadsItsNewestValuesAndKeepsItsChain() throws {
        let fixture = try Fixture()
        let original = F.incrementallyUpdatedPDF()
        let url = try write(original, "a.pdf", in: fixture)
        #expect(try read(url).values[.title] == "Newer title")
        _ = try expectPDFRoundTrip(original, name: "b.pdf", in: fixture)
    }

    @Test func aLinearizedPDFStaysReadableAfterAnUpdate() throws {
        let fixture = try Fixture()
        let original = F.linearizedPDF()
        let url = try write(original, "l.pdf", in: fixture)
        #expect(CGPDFDocument(url as CFURL)?.numberOfPages == 1)
        #expect(try read(url).values[.title] == "Old title")
        _ = try expectPDFRoundTrip(original, name: "m.pdf", in: fixture)
    }

    @Test func quartzOutputRoundTrips() throws {
        let fixture = try Fixture()
        let original = try F.quartzPDF(in: fixture)
        let url = try write(original, "q.pdf", in: fixture)
        #expect(try read(url).values[.title] == "Quartz title")
        _ = try expectPDFRoundTrip(original, name: "r.pdf", in: fixture)
    }

    @Test func xmpIsUpdatedWithTheDocumentInformationAndKeepsEverythingElse() throws {
        let fixture = try Fixture()
        for compressed in [false, true] {
            let url = try expectPDFRoundTrip(F.pdfWithXMP(compressed: compressed), name: "x\(compressed).pdf", in: fixture)
            let document = try #require(CGPDFDocument(url as CFURL))
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            let catalog = try #require(document.catalog)
            #expect(CGPDFDictionaryGetStream(catalog, "Metadata", &stream))
            let found = try #require(stream)
            let xml = String(decoding: try #require(CGPDFStreamCopyData(found, &format) as Data?), as: UTF8.self)
            #expect(xml.contains("Ünï Çödé"))
            #expect(xml.contains("<rdf:li>alpha</rdf:li><rdf:li>beta</rdf:li>"))
            #expect(xml.contains("<pdf:Keywords>alpha, beta</pdf:Keywords>"))
            for kept in ["xmp:CreatorTool=\"Fixture tool\"", "<xmp:CreateDate>2024-01-02T03:04:05Z</xmp:CreateDate>", "<!-- kept comment -->", "<?xpacket end=\"w\"?>"] {
                #expect(xml.contains(kept), "\(kept)")
            }
            #expect(!xml.hasPrefix("<?xml"))
        }
    }

    @Test func xmpPropertiesAreAddedWhereThePacketHasNone() throws {
        let fixture = try Fixture()
        let url = try write(F.pdfWithXMP(F.xmp("")), "a.pdf", in: fixture)
        try save([.title: "Added", .keywords: "one"], url, in: fixture)
        let after = try read(url)
        #expect(after.values[.title] == "Added")
        #expect(after.values[.keywords] == "one")
    }

    @Test func clearingAPDFFieldRemovesItEverywhere() throws {
        let fixture = try Fixture()
        let url = try write(F.pdfWithXMP(), "a.pdf", in: fixture)
        try save([.author: "", .keywords: ""], url, in: fixture)
        let after = try read(url)
        #expect(after.values[.author] == nil)
        #expect(after.values[.keywords] == nil)
        #expect(after.values[.title] == "Old title")
        #expect(quartzInfo(url, "Author") == nil)
    }

    @Test func aMultilingualXMPTitleIsShownButNotOffered() throws {
        let fixture = try Fixture()
        let packet = F.xmp("<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Hello</rdf:li><rdf:li xml:lang=\"de\">Hallo</rdf:li></rdf:Alt></dc:title>")
        let snapshot = try read(try write(F.pdfWithXMP(packet), "a.pdf", in: fixture))
        #expect(snapshot.values[.title] == "Hello")
        #expect(!snapshot.editable.contains(.title))
        #expect(snapshot.editable.contains(.author))
    }

    @Test func undoPutsThePDFBackByteForByte() throws {
        let fixture = try Fixture()
        let original = F.pdfWithXMP()
        let url = try write(original, "a.pdf", in: fixture)
        let step = try save([.title: "Undo me"], url, in: fixture)
        let back = try EmbeddedMetadataEditor.revert(step)
        #expect(try Data(contentsOf: url) == original)
        _ = try EmbeddedMetadataEditor.revert(back)
        #expect(try read(url).values[.title] == "Undo me")
    }

    // MARK: Office

    private let officeEdits: [EmbeddedField: String] = [.title: "New <title> & \"more\"", .subject: "写真 🌳", .author: "Ünï Çödé",
                                                        .keywords: "alpha; beta", .category: "Reports", .comment: "Line one\nline two"]

    private func expectOfficeRoundTrip(_ original: Data, name: String, in fixture: Fixture) throws -> URL {
        let url = try write(original, name, in: fixture)
        let before = try read(url)
        #expect(before.typeIdentifier == OfficeFormat.identifier)
        #expect(before.blocked == nil, "\(String(describing: before.blocked?.localizedDescription))")
        #expect(before.editable == [.title, .subject, .author, .keywords, .category, .comment])
        try save(officeEdits, url, in: fixture)
        let after = try read(url)
        for (field, value) in officeEdits { #expect(after.values[field] == value, "\(field)") }
        #expect(try F.unzipAccepts(url))
        return url
    }

    @Test func officePackageRoundTripsKeepingEveryOtherPartAndElement() throws {
        let fixture = try Fixture()
        let url = try expectOfficeRoundTrip(F.office(), name: "a.docx", in: fixture)
        let written = try Data(contentsOf: url)
        for item in F.officeItems() where item.name != "docProps/core.xml" {
            #expect(written.range(of: item.deflate ? F.rawDeflate(item.data) : item.data) != nil, "\(item.name)")
        }
        let xml = String(decoding: try #require(written.range(of: Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties".utf8)).map { written[$0.lowerBound...] }), as: UTF8.self)
        for kept in ["<cp:lastModifiedBy>Editor</cp:lastModifiedBy>", "<cp:revision>3</cp:revision>", "xsi:type=\"dcterms:W3CDTF\"",
                     "<x:custom xmlns:x=\"urn:fixture\" x:a=\"1\">kept <!-- note --></x:custom>", "New &lt;title&gt; &amp; \"more\""] {
            #expect(xml.contains(kept), "\(kept)")
        }
    }

    @Test func everyOfficeKindIsOfferedAndLegacyFilesAreNot() throws {
        let fixture = try Fixture()
        for kind in OfficeFormat.extensions.sorted() {
            #expect(try read(try write(F.office(), "a.\(kind)", in: fixture)).blocked == nil, "\(kind)")
        }
        for legacy in ["doc", "xls", "ppt", "zip"] {
            #expect(EmbeddedSnapshot.read(try write(F.office(), "a.\(legacy)", in: fixture)) == nil, "\(legacy)")
        }
    }

    @Test func packagesFromTheZipToolRoundTrip() throws {
        let fixture = try Fixture()
        let packed = try F.zipTool(F.officeItems(), in: fixture)
        _ = try expectOfficeRoundTrip(packed, name: "tool.xlsx", in: fixture)
        let described = try F.zipTool(F.officeItems(), in: fixture, extraArguments: ["-fd"])
        _ = try expectOfficeRoundTrip(described, name: "described.pptx", in: fixture)
    }

    @Test func dataDescriptorsExtraFieldsAndTheArchiveCommentAreKept() throws {
        let fixture = try Fixture()
        var items = F.officeItems()
        for index in items.indices {
            items[index].descriptor = index % 2 == 0
            items[index].localExtra = F.le(0xCAFE, 2) + F.le(4, 2) + Data([1, 2, 3, 4])
            items[index].centralExtra = F.le(0xCAFE, 2) + F.le(0, 2)
        }
        let comment = Data("Archive comment".utf8)
        let url = try expectOfficeRoundTrip(F.archive(items, comment: comment), name: "a.docm", in: fixture)
        #expect(try Data(contentsOf: url).suffix(comment.count) == comment)
    }

    @Test func clearingAndAddingOfficeFieldsTouchesOnlyThoseElements() throws {
        let fixture = try Fixture()
        let url = try write(F.office(core: F.core("<dc:title>Only title</dc:title><cp:revision>1</cp:revision>")), "a.docx", in: fixture)
        try save([.title: "", .category: "Added"], url, in: fixture)
        let after = try read(url)
        #expect(after.values[.title] == nil)
        #expect(after.values[.category] == "Added")
        let written = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(written.contains("<cp:revision>1</cp:revision><cp:category>Added</cp:category>"))
    }

    @Test func keywordsWithLanguagePartsAndRepeatedElementsAreNotOffered() throws {
        let fixture = try Fixture()
        let core = F.core("<cp:keywords>plain <cp:value xml:lang=\"de\">Wort</cp:value></cp:keywords><dc:title>A</dc:title><dc:title>B</dc:title>")
        let snapshot = try read(try write(F.office(core: core), "a.docx", in: fixture))
        #expect(!snapshot.editable.contains(.keywords))
        #expect(!snapshot.editable.contains(.title))
        #expect(snapshot.editable.contains(.author))
    }

    @Test func undoPutsThePackageBackByteForByte() throws {
        let fixture = try Fixture()
        let original = F.office()
        let url = try write(original, "a.xlsm", in: fixture)
        let step = try save([.title: "Undo me"], url, in: fixture)
        _ = try EmbeddedMetadataEditor.revert(step)
        #expect(try Data(contentsOf: url) == original)
    }
}
