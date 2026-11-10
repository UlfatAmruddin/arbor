import Foundation

/// MP3 files with an ID3v2.3 or 2.4 tag at the start (FE-152). Only the named frames change; every other frame, the audio and any ID3v1 trailer are kept.
struct ID3Format: TagRegionFormat {
    static let identifier = "public.mp3"
    let typeIdentifier = identifier

    private static let headerSize: Int64 = 10, maxFrames = 8192, maxStackedTags = 16
    /// Longer than any value that can be edited; a longer frame is shown blank and left alone.
    private static let maxFieldFrame = 1 << 16
    private static let damaged = L10n.tr("This MP3's tag is damaged or uses features Arbor doesn't understand, so its properties are read-only.")

    private static func textFrame(_ field: EmbeddedField, version: UInt8) -> String? {
        switch field {
        case .title: return "TIT2"
        case .artist: return "TPE1"
        case .album: return "TALB"
        case .year: return version == 3 ? "TYER" : "TDRC"
        case .track: return "TRCK"
        case .genre: return "TCON"
        default: return nil
        }
    }

    private static let textFields: [EmbeddedField] = [.title, .artist, .album, .year, .track, .genre]

    func layout(of file: EmbeddedFileReader) -> TagLayout? {
        guard let head = file.bytes(at: 0, count: Int(Self.headerSize)), let bodySize = Self.tagBodySize(head) else { return nil }
        let version = head[3], flags = head[5]
        let end = Self.headerSize + Int64(bodySize)
        let hasFooter = version == 4 && flags & 0x10 != 0
        let audio = hasFooter && file.bytes(at: end, count: 3) == Data("3DI".utf8) ? end + Self.headerSize : end
        // Plain text can begin with "ID3", and FLAC or AAC can carry such a tag.
        guard Self.audioFollows(audio, file) else { return nil }
        guard version == 3 || version == 4 else {
            return TagLayout(blocked: L10n.tr("This MP3's tag uses an ID3 version Arbor can't rewrite, so its properties are read-only."))
        }
        if flags & 0x80 != 0 { return TagLayout(blocked: L10n.tr("This MP3's tag is unsynchronised, so its properties are read-only.")) }
        if flags & 0x40 != 0 { return TagLayout(blocked: L10n.tr("This MP3's tag has an extended header, so its properties are read-only.")) }
        if hasFooter { return TagLayout(blocked: L10n.tr("This MP3's tag has a footer, so its properties are read-only.")) }
        let known: UInt8 = version == 3 ? 0xE0 : 0xF0
        guard flags & ~known == 0, flags & 0x20 == 0 else { return TagLayout(blocked: Self.damaged) }

        var layout = TagLayout(region: 0..<end)
        layout.items = [TagItem(range: 0..<6, field: nil)]
        if let reason = Self.reasonAfterTag(end, file) { layout.block(reason) }
        walkFrames(from: Self.headerSize, to: end, version: version, file, into: &layout)
        return layout
    }

    /// The body size when `head` has ID3v2's signature: the letters, a version and revision below 0xFF, and a synchsafe size.
    private static func tagBodySize(_ head: Data) -> Int? {
        guard head.starts(with: Data("ID3".utf8)), head[3] != 0xFF, head[4] != 0xFF else { return nil }
        return synchsafe(head, at: 6)
    }

    /// True when MPEG audio starts at `start`, or after further tags stacked there.
    private static func audioFollows(_ start: Int64, _ file: EmbeddedFileReader) -> Bool {
        var offset = start
        for _ in 0...maxStackedTags {
            guard let next = file.bytes(at: offset, count: 4) else { return false }
            if isMPEGHeader(next) { return true }
            guard let head = file.bytes(at: offset, count: Int(headerSize)), let body = tagBodySize(head) else { return false }
            offset += headerSize + Int64(body)
        }
        return false
    }

    /// No second tag may exist, and a tag's size field alone doesn't prove that.
    private static func reasonAfterTag(_ end: Int64, _ file: EmbeddedFileReader) -> String? {
        let multiple = L10n.tr("This MP3 has more than one tag, so its properties are read-only.")
        if file.bytes(at: end, count: 3) == Data("ID3".utf8) { return multiple }
        // An appended tag ends the file with a footer, before any ID3v1 trailer.
        for trailer in [Int64(0), 128] where file.size >= end + trailer + 10 {
            if file.bytes(at: file.size - trailer - 10, count: 3) == Data("3DI".utf8) { return multiple }
        }
        return nil
    }

    private static func isMPEGHeader(_ bytes: Data) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 else { return false }
        return (bytes[1] >> 3) & 3 != 1 && (bytes[1] >> 1) & 3 != 0 && bytes[2] >> 4 != 15 && (bytes[2] >> 2) & 3 != 3
    }

    private func walkFrames(from start: Int64, to end: Int64, version: UInt8, _ file: EmbeddedFileReader, into layout: inout TagLayout) {
        var offset = start, count = 0
        while offset < end {
            // Only zeros may follow the last frame.
            guard end - offset >= Self.headerSize, let header = file.bytes(at: offset, count: Int(Self.headerSize)), header[0] != 0 else {
                if !file.isAllZero(offset..<end) { layout.block(Self.damaged) }
                return
            }
            guard header[0..<4].allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
                  let size = version == 3 ? header.bigEndian(at: 4, bytes: 4) : Self.synchsafe(header, at: 4),
                  Int64(size) <= end - offset - Self.headerSize, count < Self.maxFrames else {
                layout.block(Self.damaged)
                return
            }
            count += 1
            let range = offset..<(offset + Self.headerSize + Int64(size))
            let id = String(decoding: header[0..<4], as: UTF8.self)
            let frameFlags = (status: header[8], format: header[9])
            let isOpaque = Self.isOpaque(frameFlags.format, version: version)
            if isOpaque { layout.block(L10n.tr("This MP3's tag has compressed or encrypted frames, so its properties are read-only.")) }
            if id == "SEEK" { layout.block(L10n.tr("This MP3 has more than one tag, so its properties are read-only.")) }
            let field = isOpaque ? nil : record(id, range: range, frameFlags, version: version, file, into: &layout)
            layout.items.append(TagItem(range: range, field: field))
            offset = range.upperBound
        }
    }

    /// Flags that change how a frame's bytes must be read: compression, encryption and, in 2.4, frame-level unsynchronisation and a length prefix.
    private static func isOpaque(_ format: UInt8, version: UInt8) -> Bool {
        format & (version == 3 ? 0xC0 : 0x0F) != 0
    }

    /// Takes the frame's value if it holds one of the edited fields, and returns that field.
    private func record(_ id: String, range: Range<Int64>, _ flags: (status: UInt8, format: UInt8), version: UInt8,
                        _ file: EmbeddedFileReader, into layout: inout TagLayout) -> EmbeddedField? {
        let body = (range.lowerBound + Self.headerSize)..<range.upperBound
        // Only the two "keep this frame" hints survive a rewrite; read-only, grouped or unknown flags leave the frame alone.
        let isPlain = flags.status & ~(version == 3 ? 0xC0 : 0x60) == 0 && flags.format == 0
        if id == "COMM" { return recordComment(body, isPlain: isPlain, version: version, file, into: &layout) }
        if let field = Self.textFields.first(where: { Self.textFrame($0, version: version) == id }) {
            var raw = Self.textValue(body, version: version, file)
            if field == .genre { raw = ID3Genre.resolve(raw) }
            layout.record(field, EmbeddedReader.Raw(text: raw.text, canEdit: raw.canEdit && isPlain))
            return field
        }
        // The other version's year frame: its value is real, but a rewrite would leave it behind.
        if id == (version == 3 ? "TDRC" : "TYER") {
            let raw = Self.textValue(body, version: version, file)
            layout.record(.year, EmbeddedReader.Raw(text: raw.text, canEdit: false))
        }
        return nil
    }

    /// Comments with a description (iTunes keeps its own data that way) stay as they are; the field is the plain one.
    private func recordComment(_ body: Range<Int64>, isPlain: Bool, version: UInt8, _ file: EmbeddedFileReader, into layout: inout TagLayout) -> EmbeddedField? {
        guard let count = Int(exactly: body.upperBound - body.lowerBound), count <= Self.maxFieldFrame else {
            layout.record(.comment, EmbeddedReader.Raw(text: "", canEdit: false))
            return nil
        }
        guard count >= 4, let bytes = file.bytes(body) else { return nil }
        let encoding = bytes[0], parts = ID3Text.split(bytes.subdata(in: 4..<bytes.count), encoding: encoding, limit: 2)
        guard parts.count >= 1, let description = ID3Text.decode(parts[0], encoding: encoding), description.isEmpty else { return nil }
        let text = parts.count > 1 ? parts[1] : Data()
        let value = ID3Text.decode(Self.strippingTerminator(text, encoding: encoding), encoding: encoding)
        layout.record(.comment, EmbeddedReader.Raw(text: value ?? "", canEdit: value != nil && isPlain && ID3Text.isLegal(encoding, version: version)))
        return .comment
    }

    private static func strippingTerminator(_ text: Data, encoding: UInt8) -> Data {
        var bytes = text
        let width = encoding == 1 || encoding == 2 ? 2 : 1
        while bytes.count >= width, bytes.suffix(width).allSatisfy({ $0 == 0 }) { bytes.removeLast(width) }
        return bytes
    }

    private static func textValue(_ body: Range<Int64>, version: UInt8, _ file: EmbeddedFileReader) -> EmbeddedReader.Raw {
        guard let count = Int(exactly: body.upperBound - body.lowerBound), count <= maxFieldFrame, count >= 1, let bytes = file.bytes(body) else {
            return EmbeddedReader.Raw(text: "", canEdit: false)
        }
        let encoding = bytes[0]
        var parts = ID3Text.split(bytes.subdata(in: 1..<bytes.count), encoding: encoding, limit: .max)
        while parts.last?.isEmpty == true { parts.removeLast() }
        let decoded = parts.compactMap { ID3Text.decode($0, encoding: encoding) }
        guard decoded.count == parts.count else { return EmbeddedReader.Raw(text: "", canEdit: false) }
        return EmbeddedReader.Raw(text: decoded.joined(separator: "; "), canEdit: parts.count <= 1 && ID3Text.isLegal(encoding, version: version))
    }

    private static func synchsafe(_ bytes: Data, at index: Int) -> Int? {
        guard index >= 0, index <= bytes.count - 4 else { return nil }
        var value = 0
        for byte in bytes[(bytes.startIndex + index)..<(bytes.startIndex + index + 4)] {
            guard byte < 0x80 else { return nil }
            value = value << 7 | Int(byte)
        }
        return value
    }

    private static func synchsafeBytes(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 7)) & 0x7F })
    }

    // MARK: Writing

    func regionPieces(for edits: [EmbeddedField: String], in layout: TagLayout, of file: EmbeddedFileReader) throws -> [TagPiece] {
        guard let head = file.bytes(at: 0, count: Int(Self.headerSize)) else { throw EmbeddedFailure.changedSinceRead }
        let version = head[3]
        var frames: [TagPiece] = []
        var used: Int64 = 0
        var placed = Set<EmbeddedField>()
        func add(_ piece: TagPiece, size: Int64) {
            frames.append(piece)
            used += size
        }
        for item in layout.items.dropFirst() {
            guard let field = item.field, let value = edits[field] else {
                add(.copy(item.range), size: Int64(item.range.count))
                continue
            }
            placed.insert(field)
            guard !value.isEmpty else { continue }
            let frame = try Self.frame(field, value, version: version, replacing: item, file)
            add(.bytes(frame), size: Int64(frame.count))
        }
        for field in EmbeddedField.allCases where edits[field]?.isEmpty == false && !placed.contains(field) {
            let frame = try Self.frame(field, edits[field] ?? "", version: version, replacing: nil, file)
            add(.bytes(frame), size: Int64(frame.count))
        }
        // The same size keeps the audio where it was when the new frames fit.
        let oldBody = layout.region.upperBound - Self.headerSize
        let padding = max(oldBody - used, 0)
        let body = used + padding
        guard body < 1 << 28 else { throw EmbeddedFailure.writeFailed }
        return [.bytes(head.subdata(in: 0..<6) + Self.synchsafeBytes(Int(body)))] + frames + [.zeros(padding)]
    }

    private static func frame(_ field: EmbeddedField, _ value: String, version: UInt8, replacing item: TagItem?, _ file: EmbeddedFileReader) throws -> Data {
        var old: Data?
        if let item {
            old = file.bytes(at: item.range.lowerBound, count: min(Int(headerSize) + 4, item.range.count))
        }
        let encoding = ID3Text.preferredEncoding(for: value, version: version)
        var body = Data([encoding])
        if field == .comment {
            let language = old.flatMap { $0.count >= 14 ? $0.subdata(in: 11..<14) : nil } ?? Data("und".utf8)
            body += language + ID3Text.encode("", encoding: encoding) + ID3Text.terminator(encoding)
        }
        body += ID3Text.encode(value, encoding: encoding)
        guard let id = field == .comment ? "COMM" : textFrame(field, version: version) else { throw EmbeddedFailure.notEditable }
        guard body.count < 1 << 28 else { throw EmbeddedFailure.writeFailed }
        let size = version == 3 ? Data.bigEndian(body.count, bytes: 4) : synchsafeBytes(body.count)
        let flags = old.flatMap { $0.count >= 10 ? $0.subdata(in: 8..<10) : nil } ?? Data([0, 0])
        return Data(id.utf8) + size + flags + body
    }
}

/// ID3's four text encodings, read strictly: bytes that don't decode are reported, never guessed at.
enum ID3Text {
    /// 2.3 allows only Latin-1 and UTF-16; a value in anything else can be shown but isn't offered.
    static func isLegal(_ encoding: UInt8, version: UInt8) -> Bool {
        encoding <= (version == 3 ? 1 : 3)
    }

    /// 2.4 is UTF-8; 2.3 stays ASCII when it can, for older players, else UTF-16.
    static func preferredEncoding(for value: String, version: UInt8) -> UInt8 {
        if version != 3 { return 3 }
        return value.utf8.allSatisfy { $0 < 0x80 } ? 0 : 1
    }

    static func terminator(_ encoding: UInt8) -> Data {
        encoding == 1 || encoding == 2 ? Data([0, 0]) : Data([0])
    }

    static func encode(_ text: String, encoding: UInt8) -> Data {
        switch encoding {
        case 1: return Data([0xFF, 0xFE]) + text.utf16.reduce(into: Data()) { $0 += Data.littleEndian(Int($1), bytes: 2) }
        case 2: return text.utf16.reduce(into: Data()) { $0 += Data.bigEndian(Int($1), bytes: 2) }
        case 3: return Data(text.utf8)
        default: return Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        }
    }

    /// Cuts at the encoding's terminator, `limit` pieces at most; the last piece keeps the rest.
    static func split(_ bytes: Data, encoding: UInt8, limit: Int) -> [Data] {
        let bytes = Data(bytes)
        let width = encoding == 1 || encoding == 2 ? 2 : 1
        var parts: [Data] = []
        var start = 0, index = 0
        while index + width <= bytes.count, parts.count + 1 < limit {
            if bytes[index] == 0, width == 1 || bytes[index + 1] == 0 {
                parts.append(bytes.subdata(in: start..<index))
                index += width
                start = index
            } else {
                index += width
            }
        }
        parts.append(bytes.subdata(in: start..<bytes.count))
        return parts
    }

    /// nil when the bytes aren't valid in the encoding, or it isn't one of the four.
    static func decode(_ bytes: Data, encoding: UInt8) -> String? {
        let bytes = Data(bytes)
        switch encoding {
        case 0: return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        case 1:
            guard !bytes.isEmpty else { return "" }
            guard bytes.count >= 2 else { return nil }
            if bytes[0] == 0xFF, bytes[1] == 0xFE { return utf16(bytes.subdata(in: 2..<bytes.count), bigEndian: false) }
            if bytes[0] == 0xFE, bytes[1] == 0xFF { return utf16(bytes.subdata(in: 2..<bytes.count), bigEndian: true) }
            return nil
        case 2: return utf16(bytes, bigEndian: true)
        case 3: return String(data: bytes, encoding: .utf8)
        default: return nil
        }
    }

    private static func utf16(_ bytes: Data, bigEndian: Bool) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        let units = stride(from: 0, to: bytes.count, by: 2).map { index -> UInt16 in
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            return bigEndian ? first << 8 | second : second << 8 | first
        }
        var decoder = UTF16()
        var iterator = units.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }
}

/// The genre codes ID3v1 defined, which ID3v2's genre frame and M4A's `gnre` atom still point into.
enum ID3Genre {
    static func name(_ index: Int) -> String? { names.indices.contains(index) ? names[index] : nil }

    /// "(17)" and "17" become the name. Anything else in brackets mixes codes with text and can't be rewritten as one value.
    static func resolve(_ raw: EmbeddedReader.Raw) -> EmbeddedReader.Raw {
        let text = raw.text
        let inner = text.hasPrefix("(") && text.hasSuffix(")") ? String(text.dropFirst().dropLast()) : text
        if !inner.isEmpty, inner.utf8.allSatisfy({ (48...57).contains($0) }), inner.utf8.count <= 3, let index = Int(inner) {
            guard let known = name(index) else { return EmbeddedReader.Raw(text: text, canEdit: false) }
            return EmbeddedReader.Raw(text: known, canEdit: raw.canEdit)
        }
        return EmbeddedReader.Raw(text: text, canEdit: raw.canEdit && !text.hasPrefix("("))
    }

    private static let names = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop",
        "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno",
        "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip",
        "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic",
        "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer",
        "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}
