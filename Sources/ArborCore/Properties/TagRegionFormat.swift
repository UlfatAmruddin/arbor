import Foundation
import Darwin

/// One piece of a file's new metadata region. Originals are copied, never held, so a large picture stays on disk.
enum TagPiece {
    case bytes(Data)
    case copy(Range<Int64>)
    case zeros(Int64)
}

/// A stretch of the region that an edit keeps byte for byte, or that holds `field`'s value.
struct TagItem: Equatable {
    let range: Range<Int64>
    var field: EmbeddedField?
}

/// Where a file's editable metadata lives, and what is in it.
struct TagLayout {
    /// The only bytes an edit may touch; everything before and after stays byte for byte.
    var region: Range<Int64>
    /// In file order. What is in `region` and not here is structure or padding that a rewrite regenerates.
    var items: [TagItem] = []
    var fields: [EmbeddedField: EmbeddedReader.Raw] = [:]
    /// Why this file stays read-only.
    var blocked: String?
    /// True when something after the region can't change position.
    var suffixIsPinned = false

    init(region: Range<Int64>) { self.region = region }

    init(blocked reason: String) {
        region = 0..<0
        blocked = reason
    }

    mutating func block(_ reason: String) {
        if blocked == nil { blocked = reason }
    }

    /// A second value for a field can't be rewritten as one, so the field is shown but not offered.
    mutating func record(_ field: EmbeddedField, _ raw: EmbeddedReader.Raw) {
        if let first = fields[field] {
            fields[field] = EmbeddedReader.Raw(text: first.text, canEdit: false)
        } else {
            fields[field] = raw
        }
    }

    func kept(excluding edited: Set<EmbeddedField>) -> [Range<Int64>] {
        items.compactMap { item in
            if let field = item.field, edited.contains(field) { return nil }
            return item.range
        }
    }
}

/// A format whose properties sit in one region of a parsed file: the rest is streamed through untouched.
protocol TagRegionFormat: EmbeddedFormat {
    var typeIdentifier: String { get }
    /// nil when the file isn't this format. Never trusts a size field.
    func layout(of file: EmbeddedFileReader) -> TagLayout?
    /// The new contents of `layout.region`.
    func regionPieces(for edits: [EmbeddedField: String], in layout: TagLayout, of file: EmbeddedFileReader) throws -> [TagPiece]
}

extension TagRegionFormat {
    var typeIdentifiers: Set<String> { [typeIdentifier] }
    var maxFileBytes: Int64 { EmbeddedLimits.maxStreamedFileBytes }

    func inspect(_ url: URL, info: stat) -> EmbeddedInspection? {
        // Reading an online-only file would download it just to fill a panel.
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let file = EmbeddedFileReader(descriptor: descriptor), let layout = layout(of: file),
              let support = EmbeddedSupport.forType(typeIdentifier) else { return nil }
        return EmbeddedInspection(typeIdentifier: typeIdentifier, support: support, fields: layout.fields, budgetBlock: nil,
                                  contentBlock: layout.blocked.map(EmbeddedFailure.structure))
    }

    func produce(_ edits: [EmbeddedField: String], from held: EmbeddedHeldFile, type: String, to staged: URL) throws {
        guard let file = EmbeddedFileReader(descriptor: held.descriptor), let layout = layout(of: file) else { throw EmbeddedFailure.changedSinceRead }
        if let reason = layout.blocked { throw EmbeddedFailure.structure(reason) }
        let region = try regionPieces(for: edits, in: layout, of: file)
        try TagPieceWriter.write([.copy(0..<layout.region.lowerBound)] + region + [.copy(layout.region.upperBound..<file.size)], from: file, to: staged)
    }

    func verify(_ edits: [EmbeddedField: String], original held: EmbeddedHeldFile, written: URL, type: String) throws {
        guard let file = EmbeddedFileReader(descriptor: held.descriptor) else { throw EmbeddedFailure.changedSinceRead }
        try TagRegionVerifier.verify(self, edits: edits, original: file, written: written)
    }
}

/// Bounded random access to an open file: every offset and length is checked, so a hostile size field can only cause a refusal.
struct EmbeddedFileReader {
    /// Covers FLAC's largest possible metadata block.
    static let maxRead = 17 << 20
    static let chunkSize = 1 << 20

    let descriptor: Int32
    let size: Int64

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return nil }
        self.descriptor = descriptor
        size = Int64(info.st_size)
    }

    func contains(_ range: Range<Int64>) -> Bool { range.lowerBound >= 0 && range.upperBound <= size }

    /// nil unless exactly `count` bytes exist at `offset`.
    func bytes(at offset: Int64, count: Int) -> Data? {
        guard (0...Self.maxRead).contains(count), offset >= 0, offset <= size, Int64(count) <= size - offset else { return nil }
        var data = Data(count: count)
        return data.withUnsafeMutableBytes { Self.fill($0, from: descriptor, at: offset) } ? data : nil
    }

    func bytes(_ range: Range<Int64>) -> Data? {
        guard let count = Int(exactly: range.upperBound - range.lowerBound) else { return nil }
        return bytes(at: range.lowerBound, count: count)
    }

    /// Hands `range` to `body` one chunk at a time; false when it can't all be read or `body` stops early.
    func stream(_ range: Range<Int64>, _ body: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        guard contains(range) else { return false }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
        defer { buffer.deallocate() }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let count = Int(min(Int64(Self.chunkSize), range.upperBound - offset))
            let part = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
            guard Self.fill(part, from: descriptor, at: offset), body(UnsafeRawBufferPointer(part)) else { return false }
            offset += Int64(count)
        }
        return true
    }

    func isAllZero(_ range: Range<Int64>) -> Bool {
        stream(range) { chunk in chunk.allSatisfy { $0 == 0 } }
    }

    /// Compares chunk by chunk, so neither range is ever held whole.
    func sameBytes(_ range: Range<Int64>, as other: EmbeddedFileReader, _ otherRange: Range<Int64>) -> Bool {
        guard range.count == otherRange.count, other.contains(otherRange) else { return false }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
        defer { buffer.deallocate() }
        var position = otherRange.lowerBound
        return stream(range) { chunk in
            let part = UnsafeMutableRawBufferPointer(rebasing: buffer[..<chunk.count])
            guard Self.fill(part, from: other.descriptor, at: position), memcmp(part.baseAddress, chunk.baseAddress, chunk.count) == 0 else { return false }
            position += Int64(chunk.count)
            return true
        }
    }

    private static func fill(_ buffer: UnsafeMutableRawBufferPointer, from descriptor: Int32, at offset: Int64) -> Bool {
        var done = 0
        while done < buffer.count {
            guard let base = buffer.baseAddress else { return false }
            let got = pread(descriptor, base + done, buffer.count - done, offset + Int64(done))
            if got > 0 {
                done += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

/// Writes pieces to a new private file, streaming everything copied.
enum TagPieceWriter {
    static func write(_ pieces: [TagPiece], from file: EmbeddedFileReader, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw EmbeddedFailure.writeFailed }
        defer { close(descriptor) }
        for piece in pieces {
            let wrote: Bool
            switch piece {
            case .bytes(let data): wrote = data.withUnsafeBytes { writeAll(descriptor, $0) }
            case .copy(let range): wrote = file.stream(range) { writeAll(descriptor, $0) }
            case .zeros(let count): wrote = zeros(count, to: descriptor)
            }
            guard wrote else { throw EmbeddedFailure.writeFailed }
        }
        guard fsync(descriptor) == 0 else { throw EmbeddedFailure.writeFailed }
    }

    private static func zeros(_ count: Int64, to descriptor: Int32) -> Bool {
        let chunk = [UInt8](repeating: 0, count: EmbeddedFileReader.chunkSize)
        var left = count
        while left > 0 {
            let part = Int(min(left, Int64(chunk.count)))
            guard chunk.withUnsafeBytes({ writeAll(descriptor, UnsafeRawBufferPointer(rebasing: $0[..<part])) }) else { return false }
            left -= Int64(part)
        }
        return true
    }

    private static func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        var done = 0
        while done < buffer.count {
            guard let base = buffer.baseAddress else { return false }
            let wrote = Darwin.write(descriptor, base + done, buffer.count - done)
            if wrote > 0 {
                done += wrote
            } else if wrote < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

extension Data {
    /// A big-endian unsigned value of up to four bytes; nil outside the data.
    func bigEndian(at index: Int, bytes count: Int) -> Int? {
        guard (1...4).contains(count), index >= 0, index <= self.count - count else { return nil }
        return (0..<count).reduce(0) { $0 << 8 | Int(self[startIndex + index + $1]) }
    }

    func littleEndian(at index: Int, bytes count: Int) -> Int? {
        guard (1...4).contains(count), index >= 0, index <= self.count - count else { return nil }
        return (0..<count).reversed().reduce(0) { $0 << 8 | Int(self[startIndex + index + $1]) }
    }

    /// The low `count` bytes of `value`, most significant first.
    static func bigEndian(_ value: Int, bytes count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    static func littleEndian(_ value: Int, bytes count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
