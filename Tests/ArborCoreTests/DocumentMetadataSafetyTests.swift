import Foundation
import Darwin
import Testing
@testable import ArborCore

/// FE-152: hostile PDFs and packages, refusals with their reasons, verifiers that don't trust the writer, and streaming.
@Suite struct DocumentMetadataSafetyTests {
    private typealias F = DocumentFixtures

    private func write(_ bytes: Data, _ name: String, in fixture: Fixture) throws -> URL {
        let url = fixture.url(name)
        try bytes.write(to: url)
        return url
    }

    private func layout(_ bytes: Data, in fixture: Fixture) throws -> TagLayout? {
        let url = try write(bytes, "input-\(UUID().uuidString)", in: fixture)
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        return PDFFormat().layout(of: try #require(EmbeddedFileReader(descriptor: descriptor)))
    }

    /// Why the file is read-only, or nil when it is editable; "-" when it isn't offered at all.
    private func reason(_ bytes: Data, _ name: String, in fixture: Fixture) throws -> String? {
        guard let snapshot = EmbeddedSnapshot.read(try write(bytes, name, in: fixture)) else { return "-" }
        #expect(snapshot.blocked == nil || snapshot.editable.isEmpty)
        return snapshot.blocked?.localizedDescription
    }

    // MARK: PDF: hostile input

    private static let pdfs: [Data] = [F.pdf(), F.pdfWithObjectStreams(), F.pdfWithXMP(compressed: true), F.incrementallyUpdatedPDF()]

    @Test func truncatedPDFsNeverTrapAndAreNeverEditableShort() throws {
        let fixture = try Fixture()
        for whole in Self.pdfs {
            for length in 0..<whole.count {
                let found = try layout(whole.prefix(length), in: fixture)
                // Only a cut exactly after an earlier complete update leaves a readable file.
                if let found, found.blocked == nil { #expect(String(decoding: whole.prefix(length), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%%EOF")) }
            }
        }
    }

    @Test func byteFlipsInPDFStructureAreHandled() throws {
        let fixture = try Fixture()
        for whole in Self.pdfs {
            for index in stride(from: 0, to: whole.count, by: 2) {
                for pattern in [UInt8(0xFF), 0x00, 0x30, 0x2F] {
                    var bytes = whole
                    bytes[index] = pattern
                    _ = try layout(bytes, in: fixture)
                }
            }
        }
    }

    @Test func hostileOffsetsAndSizesAreReadOnly() throws {
        let fixture = try Fixture()
        let damaged = PDFStructure.damaged.localizedDescription
        let good = F.pdf()
        func withStart(_ value: String) -> Data {
            let text = String(decoding: good, as: UTF8.self)
            guard let range = text.range(of: "startxref\n", options: .backwards) else { return good }
            return Data((String(text[..<range.upperBound]) + value + "\n%%EOF\n").utf8)
        }
        for start in ["0", "9", "12", "\(good.count)", "\(good.count - 10)", "99999999999999999999", "-5"] {
            #expect(try reason(withStart(start), "s\(start).pdf", in: fixture) == damaged, "\(start)")
        }
        var looping = F.basePDF()
        looping.classicTable(trailer: "/Size 6/Root 1 0 R/Prev 0")
        let selfLoop = String(decoding: looping.data, as: UTF8.self).replacingOccurrences(of: "/Prev 0", with: "/Prev \(looping.lastXRef)")
        let cases: [(String, Data)] = [
            ("loop", Data(selfLoop.utf8)),
            ("size", F.pdf(trailer: "/Prev 99999999999")),
            ("bigsize", Data(String(decoding: F.pdf(), as: UTF8.self).replacingOccurrences(of: "/Size 6", with: "/Size 9999999999999").utf8)),
            ("length", F.pdf(catalog: "/Metadata 6 0 R", extra: ["<</Type/Metadata/Length 999999999999>>\nstream\nabc\nendstream"])),
            ("nesting", F.pdf(info: "/Title(x)/Deep " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000))),
            ("count", Data(String(decoding: F.pdf(), as: UTF8.self).replacingOccurrences(of: "xref\n0 6\n", with: "xref\n0 999999999\n").utf8)),
            ("duplicate", F.pdf(info: "/Title(a)/Title(b)")),
        ]
        for (name, bytes) in cases {
            let found = try reason(bytes, "\(name).pdf", in: fixture)
            #expect(found != nil && found != "-", "\(name)")
        }
        // The table says object 5 is where object 4 is.
        var misplaced = F.basePDF()
        let wrong = misplaced.offsets[4] ?? 0
        misplaced.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R")
        let text = String(decoding: misplaced.data, as: UTF8.self)
        let entry = String(format: "%010d 00000 n", misplaced.offsets[5] ?? 0)
        #expect(try reason(Data(text.replacingOccurrences(of: entry, with: String(format: "%010d 00000 n", wrong)).utf8), "m.pdf", in: fixture) == damaged)
    }

    @Test func protectedAndSignedPDFsAreReadOnlyWithTheirReason() throws {
        let fixture = try Fixture()
        let signed = PDFDocumentFacts.signed
        #expect(try reason(F.pdf(extra: ["<</Filter/Standard/V 2/R 3/O<00>/U<00>/P -4>>"], trailer: "/Encrypt 6 0 R"), "e.pdf", in: fixture)
                == PDFStructure.encrypted.localizedDescription)
        #expect(try reason(F.pdf(catalog: "/AcroForm<</Fields[6 0 R]>>", extra: ["<</FT/Sig/T(Signature1)>>"]), "f.pdf", in: fixture) == signed)
        #expect(try reason(F.pdf(catalog: "/AcroForm<</Fields[6 0 R]>>", extra: ["<</Kids[7 0 R]>>", "<</FT/Sig/Parent 6 0 R>>"]), "k.pdf", in: fixture) == signed)
        #expect(try reason(F.pdf(catalog: "/AcroForm<</Fields[]/SigFlags 3>>"), "g.pdf", in: fixture) == signed)
        #expect(try reason(F.pdf(catalog: "/Perms<</DocMDP 6 0 R>>", extra: ["<</Type/Sig>>"]), "p.pdf", in: fixture) == signed)
        #expect(try reason(F.pdf(extra: ["<</Type/Sig/ByteRange[0 1 2 3]/Contents<00>>>"]), "b.pdf", in: fixture) == signed)
        #expect(try reason(F.pdf(catalog: "/AcroForm<</Fields[6 0 R]>>", extra: ["<</FT/Tx/T(Name)>>"]), "t.pdf", in: fixture) == nil)
        #expect(try reason(F.pdf(trailer: "/XRefStm 0"), "h.pdf", in: fixture) == L10n.tr("This PDF mixes two kinds of cross-reference data, so its properties are read-only."))
        // Only a real header makes a file a PDF.
        #expect(try reason(Data("Not a %PDF-1.7 file".utf8), "n.pdf", in: fixture) == "-")
    }

    @Test func hostileXMPLeavesThePDFReadOnly() throws {
        let fixture = try Fixture()
        let unsafe = PDFDocumentFacts.unsafeXMP
        let laughs = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\">]>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description>&b;</rdf:Description></rdf:RDF></x:xmpmeta>"
        let external = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/hosts\">]><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">&e;</x:xmpmeta>"
        let deep = String(repeating: "<a>", count: 200) + String(repeating: "</a>", count: 200)
        let packets: [(String, Data)] = [
            ("laughs", Data(laughs.utf8)), ("external", Data(external.utf8)),
            ("deep", F.xmp("<dc:title><rdf:Alt><rdf:li>\(deep)</rdf:li></rdf:Alt></dc:title>")),
            ("utf16", Data([0xFE, 0xFF]) + (String(decoding: F.richXMP, as: UTF8.self).data(using: .utf16BigEndian) ?? Data())),
            ("latin1", Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>".utf8) + F.xmp("")),
            ("broken", Data(String(decoding: F.richXMP, as: UTF8.self).replacingOccurrences(of: "</dc:title>", with: "").utf8)),
            ("typed", Data("<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><x:Thing xmlns:x=\"urn:x\"/></rdf:RDF>".utf8)),
        ]
        for (name, packet) in packets {
            #expect(try reason(F.pdfWithXMP(packet), "\(name).pdf", in: fixture) == unsafe, "\(name)")
        }
    }

    @Test func nestedUnfilteredCrossReferenceStreamsStayWithinTheBudget() throws {
        let fixture = try Fixture()
        // Two of them are an ordinary file, so only the total held is the reason for the refusal.
        #expect(try reason(F.nestedXRefChain(sections: 2, rows: 8 << 20), "two.pdf", in: fixture) == nil)
        #expect(try reason(F.nestedXRefChain(sections: 24, rows: 8 << 20), "many.pdf", in: fixture) == PDFStructure.damaged.localizedDescription)
    }

    @Test func objectsInObjectStreamsCountAgainstTheReadBudget() throws {
        let fixture = try Fixture()
        // Every field's type is object 9: a name after 1 MiB of white space, walked again for each field.
        let shared = String(repeating: " ", count: 1 << 20) + "/Tx"
        func chain(_ count: Int) -> [String] { (0..<count).map { "<</FT 9 0 R/T(f\($0))" + ($0 < count - 1 ? "/Kids[\(11 + $0) 0 R]" : "") + ">>" } }
        #expect(try reason(F.objectStreamForm(shared, fields: chain(20)), "few.pdf", in: fixture) == nil)
        #expect(try reason(F.objectStreamForm(shared, fields: chain(200)), "many.pdf", in: fixture) == PDFStructure.damaged.localizedDescription)
    }

    @Test func aKidsArraySharedByEveryFieldIsCountedAsQueued() throws {
        let fixture = try Fixture()
        let count = 2_000
        let kids = "[" + (0..<count).map { "\(10 + $0) 0 R" }.joined(separator: " ") + "]"
        let fields = Array(repeating: "<</FT/Tx/Kids 9 0 R>>", count: count)
        #expect(try reason(F.objectStreamForm(kids, fields: fields), "shared.pdf", in: fixture) == PDFDocumentFacts.signed)
        // The same fields as one honest tree are fine.
        #expect(try reason(F.objectStreamForm(kids, fields: ["<</FT/Tx/Kids 9 0 R>>"] + Array(repeating: "<</FT/Tx>>", count: count - 1)), "tree.pdf", in: fixture) == nil)
    }

    // MARK: PDF: the verifier

    @Test func newObjectsAreNumberedAboveEveryNumberTheFileKnows() throws {
        let fixture = try Fixture()
        let edits: [EmbeddedField: String] = [.title: "Hello"]
        // The table lists objects 0 to 4 under /Size 4, with no information dictionary yet; the stream lists 0 to 7 under /Size 3.
        var table = F.basePDF(info: nil)
        table.classicTable(trailer: "/Size 4/Root 1 0 R\(F.id)")
        var stream = F.pdfWithObjectStreams()
        let size = try #require(stream.range(of: Data("/Type/XRef/Size 8/".utf8)))
        stream.replaceSubrange(size, with: Data("/Type/XRef/Size 3/Index[0 8]/".utf8))
        for (original, added, live) in [(table.data, "5 0 obj", "4 0 obj"), (stream, "8 0 obj", "3 0 obj")] {
            let (held, staged) = try produced(edits, from: original, in: fixture)
            let update = staged.dropFirst(original.count)
            #expect(update.range(of: Data(added.utf8)) != nil)
            #expect(update.range(of: Data(live.utf8)) == nil)
            let url = try write(staged, "numbered-\(UUID().uuidString)", in: fixture)
            try PDFFormat().verify(edits, original: held, written: url, type: PDFFormat.identifier)
            let descriptor = open(url.path, O_RDONLY)
            defer { close(descriptor) }
            let structure = try PDFStructure(try #require(EmbeddedFileReader(descriptor: descriptor)))
            #expect(try structure.dictionary(.reference(PDFObjectID(number: 3, generation: 0)))?["Type"] == .name("Page"))
            #expect(try structure.object(PDFObjectID(number: 4, generation: 0))?.streamStart != nil)
        }
        // An update that numbers the new dictionary from the understated /Size replaces the page's contents.
        let (held, _) = try produced(edits, from: table.data, in: fixture)
        var reused = table
        let previous = reused.lastXRef
        reused.object(4, "<</Title(Hello)>>")
        reused.classicTable(trailer: "/Size 5/Root 1 0 R/Info 4 0 R\(F.id)/Prev \(previous)", numbers: [4])
        try expectPDFRefused(edits, held, reused.data, in: fixture)
    }

    private func produced(_ edits: [EmbeddedField: String], from original: Data, in fixture: Fixture) throws -> (held: EmbeddedHeldFile, staged: Data) {
        let url = try write(original, "original-\(UUID().uuidString).pdf", in: fixture)
        let held = try EmbeddedHeldFile(try #require(EmbeddedSnapshot.read(url)), limit: EmbeddedLimits.maxStreamedFileBytes)
        let staged = fixture.url("staged-\(UUID().uuidString)")
        try PDFFormat().produce(edits, from: held, type: PDFFormat.identifier, to: staged)
        return (held, try Data(contentsOf: staged))
    }

    private func expectPDFRefused(_ edits: [EmbeddedField: String], _ held: EmbeddedHeldFile, _ written: Data, in fixture: Fixture) throws {
        let url = try write(written, "tampered-\(UUID().uuidString)", in: fixture)
        #expect(throws: EmbeddedFailure.documentUnverified) { try PDFFormat().verify(edits, original: held, written: url, type: PDFFormat.identifier) }
    }

    @Test func pdfVerifierRefusesAnythingButTheRequestedUpdate() throws {
        let fixture = try Fixture()
        let original = F.pdfWithXMP()
        let edits: [EmbeddedField: String] = [.title: "New"]
        let (held, staged) = try produced(edits, from: original, in: fixture)
        let accepted = try write(staged, "accepted", in: fixture)
        try PDFFormat().verify(edits, original: held, written: accepted, type: PDFFormat.identifier)

        var prefix = staged
        if let content = prefix.range(of: F.pageContent) { prefix[content.lowerBound] ^= 1 }
        try expectPDFRefused(edits, held, prefix, in: fixture)
        try expectPDFRefused([.title: "Other"], held, staged, in: fixture)
        try expectPDFRefused([.title: "New", .author: ""], held, staged, in: fixture)
        // Same-length changes inside the update alone, so every offset still holds.
        func inUpdate(_ old: String, _ new: String) -> Data {
            staged.prefix(original.count) + Data(String(decoding: staged.dropFirst(original.count), as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
        }
        try expectPDFRefused(edits, held, inUpdate("(Fixture producer)", "(Fixture producex)"), in: fixture)
        try expectPDFRefused(edits, held, inUpdate("Fixture tool", "Fixture tooL"), in: fixture)
        try expectPDFRefused(edits, held, inUpdate("<!-- kept comment -->", "<!-- kept commenT -->"), in: fixture)
        try expectPDFRefused(edits, held, original, in: fixture)
    }

    @Test func pdfVerifierRefusesAnUpdateThatAlsoReplacesAPage() throws {
        let fixture = try Fixture()
        let edits: [EmbeddedField: String] = [.title: "New"]
        let (held, staged) = try produced(edits, from: F.pdf(), in: fixture)
        let accepted = try write(staged, "accepted", in: fixture)
        try PDFFormat().verify(edits, original: held, written: accepted, type: PDFFormat.identifier)
        var sneaky = F.basePDF()
        sneaky.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R\(F.id)")
        let previous = sneaky.lastXRef
        #expect(sneaky.data == F.pdf())
        sneaky.object(5, "<</Title(New)/Author(Old author)/Subject(Old subject)/Producer(Fixture producer)/CreationDate(D:20240102030405Z)>>")
        sneaky.object(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 400 400]/Contents 4 0 R>>")
        sneaky.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R\(F.id)/Prev \(previous)", numbers: [3, 5])
        try expectPDFRefused(edits, held, sneaky.data, in: fixture)
        // The same update without the page is accepted, so the page alone was the reason.
        var honest = F.basePDF()
        honest.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R\(F.id)")
        honest.object(5, "<</Title (New)/Author (Old author)/Subject (Old subject)/Producer (Fixture producer)/CreationDate (D:20240102030405Z)>>")
        honest.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R\(F.id)/Prev \(previous)", numbers: [5])
        try PDFFormat().verify(edits, original: held, written: try write(honest.data, "honest", in: fixture), type: PDFFormat.identifier)
    }

    // MARK: Office: hostile input

    private static let officeTrashed = OfficePackage.damaged.localizedDescription

    @Test func truncatedAndFlippedPackagesNeverTrap() throws {
        let fixture = try Fixture()
        let whole = F.office()
        for length in stride(from: 0, to: whole.count, by: 3) {
            let found = try reason(whole.prefix(length), "t\(length).docx", in: fixture)
            #expect(found != nil, "\(length)")
        }
        for index in stride(from: 0, to: whole.count, by: 5) {
            var bytes = whole
            bytes[index] ^= 0x5A
            _ = try reason(bytes, "f\(index).docx", in: fixture)
        }
    }

    @Test func protectedOrUnusualPackagesAreReadOnlyWithTheirReason() throws {
        let fixture = try Fixture()
        func items(_ change: (inout [F.ZipItem]) -> Void) -> Data {
            var list = F.officeItems()
            change(&list)
            return F.archive(list)
        }
        let signed = L10n.tr("This Office document is digitally signed, and changing it would invalidate the signature, so its properties are read-only.")
        let zip64 = L10n.tr("This Office document uses the ZIP64 format, so its properties are read-only.")
        let noCore = L10n.tr("This Office document has no core properties part to edit, so its properties are read-only.")
        let core = L10n.tr("This Office document's core properties can't be read safely, so its properties are read-only.")
        let cases: [(String, Data, String)] = [
            ("ole", Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 600),
             L10n.tr("This document is encrypted or isn't stored as Office Open XML, so its properties are read-only.")),
            ("signature", items { $0.append(F.ZipItem(name: "_xmlsignatures/sig1.xml", data: Data("<a/>".utf8))) }, signed),
            ("zip64extra", items { $0[3].centralExtra = F.le(1, 2) + F.le(8, 2) + Data(count: 8) }, zip64),
            ("duplicate", items { $0.append(F.ZipItem(name: "WORD/document.xml", data: Data("<a/>".utf8))) },
             L10n.tr("This Office document has two parts with the same name, so its properties are read-only.")),
            ("encrypted", items { $0[4].flags = 1 }, L10n.tr("This Office document is encrypted, so its properties are read-only.")),
            ("nocore", F.office(core: nil), noCore),
            ("elsewhere", F.archive(F.officeItems(relationships: F.relationships(core: "docProps/other.xml"))), noCore),
            ("bigcore", items { $0[2] = F.ZipItem(name: "docProps/core.xml", data: Data(F.core("<dc:title>\(String(repeating: "x", count: 1_100_000))</dc:title>").utf8), deflate: false) },
             L10n.tr("This Office document's core properties are unusually large, so its properties are read-only.")),
            ("doctype", F.office(core: "<?xml version=\"1.0\"?><!DOCTYPE cp:coreProperties [<!ENTITY a \"x\">]><cp:coreProperties"
                + " xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
                + "<dc:title>&a;</dc:title></cp:coreProperties>"), core),
            ("utf16", items { $0[2].data = F.richCore.data(using: .utf16) ?? Data() }, core),
            ("deep", F.office(core: F.core(String(repeating: "<x:a xmlns:x=\"urn:x\">", count: 100) + String(repeating: "</x:a>", count: 100))), core),
            ("notcore", F.office(core: "<root/>"), core),
        ]
        for (name, bytes, expected) in cases {
            #expect(try reason(bytes, "\(name).docx", in: fixture) == expected, "\(name)")
        }
    }

    @Test func zipLayoutsArborCannotProveAreReadOnly() throws {
        let fixture = try Fixture()
        let good = F.office()
        let directoryOffset = Int(good.suffix(6).prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) })
        var multiDisk = good
        multiDisk[multiDisk.count - 18] = 1
        var mismatch = good
        if let name = mismatch.range(of: Data("word/document.xml".utf8)) { mismatch[name.lowerBound] = UInt8(ascii: "W") }
        var locator = good
        locator.insert(contentsOf: Data([0x50, 0x4B, 0x06, 0x07]) + Data(count: 16), at: locator.count - 22)
        let fakeEnd = F.le(0x0605_4B50, 4) + Data(count: 16) + F.le(0, 2)
        let twoEnds = F.office(comment: fakeEnd)
        let cases: [(String, Data, String?)] = [
            ("prefix", Data("junk".utf8) + good, nil),
            ("between", Data(good.prefix(directoryOffset)) + Data("hidden".utf8) + Data(good.dropFirst(directoryOffset)), nil),
            ("multidisk", multiDisk, L10n.tr("This Office document spans several disks, so its properties are read-only.")),
            ("mismatch", mismatch, nil),
            ("locator", locator, L10n.tr("This Office document uses the ZIP64 format, so its properties are read-only.")),
            ("twoends", twoEnds, nil),
        ]
        #expect(try reason(good, "fine.docx", in: fixture) == nil)
        for (name, bytes, expected) in cases {
            let found = try reason(bytes, "\(name).docx", in: fixture)
            if let expected { #expect(found == expected, "\(name)") } else { #expect(found != nil && found != "-", "\(name): \(String(describing: found))") }
        }
    }

    // MARK: Office: the verifier

    @Test func officeVerifierRefusesAnythingButTheRequestedChange() throws {
        let fixture = try Fixture()
        let original = F.office()
        let url = try write(original, "original.docx", in: fixture)
        let held = try EmbeddedHeldFile(try #require(EmbeddedSnapshot.read(url)), limit: EmbeddedLimits.maxStreamedFileBytes)
        let edits: [EmbeddedField: String] = [.title: "New"]
        let staged = fixture.url("staged.docx")
        try OfficeFormat().produce(edits, from: held, type: OfficeFormat.identifier, to: staged)
        try OfficeFormat().verify(edits, original: held, written: staged, type: OfficeFormat.identifier)
        let good = try Data(contentsOf: staged)
        func refused(_ bytes: Data, _ asked: [EmbeddedField: String] = [.title: "New"]) throws {
            let tampered = try write(bytes, "tampered-\(UUID().uuidString).docx", in: fixture)
            #expect(throws: EmbeddedFailure.documentUnverified) { try OfficeFormat().verify(asked, original: held, written: tampered, type: OfficeFormat.identifier) }
        }
        var picture = good
        if let range = picture.range(of: F.picture) { picture[range.lowerBound + 10] ^= 1 }
        try refused(picture)
        try refused(good, [.title: "Other"])
        try refused(good, [.title: "New", .category: "x"])
        try refused(Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "<cp:revision>3", with: "<cp:revision>4").utf8))
        try refused(original)
        // Same values, but another part replaced alongside.
        var items = F.officeItems(core: String(decoding: F.richCore.utf8, as: UTF8.self).replacingOccurrences(of: "Old title", with: "New"))
        items[4].data = Data(String(decoding: F.documentXML, as: UTF8.self).replacingOccurrences(of: "Body", with: "Bodx").utf8)
        try refused(F.archive(items))
    }

    // MARK: Streaming

    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// How far memory rose during one save; other suites run alongside, so callers take the quietest of several.
    private func memoryRise(_ title: String, over url: URL, in fixture: Fixture) throws -> Int64 {
        let snapshot = try #require(EmbeddedSnapshot.read(url))
        #expect(snapshot.blocked == nil)
        let baseline = footprint()
        let stop = Counter()
        let peak = DocumentPeak()
        let sampler = Thread {
            while stop.count == 0 {
                peak.observe(self.footprint())
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        sampler.start()
        defer { stop.increment() }
        try EmbeddedMetadataEditor.save([.title: title], over: snapshot, dispose: { staged, _ in
            let target = fixture.trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: staged, to: target)
            try FileManager.default.removeItem(at: target)
            try Data().write(to: target)
            return target
        })
        return peak.value - baseline
    }

    private func expectStreamed(_ url: URL, in fixture: Fixture) throws {
        var quietest = Int64.max
        for attempt in 0..<5 where quietest >= 64 << 20 {
            quietest = min(quietest, try memoryRise("Large \(attempt)", over: url, in: fixture))
        }
        #expect(quietest < 64 << 20)
        #expect(try #require(EmbeddedSnapshot.read(url)).values[.title]?.hasPrefix("Large") == true)
    }

    @Test func aLargePDFIsStreamedWithinAMemoryBound() throws {
        let fixture = try Fixture()
        let url = fixture.url("large.pdf")
        let header = Data("%PDF-1.7\n".utf8)
        // Zeros are white space in PDF: a sparse gap of them sits between the header and the objects.
        let start = header.count + (160 << 20)
        let bodies = ["<</Type/Catalog/Pages 2 0 R>>", "<</Type/Pages/Kids[3 0 R]/Count 1>>", "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>",
                      String(decoding: F.stream("", F.pageContent), as: UTF8.self), "<<\(F.oldInfo)>>"]
        var objects = Data()
        var table = "xref\n0 6\n0000000000 65535 f\r\n"
        for (index, body) in bodies.enumerated() {
            table += String(format: "%010d 00000 n\r\n", start + objects.count)
            objects += Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        table += "trailer\n<</Size 6/Root 1 0 R/Info 5 0 R>>\nstartxref\n\(start + objects.count)\n%%EOF\n"
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(start))
        try handle.seekToEnd()
        try handle.write(contentsOf: objects + Data(table.utf8))
        try handle.close()
        try expectStreamed(url, in: fixture)
    }

    @Test func aLargePackageIsStreamedWithinAMemoryBound() throws {
        let fixture = try Fixture()
        let folder = fixture.url("pack")
        var items = F.officeItems()
        items.removeLast()
        for item in items {
            let url = folder.appendingPathComponent(item.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try item.data.write(to: url)
        }
        let media = folder.appendingPathComponent("word/media/video.bin")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: media)
        let handle = try FileHandle(forWritingTo: media)
        try handle.truncate(atOffset: 160 << 20)
        try handle.close()
        let url = fixture.url("large.pptx")
        // Stored, so the package really holds the whole payload; it comes after the core part, so it moves when that grows.
        try F.run("/usr/bin/zip", ["-q", "-nw", "-0", url.path, "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/media/video.bin", "docProps/app.xml"], in: folder)
        try expectStreamed(url, in: fixture)
        #expect(try F.unzipAccepts(url))
    }
}

private final class DocumentPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    func observe(_ sample: Int64) { lock.withLock { peak = max(peak, sample) } }
    var value: Int64 { lock.withLock { peak } }
}
