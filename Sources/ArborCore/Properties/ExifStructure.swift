import Foundation

/// A bounded walk of an Exif block's directories, for the data ImageIO's properties never show (FE-152).
enum ExifStructure {
    enum Directory: Hashable { case main, exif, gps }

    struct Tag: Hashable {
        let directory: Directory
        let id: Int
    }

    struct Contents: Equatable {
        var tags = Set<Tag>()
        /// Empty when there is none.
        var makerNote = Data()
    }

    static let imageDescription = 0x010E, dateTimeOriginal = 0x9003
    private static let exifPointer = 0x8769, gpsPointer = 0x8825, makerNoteTag = 0x927C
    /// Padding that Windows reserves for later edits; it holds nothing to lose.
    private static let padding: Set<Int> = [0xEA1C, 0xEA1D]
    private static let maxEntries = 4096

    /// nil when `block` (a TIFF header and its directories) can't be followed; the caller treats that as doubt.
    static func read(_ block: Data) -> Contents? {
        guard let reader = Reader(block), let first = reader.u32(4) else { return nil }
        var contents = Contents()
        var pending: [(offset: Int, directory: Directory)] = [(first, .main)]
        var budget = maxEntries
        while let next = pending.popLast() {
            guard let count = reader.u16(next.offset) else { return nil }
            budget -= count
            guard budget >= 0 else { return nil }
            for index in 0..<count {
                let entry = next.offset + 2 + index * 12
                guard let id = reader.u16(entry), let type = reader.u16(entry + 2), let length = reader.u32(entry + 4),
                      let inline = reader.u32(entry + 8) else { return nil }
                switch (next.directory, id) {
                case (.main, exifPointer): pending.append((inline, .exif))
                case (.main, gpsPointer): pending.append((inline, .gps))
                case (.exif, makerNoteTag):
                    guard type == 1 || type == 7, let note = reader.bytes(length, at: length <= 4 ? entry + 8 : inline) else { return nil }
                    contents.makerNote = note
                    contents.tags.insert(Tag(directory: .exif, id: id))
                default:
                    if !padding.contains(id) { contents.tags.insert(Tag(directory: next.directory, id: id)) }
                }
            }
        }
        return contents
    }

    /// Every tag of `before` is in `after`, bar those the edit may remove, and the maker note is byte-identical.
    static func survives(_ before: Contents, in after: Contents, removable: Set<Int>) -> Bool {
        before.makerNote == after.makerNote && before.tags.allSatisfy { after.tags.contains($0) || removable.contains($0.id) }
    }

    /// Offsets are counted from the TIFF header, so the block is rebased to start at zero.
    private struct Reader {
        private let data: Data
        private let bigEndian: Bool

        init?(_ block: Data) {
            data = Data(block)
            guard data.count >= 8, data[0] == data[1], data[0] == UInt8(ascii: "I") || data[0] == UInt8(ascii: "M") else { return nil }
            bigEndian = data[0] == UInt8(ascii: "M")
            guard u16(2) == 42 else { return nil }
        }

        func u16(_ offset: Int) -> Int? { number(2, at: offset) }
        func u32(_ offset: Int) -> Int? { number(4, at: offset) }

        func bytes(_ count: Int, at offset: Int) -> Data? {
            guard offset >= 0, count >= 0, count <= data.count, offset <= data.count - count else { return nil }
            return data.subdata(in: offset..<(offset + count))
        }

        private func number(_ width: Int, at offset: Int) -> Int? {
            guard let field = bytes(width, at: offset) else { return nil }
            return (bigEndian ? Array(field) : field.reversed()).reduce(0) { $0 << 8 | Int($1) }
        }
    }
}
