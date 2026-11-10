import Foundation

/// FLAC files (FE-152): only the VORBIS_COMMENT block changes, comment by comment; the vendor string, every other block and all frames are kept.
struct FLACFormat: TagRegionFormat {
    static let identifier = "org.xiph.flac"
    let typeIdentifier = identifier

    private static let maxBlocks = 4096, maxComments = 65_536
    private static let commentBlock: UInt8 = 4
    private static let damaged = L10n.tr("This FLAC file is damaged or uses features Arbor doesn't understand, so its properties are read-only.")

    private static func field(forKey key: String) -> EmbeddedField? {
        switch key.uppercased() {
        case "TITLE": return .title
        case "ARTIST": return .artist
        case "ALBUM": return .album
        case "DATE", "YEAR": return .year
        case "TRACKNUMBER": return .track
        case "GENRE": return .genre
        case "COMMENT", "DESCRIPTION": return .comment
        default: return nil
        }
    }

    private static func key(for field: EmbeddedField) -> String? {
        switch field {
        case .title: return "TITLE"
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .year: return "DATE"
        case .track: return "TRACKNUMBER"
        case .genre: return "GENRE"
        case .comment: return "COMMENT"
        default: return nil
        }
    }

    func layout(of file: EmbeddedFileReader) -> TagLayout? {
        guard file.bytes(at: 0, count: 4) == Data("fLaC".utf8) else { return nil }
        var offset: Int64 = 4, count = 0, isLast = false
        var comments: Range<Int64>?
        while !isLast {
            guard count < Self.maxBlocks, let header = file.bytes(at: offset, count: 4),
                  let length = header.bigEndian(at: 1, bytes: 3), Int64(length) <= file.size - offset - 4 else { return TagLayout(blocked: Self.damaged) }
            let type = header[0] & 0x7F
            isLast = header[0] & 0x80 != 0
            // The first block is always the 34-byte stream information; 127 is forbidden by the format.
            guard count > 0 ? type != 0 && type != 127 : type == 0 && length == 34 else { return TagLayout(blocked: Self.damaged) }
            let block = offset..<(offset + 4 + Int64(length))
            if type == Self.commentBlock {
                guard comments == nil else { return TagLayout(blocked: L10n.tr("This FLAC file has more than one comment block, so its properties are read-only.")) }
                comments = block
            }
            offset = block.upperBound
            count += 1
        }
        guard let sync = file.bytes(at: offset, count: 2), sync[0] == 0xFF, sync[1] & 0xFE == 0xF8 else { return TagLayout(blocked: Self.damaged) }
        guard let comments else { return TagLayout(blocked: L10n.tr("This FLAC file has no comment block to edit, so its properties are read-only.")) }
        return Self.parseComments(comments, file) ?? TagLayout(blocked: Self.damaged)
    }

    /// nil unless the block's lengths add up exactly; it is at most 16 MiB by the format's own size field.
    private static func parseComments(_ block: Range<Int64>, _ file: EmbeddedFileReader) -> TagLayout? {
        guard let bytes = file.bytes(block), let vendor = bytes.littleEndian(at: 4, bytes: 4), vendor <= bytes.count - 8 else { return nil }
        var layout = TagLayout(region: block)
        let origin = block.lowerBound
        layout.items = [TagItem(range: origin..<(origin + 1), field: nil), TagItem(range: (origin + 4)..<(origin + 8 + Int64(vendor)), field: nil)]
        var index = 8 + vendor
        guard let count = bytes.littleEndian(at: index, bytes: 4), count <= maxComments else { return nil }
        index += 4
        for _ in 0..<count {
            guard let length = bytes.littleEndian(at: index, bytes: 4), length <= bytes.count - index - 4 else { return nil }
            let text = bytes.subdata(in: (index + 4)..<(index + 4 + length))
            guard let separator = text.firstIndex(of: UInt8(ascii: "=")), text[..<separator].allSatisfy({ (0x20...0x7D).contains($0) }) else { return nil }
            let found = field(forKey: String(decoding: text[..<separator], as: UTF8.self))
            if let found {
                let value = String(data: text[text.index(after: separator)...], encoding: .utf8)
                layout.record(found, EmbeddedReader.Raw(text: value ?? "", canEdit: value != nil))
            }
            layout.items.append(TagItem(range: (origin + Int64(index))..<(origin + Int64(index) + 4 + Int64(length)), field: found))
            index += 4 + length
        }
        return index == bytes.count ? layout : nil
    }

    func regionPieces(for edits: [EmbeddedField: String], in layout: TagLayout, of file: EmbeddedFileReader) throws -> [TagPiece] {
        guard layout.items.count >= 2, let flag = file.bytes(layout.items[0].range) else { throw EmbeddedFailure.changedSinceRead }
        var body: [TagPiece] = [], size = Int64(layout.items[1].range.count) + 4, comments = 0
        var placed = Set<EmbeddedField>()
        func add(_ comment: Data) {
            body.append(.bytes(Data.littleEndian(comment.count, bytes: 4) + comment))
            size += Int64(comment.count) + 4
            comments += 1
        }
        for item in layout.items.dropFirst(2) {
            guard let field = item.field, let value = edits[field] else {
                body.append(.copy(item.range))
                size += Int64(item.range.count)
                comments += 1
                continue
            }
            placed.insert(field)
            guard !value.isEmpty else { continue }
            // The original's spelling of the key stays. The search starts past the length prefix, whose bytes can equal "=".
            guard let old = file.bytes(item.range), let separator = old[4...].firstIndex(of: UInt8(ascii: "=")) else { throw EmbeddedFailure.changedSinceRead }
            add(old[4...separator] + Data(value.utf8))
        }
        for field in EmbeddedField.allCases where edits[field]?.isEmpty == false && !placed.contains(field) {
            guard let key = Self.key(for: field), let value = edits[field] else { throw EmbeddedFailure.notEditable }
            add(Data("\(key)=\(value)".utf8))
        }
        guard size < 1 << 24 else { throw EmbeddedFailure.writeFailed }
        return [.bytes(flag + Data.bigEndian(Int(size), bytes: 3)), .copy(layout.items[1].range),
                .bytes(Data.littleEndian(comments, bytes: 4))] + body
    }
}
