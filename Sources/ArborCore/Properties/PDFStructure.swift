import Foundation

/// One cross-reference section: where its objects are, and its trailer.
struct PDFXRefSection {
    enum Entry: Equatable {
        case free
        case offset(Int64, generation: Int)
        case compressed(inStream: Int, index: Int)
    }

    enum Table {
        /// Subsections of fixed 20-byte lines, read one line at a time when looked up.
        case classic([(first: Int, count: Int, start: Int64)])
        case stream(rows: [UInt8], widths: [Int], index: [(first: Int, count: Int)])
    }

    let offset: Int64
    let table: Table
    let trailer: PDFDictionary

    var isStream: Bool {
        if case .stream = table { return true }
        return false
    }

    var previous: Int64? {
        if case .integer(let value)? = trailer["Prev"] { return value }
        return nil
    }

    /// nil when this section doesn't mention `number`; throws when the line it points at is malformed.
    func entry(_ number: Int, in file: EmbeddedFileReader) throws -> Entry? {
        switch table {
        case .classic(let subsections):
            guard let subsection = subsections.first(where: { number >= $0.first && number - $0.first < $0.count }),
                  let line = file.bytes(at: subsection.start + Int64(number - subsection.first) * 20, count: 20) else { return nil }
            return try Self.classicEntry(line)
        case .stream(let rows, let widths, let index):
            var row = 0
            for part in index {
                if number >= part.first, number - part.first < part.count { return try Self.streamEntry(rows, widths, row: row + number - part.first) }
                row += part.count
            }
            return nil
        }
    }

    /// The object numbers this section defines, for proving an update added only what it should.
    var numbers: [Int] {
        switch table {
        case .classic(let subsections): return subsections.flatMap { $0.first..<($0.first + $0.count) }
        case .stream(_, _, let index): return index.flatMap { $0.first..<($0.first + $0.count) }
        }
    }

    /// One past the highest object number this section declares in /Size or lists.
    var end: Int {
        var end = 0
        if case .integer(let size)? = trailer["Size"] { end = Int(clamping: size) }
        switch table {
        case .classic(let subsections): return subsections.reduce(end) { max($0, $1.first + $1.count) }
        case .stream(_, _, let index): return index.reduce(end) { max($0, $1.first + $1.count) }
        }
    }

    /// "nnnnnnnnnn ggggg n" and a two-byte line end.
    static func classicEntry(_ line: Data) throws -> Entry {
        let bytes = [UInt8](line)
        guard bytes.count == 20, bytes[10] == 32, bytes[16] == 32, bytes[0..<10].allSatisfy({ (48...57).contains($0) }),
              bytes[11..<16].allSatisfy({ (48...57).contains($0) }), bytes[18...].allSatisfy({ $0 == 32 || $0 == 10 || $0 == 13 }) else {
            throw PDFStructure.damaged
        }
        let offset = bytes[0..<10].reduce(Int64(0)) { $0 * 10 + Int64($1 - 48) }
        let generation = bytes[11..<16].reduce(0) { $0 * 10 + Int($1 - 48) }
        switch bytes[17] {
        case UInt8(ascii: "n"): return .offset(offset, generation: generation)
        case UInt8(ascii: "f"): return .free
        default: throw PDFStructure.damaged
        }
    }

    private static func streamEntry(_ rows: [UInt8], _ widths: [Int], row: Int) throws -> Entry {
        let width = widths.reduce(0, +)
        var index = row * width
        var fields: [Int64] = []
        for (position, size) in widths.enumerated() {
            guard size > 0 else {
                fields.append(position == 0 ? 1 : 0)
                continue
            }
            var value: Int64 = 0
            for _ in 0..<size {
                guard index < rows.count, value <= Int64.max >> 8 else { throw PDFStructure.damaged }
                value = value << 8 | Int64(rows[index])
                index += 1
            }
            fields.append(value)
        }
        switch fields[0] {
        case 1:
            guard let generation = Int(exactly: fields[2]), generation <= 65535 else { throw PDFStructure.damaged }
            return .offset(fields[1], generation: generation)
        case 2:
            guard let stream = Int(exactly: fields[1]), stream < 1 << 31, let index = Int(exactly: fields[2]) else { throw PDFStructure.damaged }
            return .compressed(inStream: stream, index: index)
        default: return .free
        }
    }
}

/// A PDF's cross-reference chain and objects, read from the end of the file (FE-152). Every offset is checked against what it must point at,
/// every read and inflate is bounded, and anything unexpected throws `EmbeddedFailure.structure`, which leaves the file read-only.
final class PDFStructure {
    static let damaged = EmbeddedFailure.structure(L10n.tr("This PDF is damaged or uses features Arbor doesn't understand, so its properties are read-only."))
    static let encrypted = EmbeddedFailure.structure(L10n.tr("This PDF is encrypted, so its properties are read-only."))

    private static let maxSections = 512
    private static let windows = [4 << 10, 64 << 10, 1 << 20]
    /// Across one parse, so a hostile chain can't make a panel read, inflate or hold gigabytes.
    private static let readBudget = 128 << 20
    private static let inflateBudget = 256 << 20
    private static let xrefBudget = 64 << 20

    let file: EmbeddedFileReader
    /// Newest first.
    private(set) var sections: [PDFXRefSection] = []
    /// Where the file's last `startxref` points.
    let start: Int64
    /// Above every number any section declares or lists, since the newest /Size alone can be understated.
    private(set) var firstUnusedNumber = 0
    private var read = 0, inflated = 0, xrefRows = 0
    /// Its body ends in one extra space that ends the last token, so a lookup lexes in place.
    private var objectStream: (number: Int, offsets: [(number: Int, offset: Int)], body: [UInt8])?

    init(_ file: EmbeddedFileReader) throws {
        self.file = file
        start = try Self.lastStartXRef(file)
        var next: Int64? = start
        var seen = Set<Int64>()
        while let offset = next {
            guard sections.count < Self.maxSections, seen.insert(offset).inserted else { throw Self.damaged }
            let section = try readSection(at: offset)
            sections.append(section)
            firstUnusedNumber = max(firstUnusedNumber, section.end)
            next = section.previous
        }
    }

    var trailer: PDFDictionary { sections[0].trailer }

    // MARK: Cross-reference sections

    /// The last "startxref", its offset and "%%EOF", with nothing but white space after.
    private static func lastStartXRef(_ file: EmbeddedFileReader) throws -> Int64 {
        let count = Int(min(file.size, 2048))
        guard let tail = file.bytes(at: file.size - Int64(count), count: count),
              let keyword = tail.range(of: Data("startxref".utf8), options: .backwards) else { throw damaged }
        let isSpace: (UInt8) -> Bool = { $0 == 32 || $0 == 10 || $0 == 13 || $0 == 9 || $0 == 0 }
        let afterKeyword = tail[keyword.upperBound...].drop(while: isSpace)
        let digits = afterKeyword.prefix { (48...57).contains($0) }
        guard !digits.isEmpty, digits.count <= 18 else { throw damaged }
        let offset = digits.reduce(Int64(0)) { $0 * 10 + Int64($1 - 48) }
        let marker = afterKeyword.dropFirst(digits.count).drop(while: isSpace)
        guard offset < file.size, marker.starts(with: Data("%%EOF".utf8)), marker.dropFirst(5).allSatisfy(isSpace) else { throw damaged }
        return offset
    }

    private func readSection(at offset: Int64) throws -> PDFXRefSection {
        let section: PDFXRefSection
        if file.bytes(at: offset, count: 4) == Data("xref".utf8) {
            section = try classicSection(at: offset)
            // A hybrid file keeps some objects only in a stream that older readers skip; two views of one file is a doubt.
            if section.trailer["XRefStm"] != nil {
                throw EmbeddedFailure.structure(L10n.tr("This PDF mixes two kinds of cross-reference data, so its properties are read-only."))
            }
        } else {
            section = try streamSection(at: offset)
        }
        if section.trailer["Encrypt"] != nil { throw Self.encrypted }
        guard case .integer(let size)? = section.trailer["Size"], size > 0, size < 1 << 31 else { throw Self.damaged }
        if let previous = section.previous { guard previous >= 0, previous < file.size else { throw Self.damaged } }
        return section
    }

    private func classicSection(at offset: Int64) throws -> PDFXRefSection {
        var position = offset + 4
        var subsections: [(first: Int, count: Int, start: Int64)] = []
        while true {
            guard subsections.count < 1 << 16, let window = file.bytes(at: position, count: Int(min(64, file.size - position))) else { throw Self.damaged }
            var lexer = PDFLexer(window)
            lexer.skipSpace()
            if (try? lexer.consume("trailer")) == true {
                position += Int64(lexer.position)
                break
            }
            guard case .integer(let first)? = try? lexer.value(), case .integer(let count)? = try? lexer.value(), first >= 0, count >= 0,
                  first < 1 << 31, count < 1 << 31 else { throw Self.damaged }
            lexer.skipSpace()
            let start = position + Int64(lexer.position)
            let length = count * 20
            guard length <= file.size - start else { throw Self.damaged }
            // The first and last lines prove the table's spacing, so a lookup by arithmetic lands on a line.
            if count > 0 {
                for line in [start, start + length - 20] {
                    guard let bytes = file.bytes(at: line, count: 20) else { throw Self.damaged }
                    _ = try PDFXRefSection.classicEntry(bytes)
                }
            }
            subsections.append((Int(first), Int(count), start))
            position = start + length
        }
        let trailer = try parse(at: position) { lexer -> PDFDictionary in
            guard case .dictionary(let trailer) = try lexer.value() else { throw PDFLexer.Failure.malformed }
            return trailer
        }
        return PDFXRefSection(offset: offset, table: .classic(subsections), trailer: trailer)
    }

    private func streamSection(at offset: Int64) throws -> PDFXRefSection {
        let (_, value, streamStart) = try indirect(at: offset, expecting: nil)
        guard case .dictionary(let dictionary) = value, let streamStart, dictionary["Type"] == .name("XRef"),
              case .integer? = dictionary["Length"] else { throw Self.damaged }
        let rows = [UInt8](try decoded(dictionary, try streamRange(dictionary, start: streamStart), limit: Self.xrefBudget - xrefRows))
        xrefRows += rows.count
        guard case .array(let rawWidths)? = dictionary["W"], rawWidths.count == 3, case .integer(let size)? = dictionary["Size"] else { throw Self.damaged }
        let widths = try rawWidths.map { item -> Int in
            guard case .integer(let width) = item, (0...8).contains(width) else { throw Self.damaged }
            return Int(width)
        }
        var index: [(first: Int, count: Int)] = [(0, Int(clamping: size))]
        if case .array(let pairs)? = dictionary["Index"] {
            guard pairs.count % 2 == 0 else { throw Self.damaged }
            index = try stride(from: 0, to: pairs.count, by: 2).map { at in
                guard case .integer(let first) = pairs[at], case .integer(let count) = pairs[at + 1], first >= 0, count >= 0,
                      first < 1 << 31, count < 1 << 31 else { throw Self.damaged }
                return (Int(first), Int(count))
            }
        }
        let width = widths.reduce(0, +)
        let total = index.reduce(Int64(0)) { $0 + Int64($1.count) }
        guard width > 0, total * Int64(width) == Int64(rows.count) else { throw Self.damaged }
        return PDFXRefSection(offset: offset, table: .stream(rows: rows, widths: widths, index: index), trailer: dictionary)
    }

    // MARK: Objects

    /// Parses at `offset` in a small window, widening it only when the syntax runs past its end.
    private func parse<T>(at offset: Int64, _ body: (inout PDFLexer) throws -> T) throws -> T {
        for window in Self.windows {
            let available = min(Int64(window), file.size - offset)
            guard offset >= 0, available > 0 else { throw Self.damaged }
            try charge(Int(available))
            guard let bytes = file.bytes(at: offset, count: Int(available)) else { throw Self.damaged }
            var lexer = PDFLexer(bytes)
            do {
                return try body(&lexer)
            } catch PDFLexer.Failure.windowTooShort where available == Int64(window) {
                continue
            } catch let failure as EmbeddedFailure {
                throw failure
            } catch {
                throw Self.damaged
            }
        }
        throw Self.damaged
    }

    private func charge(_ count: Int) throws {
        guard count <= Self.readBudget - read else { throw Self.damaged }
        read += count
    }

    /// The object at `offset`, which must be the one expected; `streamStart` is where its data begins when it is a stream.
    private func indirect(at offset: Int64, expecting expected: PDFObjectID?) throws -> (id: PDFObjectID, value: PDFValue, streamStart: Int64?) {
        try parse(at: offset) { lexer in
            let id = try lexer.objectHeader()
            guard expected == nil || id == expected else { throw PDFLexer.Failure.malformed }
            let value = try lexer.value()
            lexer.skipSpace()
            if try lexer.consume("stream") {
                guard case .dictionary = value, try lexer.consumeStreamLineEnd() else { throw PDFLexer.Failure.malformed }
                return (id, value, offset + Int64(lexer.position))
            }
            guard try lexer.consume("endobj") else { throw PDFLexer.Failure.malformed }
            return (id, value, nil)
        }
    }

    /// Where `number` is defined now: the newest section that mentions it decides.
    func entry(_ number: Int) throws -> PDFXRefSection.Entry? {
        for section in sections {
            if let found = try section.entry(number, in: file) { return found }
        }
        return nil
    }

    /// The object `id`, or nil when no section defines it.
    func object(_ id: PDFObjectID) throws -> (value: PDFValue, streamStart: Int64?)? {
        switch try entry(id.number) {
        case nil, .free?: return nil
        case .offset(let offset, let generation)?:
            guard generation == id.generation else { return nil }
            let found = try indirect(at: offset, expecting: id)
            return (found.value, found.streamStart)
        case .compressed(let stream, let index)?:
            guard id.generation == 0 else { return nil }
            return (try compressed(id.number, in: stream, at: index), nil)
        }
    }

    /// Follows references until a direct value, a few at most; a missing object is null.
    func resolved(_ value: PDFValue?) throws -> PDFValue? {
        var current = value
        for _ in 0..<8 {
            guard case .reference(let id)? = current else { return current }
            current = try object(id)?.value ?? .null
        }
        throw Self.damaged
    }

    func dictionary(_ value: PDFValue?) throws -> PDFDictionary? {
        guard let value = try resolved(value), value != .null else { return nil }
        guard case .dictionary(let dictionary) = value else { throw Self.damaged }
        return dictionary
    }

    private func compressed(_ number: Int, in stream: Int, at index: Int) throws -> PDFValue {
        if objectStream?.number != stream { objectStream = try loadObjectStream(stream) }
        guard let loaded = objectStream, index >= 0, index < loaded.offsets.count, loaded.offsets[index].number == number else { throw Self.damaged }
        let start = loaded.offsets[index].offset
        guard start < loaded.body.count - 1 else { throw Self.damaged }
        var lexer = PDFLexer(loaded.body, from: start)
        guard let value = try? lexer.value() else { throw Self.damaged }
        // What the lexer walked counts like a file read, so resolving the same object again and again stays bounded.
        try charge(lexer.position - start)
        return value
    }

    private func loadObjectStream(_ number: Int) throws -> (number: Int, offsets: [(number: Int, offset: Int)], body: [UInt8]) {
        guard case .offset(let offset, let generation)? = try entry(number) else { throw Self.damaged }
        let found = try indirect(at: offset, expecting: PDFObjectID(number: number, generation: generation))
        guard case .dictionary(let dictionary) = found.value, let start = found.streamStart, dictionary["Type"] == .name("ObjStm"),
              case .integer(let count)? = dictionary["N"], case .integer(let first)? = dictionary["First"], count >= 0, count < 1 << 20, first >= 0 else {
            throw Self.damaged
        }
        let body = try decoded(dictionary, try streamRange(dictionary, start: start), limit: 16 << 20)
        guard first < body.count else { throw Self.damaged }
        var lexer = PDFLexer(body.prefix(Int(first)) + Data(" ".utf8))
        var offsets: [(number: Int, offset: Int)] = []
        for _ in 0..<count {
            guard case .integer(let object)? = try? lexer.value(), case .integer(let relative)? = try? lexer.value(),
                  object >= 0, object < 1 << 31, relative >= 0, relative < Int64(body.count) - first else { throw Self.damaged }
            offsets.append((Int(object), Int(first + relative)))
        }
        return (number, offsets, [UInt8](body) + [32])
    }

    // MARK: Streams

    /// The stream's data, checked to end exactly where "endstream" begins.
    func streamRange(_ dictionary: PDFDictionary, start: Int64) throws -> Range<Int64> {
        guard case .integer(let length)? = try resolved(dictionary["Length"]), length >= 0, length <= file.size - start else { throw Self.damaged }
        let end = start + length
        guard let after = file.bytes(at: end, count: Int(min(16, file.size - end))) else { throw Self.damaged }
        let rest = after.drop { $0 == 10 || $0 == 13 }
        guard after.count - rest.count <= 2, rest.starts(with: Data("endstream".utf8)) else { throw Self.damaged }
        return start..<end
    }

    /// Unfiltered or Flate, with PNG predictors at most; anything else can't be read safely here.
    func decoded(_ dictionary: PDFDictionary, _ range: Range<Int64>, limit: Int) throws -> Data {
        guard dictionary["F"] == nil, range.count <= EmbeddedFileReader.maxRead else { throw Self.damaged }
        // Unfiltered data is returned as read, so every stream byte counts, not only what is inflated.
        try charge(range.count)
        guard let raw = file.bytes(range) else { throw Self.damaged }
        var filters: [PDFValue] = []
        var parameters: PDFValue?
        switch dictionary["Filter"] {
        case nil: break
        case .array(let list)?: filters = list
        case let single?: filters = [single]
        }
        switch dictionary["DecodeParms"] {
        case .array(let list)?: parameters = list.first
        case let single?: parameters = single
        case nil: break
        }
        guard filters.count <= 1 else { throw Self.damaged }
        guard let filter = filters.first else {
            guard raw.count <= limit else { throw Self.damaged }
            return raw
        }
        guard filter == .name("FlateDecode") || filter == .name("Fl"),
              let inflatedData = BoundedInflate.zlib(raw, limit: min(limit, Self.inflateBudget - inflated)) else { throw Self.damaged }
        inflated += inflatedData.count
        guard case .dictionary(let parms)? = try resolved(parameters) else {
            guard parameters == nil || parameters == .null else { throw Self.damaged }
            return inflatedData
        }
        return try Self.undoPredictor(inflatedData, parms)
    }

    private static func undoPredictor(_ data: Data, _ parms: PDFDictionary) throws -> Data {
        func integer(_ key: String, _ fallback: Int64) throws -> Int64 {
            guard let value = parms[key] else { return fallback }
            guard case .integer(let number) = value else { throw damaged }
            return number
        }
        let predictor = try integer("Predictor", 1)
        if predictor == 1 { return data }
        let columns = try integer("Columns", 1)
        guard (10...15).contains(predictor), try integer("Colors", 1) == 1, try integer("BitsPerComponent", 8) == 8, (1...(1 << 20)).contains(columns) else {
            throw damaged
        }
        let width = Int(columns), stride = width + 1
        let input = [UInt8](data)
        guard input.count % stride == 0 else { throw damaged }
        var output: [UInt8] = []
        output.reserveCapacity(input.count / stride * width)
        var previous = [UInt8](repeating: 0, count: width)
        for row in 0..<(input.count / stride) {
            let type = input[row * stride]
            var current = [UInt8](repeating: 0, count: width)
            for column in 0..<width {
                let raw = input[row * stride + 1 + column]
                let left = column > 0 ? current[column - 1] : 0, up = previous[column], corner = column > 0 ? previous[column - 1] : 0
                switch type {
                case 0: current[column] = raw
                case 1: current[column] = raw &+ left
                case 2: current[column] = raw &+ up
                case 3: current[column] = raw &+ UInt8((Int(left) + Int(up)) / 2)
                case 4: current[column] = raw &+ paeth(left, up, corner)
                default: throw damaged
                }
            }
            output.append(contentsOf: current)
            previous = current
        }
        return Data(output)
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb, pa <= pc { return a }
        return pb <= pc ? b : c
    }
}
