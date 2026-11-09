import Foundation

/// Reads a RAR's own headers for what bsdtar can't report (FE-167), seeking over member data and never unpacking.
/// Bytes that aren't valid headers stop the walk: libarchive decides what those mean.
enum RarHeaders {
    struct Traits: Sendable, Equatable {
        /// A member's data is encrypted; libarchive would write the ciphertext as if it were the file.
        var hasEncryptedMembers = false
        /// One file of a set; libarchive reads only this file, so split members come out cut short or padded.
        var isMultiVolume = false
        /// Headers or data run past the end of the file; RAR5 reading can stop there without an error.
        var isTruncated = false
        /// RAR5 hard links, which bsdtar lists with a regular file's "-" instead of "h".
        var hasHardLinks = false
        /// Regular RAR5 members whose own name reads like one of those rows.
        var regularNamesLikeHardLinks: Set<String> = []
        /// RAR5 file copies and junctions, which libarchive writes as empty files.
        var hasFileReferences = false

        /// Why the archive can't be read correctly at all, or nil.
        var refusal: String? {
            if isMultiVolume { return L10n.tr("This is one part of a multi-volume RAR archive. Arbor can only read RAR archives that are a single file.") }
            if hasFileReferences { return L10n.tr("This RAR archive stores some files as references to other files, which Arbor can't extract.") }
            return nil
        }

        /// Adds to bsdtar's listing. Encryption covers every row, because rows can't be matched to headers reliably.
        func apply(to listing: inout ArchiveTool.Listing) throws {
            if hasEncryptedMembers {
                for i in listing.entries.indices { listing.entries[i].isEncrypted = true }
            }
            guard isTruncated, listing.warning == nil else { return }
            let message = L10n.tr("The file ends before the archive does.")
            if listing.entries.isEmpty { throw ArchiveError.unreadable(message) }
            listing.warning = message
        }
    }

    private static let rar4Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    private static let rar5Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
    /// The RAR5 format's ceiling; anything larger isn't a header.
    private static let maxRar5HeaderBytes: UInt64 = 2 << 20
    /// Names past this stay read as links, the side that goes through the link checks.
    private static let maxNamesLikeHardLinksBytes = 1 << 20

    /// The traits of the file at `url`; empty when it can't be read or isn't a RAR.
    static func traits(of url: URL) -> Traits {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Traits() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Traits() }
        let file = Source(handle: handle, size: size)
        if file.bytes(at: 0, count: rar5Signature.count) == rar5Signature { return walkRar5(file) }
        if file.bytes(at: 0, count: rar4Signature.count) == rar4Signature { return walkRar4(file) }
        return Traits()
    }

    private static func walkRar4(_ file: Source) -> Traits {
        var traits = Traits()
        var offset = UInt64(rar4Signature.count)
        guard offset < file.size else { traits.isTruncated = true; return traits }
        for _ in 0...ZipDirectory.maxEntries {
            if offset == file.size { return traits }   // the end block is optional in RAR4
            guard let start = file.bytes(at: offset, count: 7) else { traits.isTruncated = true; return traits }
            let type = start[2], flags = le16(start, 3), headerSize = UInt64(le16(start, 5))
            guard (0x72...0x7B).contains(type), headerSize >= 7 else { return traits }
            guard headerSize <= file.size - offset else { traits.isTruncated = true; return traits }
            // Sizes and flags sit in the first 36 bytes; a shorter header simply has none of them.
            guard let header = file.bytes(at: offset, count: Int(min(headerSize, 36))) else { return traits }
            var dataSize: UInt64 = 0
            switch type {
            case 0x73:
                if flags & 0x0001 != 0 { traits.isMultiVolume = true }
                // Everything after an encrypted main header is unreadable.
                if flags & 0x0080 != 0 { traits.hasEncryptedMembers = true; return traits }
            case 0x7B:
                return traits
            case 0x74, 0x7A:
                guard header.count >= 32 else { return traits }
                dataSize = UInt64(le32(header, 7))
                if flags & 0x0100 != 0, header.count >= 36 { dataSize |= UInt64(le32(header, 32)) << 32 }
                if type == 0x74 {
                    if flags & 0x0004 != 0 { traits.hasEncryptedMembers = true }
                    if flags & 0x0003 != 0 { traits.isMultiVolume = true }
                }
            default:
                if flags & 0x8000 != 0, header.count >= 11 { dataSize = UInt64(le32(header, 7)) }
            }
            offset += headerSize
            guard dataSize <= file.size - offset else { traits.isTruncated = true; return traits }
            offset += dataSize
        }
        return traits
    }

    private static func walkRar5(_ file: Source) -> Traits {
        var traits = Traits()
        var nameBudget = maxNamesLikeHardLinksBytes
        var offset = UInt64(rar5Signature.count)
        guard offset < file.size else { traits.isTruncated = true; return traits }
        for _ in 0...ZipDirectory.maxEntries {
            if offset == file.size { return traits }
            // CRC32, then the header size as a vint of at most 10 bytes.
            guard let start = file.bytes(at: offset, count: Int(min(14, file.size - offset))), start.count > 4 else {
                traits.isTruncated = true
                return traits
            }
            var prefix = Cursor(bytes: start, position: 4)
            guard let size = prefix.vint() else { traits.isTruncated = start.count < 14; return traits }
            guard size > 0, size <= maxRar5HeaderBytes else { return traits }
            offset += UInt64(prefix.position)
            guard let body = file.bytes(at: offset, count: Int(size)) else { traits.isTruncated = true; return traits }
            offset += size

            var header = Cursor(bytes: body)
            guard let type = header.vint(), let flags = header.vint() else { return traits }
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x01 != 0 { guard let value = header.vint() else { return traits }; extraSize = value }
            if flags & 0x02 != 0 { guard let value = header.vint() else { return traits }; dataSize = value }
            guard extraSize <= size else { return traits }
            switch type {
            case 1:
                guard let archiveFlags = header.vint() else { return traits }
                if archiveFlags & 0x01 != 0 { traits.isMultiVolume = true }
            case 2:
                if flags & 0x18 != 0 { traits.isMultiVolume = true }
                let extraStart = body.count - Int(extraSize)
                let isHardLink = scanExtraRecords(body, from: extraStart, into: &traits)
                if !isHardLink, let name = rar5Name(&header, end: extraStart), BsdtarListing.readsLikeHardLink(name), name.utf8.count <= nameBudget {
                    nameBudget -= name.utf8.count
                    traits.regularNamesLikeHardLinks.insert(name)
                }
            case 4:
                // Every later header is encrypted.
                traits.hasEncryptedMembers = true
                return traits
            case 5:
                return traits
            default:
                break
            }
            guard dataSize <= file.size - offset else { traits.isTruncated = true; return traits }
            offset += dataSize
        }
        return traits
    }

    /// The name from a RAR5 file header's own fields, with `fields` just past the common ones.
    private static func rar5Name(_ fields: inout Cursor, end: Int) -> String? {
        guard let fileFlags = fields.vint(), fields.vint() != nil, fields.vint() != nil else { return nil }
        // The modification time and the checksum, four bytes each when present.
        fields.position += (fileFlags & 0x02 != 0 ? 4 : 0) + (fileFlags & 0x04 != 0 ? 4 : 0)
        guard fields.vint() != nil, fields.vint() != nil, let count = fields.vint(),
              fields.position <= end, count <= UInt64(end - fields.position) else { return nil }
        return String(decoding: fields.bytes[fields.position..<fields.position + Int(count)], as: UTF8.self)
    }

    /// RAR5 extra records: size (from the type on), type, data. Type 1 is encryption, 5 a link or reference. True for a hard link.
    private static func scanExtraRecords(_ body: [UInt8], from start: Int, into traits: inout Traits) -> Bool {
        var cursor = Cursor(bytes: body, position: start)
        var isHardLink = false
        while cursor.position < body.count {
            guard let size = cursor.vint(), size > 0, size <= UInt64(body.count - cursor.position) else { return isHardLink }
            let next = cursor.position + Int(size)
            guard let type = cursor.vint() else { return isHardLink }
            if type == 1 { traits.hasEncryptedMembers = true }
            if type == 5, let redirection = cursor.vint() {
                if redirection == 4 { traits.hasHardLinks = true; isHardLink = true }
                if redirection == 3 || redirection == 5 { traits.hasFileReferences = true }
            }
            cursor.position = next
        }
        return isHardLink
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private struct Source {
        let handle: FileHandle
        let size: UInt64

        /// Exactly `count` bytes at `offset`, or nil when the file ends first or can't be read.
        func bytes(at offset: UInt64, count: Int) -> [UInt8]? {
            guard offset <= size, UInt64(count) <= size - offset else { return nil }
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
    }

    private struct Cursor {
        let bytes: [UInt8]
        var position = 0

        /// A RAR5 variable-length integer, or nil when it runs out of bytes or past 10 bytes.
        mutating func vint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: UInt64(0), to: 70, by: 7) {
                guard position < bytes.count else { return nil }
                let byte = bytes[position]
                position += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
    }
}
