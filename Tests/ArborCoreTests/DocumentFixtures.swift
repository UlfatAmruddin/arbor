import Foundation
import Compression
import CoreGraphics
import Testing
@testable import ArborCore

/// Hand-built PDFs and Office packages for FE-152, with real offsets, written into disposable folders only.
enum DocumentFixtures {
    // MARK: PDF

    /// Lays out objects with their real offsets, then a cross-reference section of either kind.
    struct PDF {
        private(set) var data: Data
        private(set) var offsets: [Int: Int] = [:]
        private(set) var lastXRef = 0

        init(version: String = "1.7") { data = Data("%PDF-\(version)\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 10]) }

        mutating func object(_ number: Int, _ body: String) { object(number, Data(body.utf8)) }

        mutating func object(_ number: Int, _ body: Data) {
            offsets[number] = data.count
            data += Data("\(number) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }

        mutating func append(_ text: String) { data += Data(text.utf8) }

        /// A table for `numbers` (default: every object so far, from 0), then the trailer.
        mutating func classicTable(trailer: String, numbers: [Int]? = nil) {
            lastXRef = data.count
            var text = "xref\n"
            if let numbers {
                for number in numbers.sorted() { text += "\(number) 1\n" + String(format: "%010d 00000 n\r\n", offsets[number] ?? 0) }
            } else {
                let top = offsets.keys.max() ?? 0
                text += "0 \(top + 1)\n0000000000 65535 f\r\n"
                for number in stride(from: 1, through: top, by: 1) {
                    text += offsets[number].map { String(format: "%010d 00000 n\r\n", $0) } ?? "0000000000 00001 f\r\n"
                }
            }
            text += "trailer\n<<\(trailer)>>\nstartxref\n\(lastXRef)\n%%EOF\n"
            append(text)
        }

        /// A compressed cross-reference stream with the PNG "up" predictor, as most writers make them.
        mutating func xrefStream(_ number: Int, trailer: String, compressed: [Int: (stream: Int, index: Int)] = [:]) {
            lastXRef = data.count
            offsets[number] = data.count
            let top = max(offsets.keys.max() ?? 0, compressed.keys.max() ?? 0)
            var rows: [[UInt8]] = []
            for object in 0...top {
                if let place = compressed[object] {
                    rows.append([2] + be(place.stream, 4) + be(place.index, 2))
                } else if let offset = offsets[object] {
                    rows.append([1] + be(offset, 4) + [0, 0])
                } else {
                    rows.append([0, 0, 0, 0, 0, 0xFF, 0xFF])
                }
            }
            var predicted = Data()
            var previous = [UInt8](repeating: 0, count: 7)
            for row in rows {
                predicted.append(2)
                predicted += Data(zip(row, previous).map { $0 &- $1 })
                previous = row
            }
            let body = DocumentFixtures.zlib(predicted)
            append("\(number) 0 obj\n<</Type/XRef/Size \(top + 1)/W[1 4 2]/Filter/FlateDecode/DecodeParms<</Predictor 12/Columns 7>>\(trailer)/Length \(body.count)>>\nstream\n")
            data += body
            append("\nendstream\nendobj\nstartxref\n\(lastXRef)\n%%EOF\n")
        }

        private func be(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }

    static func stream(_ dictionary: String, _ content: Data) -> Data {
        Data("<<\(dictionary)/Length \(content.count)>>\nstream\n".utf8) + content + Data("\nendstream".utf8)
    }

    static let pageContent = Data("0 0 1 rg 20 20 160 160 re f".utf8)
    static let id = "/ID[<0123456789ABCDEF0123456789ABCDEF><0123456789ABCDEF0123456789ABCDEF>]"
    static let oldInfo = "/Title(Old title)/Author(Old author)/Subject(Old subject)/Producer(Fixture producer)/CreationDate(D:20240102030405Z)"

    /// Catalog 1, pages 2, page 3, contents 4, information 5, then `extra` from 6.
    static func pdf(info: String? = oldInfo, catalog: String = "", extra: [String] = [], trailer: String = "") -> Data {
        var pdf = basePDF(info: info, catalog: catalog, extra: extra)
        pdf.classicTable(trailer: "/Size \(pdf.offsets.count + 1)/Root 1 0 R\(info == nil ? "" : "/Info 5 0 R")\(id)\(trailer)")
        return pdf.data
    }

    static func basePDF(info: String? = oldInfo, catalog: String = "", extra: [String] = []) -> PDF {
        var pdf = PDF()
        pdf.object(1, "<</Type/Catalog/Pages 2 0 R\(catalog)>>")
        pdf.object(2, "<</Type/Pages/Kids[3 0 R]/Count 1>>")
        pdf.object(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>")
        pdf.object(4, stream("", pageContent))
        if let info { pdf.object(5, "<<\(info)>>") }
        for (index, body) in extra.enumerated() { pdf.object(6 + index, body) }
        return pdf
    }

    /// The catalog and information dictionary live in a compressed object stream, found through a compressed cross-reference stream.
    static func pdfWithObjectStreams(info: String = oldInfo) -> Data {
        var pdf = PDF()
        pdf.object(2, "<</Type/Pages/Kids[3 0 R]/Count 1>>")
        pdf.object(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>")
        pdf.object(4, stream("", pageContent))
        let first = "<</Type/Catalog/Pages 2 0 R>>", second = "<<\(info)>>"
        let header = "1 0 5 \(first.utf8.count + 1) "
        let body = Data((header + first + " " + second).utf8)
        pdf.object(6, stream("/Type/ObjStm/N 2/First \(header.utf8.count)/Filter/FlateDecode", zlib(body)))
        pdf.xrefStream(7, trailer: "/Root 1 0 R/Info 5 0 R\(id)", compressed: [1: (6, 0), 5: (6, 1)])
        return pdf.data
    }

    /// A file already updated once by another program: the newest information dictionary is in the appended section.
    static func incrementallyUpdatedPDF() -> Data {
        var pdf = basePDF()
        pdf.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R\(id)")
        let previous = pdf.lastXRef
        pdf.object(5, "<</Title(Newer title)/Author(Old author)/Producer(Fixture producer)>>")
        pdf.classicTable(trailer: "/Size 6/Root 1 0 R/Info 5 0 R\(id)/Prev \(previous)", numbers: [5])
        return pdf.data
    }

    /// A valid newest cross-reference stream whose /Prev chain is `sections` unfiltered ones nested in each other,
    /// every header inside the data of the one before and all of them ending at one `endstream` after `rows` more bytes.
    static func nestedXRefChain(sections: Int, rows: Int) -> Data {
        var pdf = basePDF()
        let chainStart = pdf.data.count
        func header(_ index: Int, length: Int, previous: Int) -> String {
            let link = index < sections - 1 ? String(format: "/Prev %010d", previous) : ""
            return String(format: "%d 0 obj\n<</Type/XRef/W[1 0 0]/Size %010d/Length %010d", 50 + index, length, length) + link + ">>\nstream\n"
        }
        // Every number has a fixed width, so the headers' lengths are known before their values.
        var starts = [chainStart]
        for index in 0..<sections { starts.append(starts[index] + header(index, length: 0, previous: 0).utf8.count) }
        let end = starts[sections] + rows
        for index in 0..<sections { pdf.append(header(index, length: end - starts[index + 1], previous: starts[index + 1])) }
        pdf.append(String(repeating: "\0", count: rows) + "\nendstream\nendobj\n")
        pdf.xrefStream(6, trailer: "/Root 1 0 R/Info 5 0 R\(id)/Prev \(chainStart)")
        return pdf.data
    }

    /// A form whose fields, 10 onwards, and object 9 sit in one unfiltered object stream; the catalog lists field 10.
    static func objectStreamForm(_ shared: String, fields: [String]) -> Data {
        var pdf = basePDF(catalog: "/AcroForm<</Fields[10 0 R]>>")
        let objects = [shared] + fields
        var header = "", body = ""
        for (index, object) in objects.enumerated() {
            header += "\(9 + index) \(body.utf8.count) "
            body += object + " "
        }
        pdf.object(8, stream("/Type/ObjStm/N \(objects.count)/First \(header.utf8.count)", Data((header + body).utf8)))
        let places = Dictionary(uniqueKeysWithValues: objects.indices.map { (9 + $0, (stream: 8, index: $0)) })
        pdf.xrefStream(7, trailer: "/Root 1 0 R/Info 5 0 R\(id)", compressed: places)
        return pdf.data
    }

    /// Laid out as linearized: the first page's section at the start of the file, the main one at the end, linked by /Prev.
    static func linearizedPDF() -> Data {
        func pad(_ value: Int) -> String { String(format: "%010d", value) }
        func line(_ offset: Int?) -> String { String(format: "%010d 00000 n\r\n", offset ?? 0) }
        var known = (length: 0, main: 0, firstEnd: 0, catalog: 0, page: 0)
        var data = Data()
        // Every number has a fixed width, so the second pass lays out the same bytes with the forward offsets filled in.
        for _ in 0..<2 {
            var pdf = PDF(version: "1.4")
            pdf.object(4, "<</Linearized 1/L \(pad(known.length))/O 6/E \(pad(known.firstEnd))/N 1/T \(pad(known.main))/H[\(pad(0)) \(pad(0))]>>")
            let firstXRef = pdf.data.count
            pdf.append("xref\n4 3\n" + line(pdf.offsets[4]) + line(known.catalog) + line(known.page))
            pdf.append("trailer\n<</Size 7/Root 5 0 R/Info 3 0 R\(id)/Prev \(pad(known.main))>>\nstartxref\n0\n%%EOF\n")
            pdf.object(5, "<</Type/Catalog/Pages 1 0 R>>")
            pdf.object(6, "<</Type/Page/Parent 1 0 R/MediaBox[0 0 200 200]/Contents 2 0 R>>")
            let firstEnd = pdf.data.count
            pdf.object(1, "<</Type/Pages/Kids[6 0 R]/Count 1>>")
            pdf.object(2, stream("", pageContent))
            pdf.object(3, "<<\(oldInfo)>>")
            let main = pdf.data.count
            pdf.append("xref\n0 4\n0000000000 65535 f\r\n" + (1...3).map { line(pdf.offsets[$0]) }.joined())
            pdf.append("trailer\n<</Size 4>>\nstartxref\n\(firstXRef)\n%%EOF\n")
            known = (pdf.data.count, main, firstEnd, pdf.offsets[5] ?? 0, pdf.offsets[6] ?? 0)
            data = pdf.data
        }
        return data
    }

    static func xmp(_ properties: String, extraNamespaces: String = "") -> Data {
        Data(("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Fixture\">\n"
            + " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
            + "  <rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\""
            + " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\(extraNamespaces) xmp:CreatorTool=\"Fixture tool\" pdf:Producer=\"Fixture producer\">\n"
            + properties + "\n  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n" + String(repeating: " ", count: 200) + "\n<?xpacket end=\"w\"?>").utf8)
    }

    static let richXMP = xmp("""
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li></rdf:Alt></dc:title>
           <dc:creator><rdf:Seq><rdf:li>Old author</rdf:li></rdf:Seq></dc:creator>
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Old subject</rdf:li></rdf:Alt></dc:description>
           <dc:subject><rdf:Bag><rdf:li>old</rdf:li><rdf:li>words</rdf:li></rdf:Bag></dc:subject>
           <pdf:Keywords>old, words</pdf:Keywords>
           <xmp:CreateDate>2024-01-02T03:04:05Z</xmp:CreateDate>
           <!-- kept comment -->
    """)

    /// The catalog points at object 6, an XMP stream, compressed when asked.
    static func pdfWithXMP(_ packet: Data = richXMP, compressed: Bool = false, info: String? = oldInfo) -> Data {
        let body = compressed ? stream("/Type/Metadata/Subtype/XML/Filter/FlateDecode", zlib(packet)) : stream("/Type/Metadata/Subtype/XML", packet)
        var pdf = basePDF(info: info, catalog: "/Metadata 6 0 R")
        pdf.object(6, body)
        pdf.classicTable(trailer: "/Size 7/Root 1 0 R\(info == nil ? "" : "/Info 5 0 R")\(id)")
        return pdf.data
    }

    /// What Quartz itself writes for a two-page document.
    static func quartzPDF(in fixture: Fixture) throws -> Data {
        let url = fixture.url("quartz-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Quartz title", kCGPDFContextAuthor: "Quartz author"]
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        for shade in [0.2, 0.8] {
            context.beginPDFPage(nil)
            context.setFillColor(gray: shade, alpha: 1)
            context.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
            context.endPDFPage()
        }
        context.closePDF()
        return try Data(contentsOf: url)
    }

    // MARK: Office

    struct ZipItem {
        var name: String
        var data: Data
        var deflate = true
        var descriptor = false
        var localExtra = Data()
        var centralExtra = Data()
        var flags = 0
    }

    /// A ZIP file laid out by hand, so the tests decide every field.
    static func archive(_ items: [ZipItem], comment: Data = Data()) -> Data {
        var out = Data(), central = Data()
        for item in items {
            let name = Data(item.name.utf8)
            let stored = item.deflate ? rawDeflate(item.data) : item.data
            let crc = Int(CRC32.checksum(item.data))
            let flags = item.flags | (item.descriptor ? 0x08 : 0) | 0x0800
            let method = item.deflate ? 8 : 0
            let offset = out.count
            out += le(0x0403_4B50, 4) + le(20, 2) + le(flags, 2) + le(method, 2) + le(0x6000, 2) + le(0x5821, 2)
            out += item.descriptor ? le(0, 12) : le(crc, 4) + le(stored.count, 4) + le(item.data.count, 4)
            out += le(name.count, 2) + le(item.localExtra.count, 2) + name + item.localExtra + stored
            if item.descriptor { out += le(0x0807_4B50, 4) + le(crc, 4) + le(stored.count, 4) + le(item.data.count, 4) }
            central += le(0x0201_4B50, 4) + le(0x031E, 2) + le(20, 2) + le(flags, 2) + le(method, 2) + le(0x6000, 2) + le(0x5821, 2)
            central += le(crc, 4) + le(stored.count, 4) + le(item.data.count, 4) + le(name.count, 2) + le(item.centralExtra.count, 2)
            central += le(0, 2) + le(0, 2) + le(0, 2) + le(0o100644 << 16, 4) + le(offset, 4) + name + item.centralExtra
        }
        let start = out.count
        out += central
        out += le(0x0605_4B50, 4) + le(0, 4) + le(items.count, 2) + le(items.count, 2) + le(central.count, 4) + le(start, 4) + le(comment.count, 2) + comment
        return out
    }

    static func le(_ value: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
    """

    static func relationships(core target: String = "docProps/core.xml") -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="\(target)"/><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
    }

    static func core(_ inner: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(inner)</cp:coreProperties>
        """
    }

    static let richCore = core("""
    <dc:title>Old title</dc:title><dc:subject>Old subject</dc:subject><dc:creator>Old author</dc:creator><cp:keywords>old, words</cp:keywords><dc:description>Old comment</dc:description><cp:lastModifiedBy>Editor</cp:lastModifiedBy><cp:revision>3</cp:revision><dcterms:created xsi:type="dcterms:W3CDTF">2024-01-02T03:04:05Z</dcterms:created><x:custom xmlns:x="urn:fixture" x:a="1">kept <!-- note --></x:custom>
    """)

    static let documentXML = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Body text</w:t></w:r></w:p></w:body></w:document>
    """.utf8)

    static let picture = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })

    static func officeItems(core: String? = richCore, relationships: String = relationships()) -> [ZipItem] {
        var items = [ZipItem(name: "[Content_Types].xml", data: Data(contentTypes.utf8)), ZipItem(name: "_rels/.rels", data: Data(relationships.utf8))]
        if let core { items.append(ZipItem(name: "docProps/core.xml", data: Data(core.utf8))) }
        items += [ZipItem(name: "docProps/app.xml", data: Data("<Properties xmlns=\"urn:app\"><Application>Fixture</Application></Properties>".utf8)),
                  ZipItem(name: "word/document.xml", data: documentXML),
                  ZipItem(name: "word/media/image1.png", data: picture, deflate: false)]
        return items
    }

    static func office(core: String? = richCore, comment: Data = Data()) -> Data { archive(officeItems(core: core), comment: comment) }

    /// The parts written to a folder and packed by the system's zip, with its own extra fields and compression.
    static func zipTool(_ items: [ZipItem], in fixture: Fixture, extraArguments: [String] = []) throws -> Data {
        let folder = fixture.url("pack-\(UUID().uuidString)")
        for item in items {
            let url = folder.appendingPathComponent(item.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try item.data.write(to: url)
        }
        let out = fixture.url("packed-\(UUID().uuidString).zip")
        try run("/usr/bin/zip", ["-q", "-nw"] + extraArguments + [out.path] + items.map(\.name), in: folder)
        return try Data(contentsOf: out)
    }

    /// True when the system's unzip tests every entry of the archive as sound.
    static func unzipAccepts(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func run(_ tool: String, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    // MARK: Compression

    static func rawDeflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(written)
    }

    static func zlib(_ data: Data) -> Data {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = b << 16 | a
        return Data([0x78, 0x9C]) + rawDeflate(data) + Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: adler >> ($0 * 8)) })
    }
}
