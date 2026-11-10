import Foundation

/// An Office Open XML package read strictly as a ZIP file (FE-152): one end record, every entry's local header agreeing with the
/// central directory, entries back to back from the first byte, nothing hidden between them. Anything else is read-only.
struct OfficePackage {
    static let damaged = EmbeddedFailure.structure(L10n.tr("This Office document is damaged or stored in a way Arbor doesn't understand, so its properties are read-only."))
    static let corePart = Data("docProps/core.xml".utf8)
    /// Larger core properties are not what Office writes; reading them would only cost memory.
    static let maxCoreCompressed: Int64 = 1 << 20
    private static let maxPart = 4 << 20

    struct Entry {
        let name: Data
        /// The whole central-directory record, copied back with only its offset changed.
        let record: Data
        let flags: Int
        let method: Int
        let crc: UInt32
        let compressedSize: Int64
        let uncompressedSize: Int64
        let localOffset: Int64
        /// The local header, data and any data descriptor.
        var extent: Range<Int64> = 0..<0
        var dataStart: Int64 = 0
    }

    let file: EmbeddedFileReader
    /// In central-directory order.
    let entries: [Entry]
    let directory: Range<Int64>
    /// The end record and archive comment, kept as they are.
    let end: Data
    let coreIndex: Int
    /// Why an otherwise readable package can't be written.
    let readOnlyReason: String?

    /// Throws `EmbeddedFailure.structure` when the package can't be read at all.
    init(_ file: EmbeddedFileReader) throws {
        self.file = file
        let (endOffset, end) = try Self.endRecord(file)
        guard let fields = Self.fields(end, [4, 6, 8, 10, 12, 16], [2, 2, 2, 2, 4, 4]) else { throw Self.damaged }
        let (disk, directoryDisk, here, total, size, offset) = (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])
        if here == 0xFFFF || total == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw Self.zip64 }
        if disk != 0 || directoryDisk != 0 || here != total {
            throw EmbeddedFailure.structure(L10n.tr("This Office document spans several disks, so its properties are read-only."))
        }
        if endOffset >= 20, file.bytes(at: endOffset - 20, count: 4) == Data([0x50, 0x4B, 0x06, 0x07]) { throw Self.zip64 }
        guard Int64(offset) + Int64(size) == endOffset, size <= EmbeddedFileReader.maxRead,
              let central = file.bytes(at: Int64(offset), count: size) else { throw Self.damaged }
        directory = Int64(offset)..<endOffset
        self.end = end
        var entries = try Self.parseDirectory(central, count: total, before: directory.lowerBound)
        try Self.placeLocalHeaders(&entries, file, directoryStart: directory.lowerBound)
        self.entries = entries

        var names = Set<Data>()
        for entry in entries {
            guard names.insert(Data(entry.name.map { (65...90).contains($0) ? $0 + 32 : $0 })).inserted else {
                throw EmbeddedFailure.structure(L10n.tr("This Office document has two parts with the same name, so its properties are read-only."))
            }
        }
        guard let types = entries.firstIndex(where: { $0.name == Data("[Content_Types].xml".utf8) }),
              let relations = entries.firstIndex(where: { $0.name == Data("_rels/.rels".utf8) }) else { throw Self.damaged }
        let typesXML = try Self.part(entries[types], file, limit: Self.maxPart), relationsXML = try Self.part(entries[relations], file, limit: Self.maxPart)
        guard let core = entries.firstIndex(where: { $0.name == Self.corePart }), Self.coreTarget(relationsXML) == Self.corePart else {
            throw EmbeddedFailure.structure(L10n.tr("This Office document has no core properties part to edit, so its properties are read-only."))
        }
        coreIndex = core

        let signature = Data("digital-signature".utf8)
        if entries.contains(where: { String(decoding: $0.name, as: UTF8.self).lowercased().hasPrefix("_xmlsignatures/") })
            || typesXML.range(of: signature) != nil || relationsXML.range(of: signature) != nil {
            readOnlyReason = L10n.tr("This Office document is digitally signed, and changing it would invalidate the signature, so its properties are read-only.")
        } else if entries[core].compressedSize > Self.maxCoreCompressed || entries[core].uncompressedSize > Int64(SafeXML.maxBytes) {
            readOnlyReason = L10n.tr("This Office document's core properties are unusually large, so its properties are read-only.")
        } else {
            readOnlyReason = nil
        }
    }

    private static let zip64 = EmbeddedFailure.structure(L10n.tr("This Office document uses the ZIP64 format, so its properties are read-only."))

    /// The single end record whose comment runs exactly to the end of the file; two candidates would be two readings.
    private static func endRecord(_ file: EmbeddedFileReader) throws -> (offset: Int64, record: Data) {
        let count = Int(min(file.size, 22 + 65_535))
        guard count >= 22, let tail = file.bytes(at: file.size - Int64(count), count: count) else { throw damaged }
        let bytes = [UInt8](tail)
        var found: [Int] = []
        for index in stride(from: bytes.count - 22, through: 0, by: -1)
        where bytes[index] == 0x50 && bytes[index + 1] == 0x4B && bytes[index + 2] == 5 && bytes[index + 3] == 6
            && Int(bytes[index + 20]) | Int(bytes[index + 21]) << 8 == bytes.count - index - 22 {
            found.append(index)
        }
        guard found.count == 1, let index = found.first else { throw damaged }
        return (file.size - Int64(count) + Int64(index), Data(bytes[index...]))
    }

    /// Little-endian fields at `offsets` with `widths`; nil if any falls outside.
    private static func fields(_ data: Data, _ offsets: [Int], _ widths: [Int]) -> [Int]? {
        let values = zip(offsets, widths).compactMap { data.littleEndian(at: $0, bytes: $1) }
        return values.count == offsets.count ? values : nil
    }

    private static func parseDirectory(_ central: Data, count: Int, before limit: Int64) throws -> [Entry] {
        var entries: [Entry] = []
        var index = 0
        for _ in 0..<count {
            guard central.littleEndian(at: index, bytes: 4) == 0x0201_4B50,
                  let values = fields(central, [8, 10, 16, 20, 24, 28, 30, 32, 34, 42].map { index + $0 }, [2, 2, 4, 4, 4, 2, 2, 2, 2, 4]) else { throw damaged }
            let (flags, method, crc, compressed, size, nameLength) = (values[0], values[1], values[2], values[3], values[4], values[5])
            let (extraLength, commentLength, disk, offset) = (values[6], values[7], values[8], values[9])
            let next = index + 46 + nameLength + extraLength + commentLength
            guard next <= central.count, nameLength > 0, disk == 0 else { throw damaged }
            if compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF
                || hasZip64Extra(central.subdata(in: (index + 46 + nameLength)..<(index + 46 + nameLength + extraLength))) { throw zip64 }
            if flags & 0x2041 != 0 { throw EmbeddedFailure.structure(L10n.tr("This Office document is encrypted, so its properties are read-only.")) }
            guard Int64(offset) < limit else { throw damaged }
            entries.append(Entry(name: central.subdata(in: (index + 46)..<(index + 46 + nameLength)), record: central.subdata(in: index..<next),
                                 flags: flags, method: method, crc: UInt32(crc), compressedSize: Int64(compressed),
                                 uncompressedSize: Int64(size), localOffset: Int64(offset)))
            index = next
        }
        guard index == central.count else { throw damaged }
        return entries
    }

    private static func hasZip64Extra(_ extra: Data) -> Bool {
        var index = 0
        while let id = extra.littleEndian(at: index, bytes: 2), let length = extra.littleEndian(at: index + 2, bytes: 2) {
            if id == 0x0001 { return true }
            index += 4 + length
        }
        return false
    }

    /// Each local header must say what the directory says, and the entries must tile the file up to the directory exactly.
    private static func placeLocalHeaders(_ entries: inout [Entry], _ file: EmbeddedFileReader, directoryStart: Int64) throws {
        for index in entries.indices {
            let entry = entries[index]
            guard let header = file.bytes(at: entry.localOffset, count: 30), header.littleEndian(at: 0, bytes: 4) == 0x0403_4B50,
                  let values = fields(header, [6, 8, 14, 18, 22, 26, 28], [2, 2, 4, 4, 4, 2, 2]),
                  values[0] == entry.flags, values[1] == entry.method else { throw damaged }
            // With a data descriptor a writer may leave any of these zero; the descriptor itself is checked below.
            let deferred = entry.flags & 0x08 != 0
            let expected = [Int64(entry.crc), entry.compressedSize, entry.uncompressedSize]
            guard zip(values[2...4], expected).allSatisfy({ Int64($0) == $1 || (deferred && $0 == 0) }) else { throw damaged }
            let nameStart = entry.localOffset + 30
            guard let name = file.bytes(at: nameStart, count: values[5]), name == entry.name,
                  let extra = file.bytes(at: nameStart + Int64(values[5]), count: values[6]) else { throw damaged }
            if hasZip64Extra(extra) { throw zip64 }
            entries[index].dataStart = nameStart + Int64(values[5] + values[6])
        }
        let order = entries.indices.sorted { entries[$0].localOffset < entries[$1].localOffset }
        var position: Int64 = 0
        for (rank, index) in order.enumerated() {
            let entry = entries[index]
            let dataEnd = entry.dataStart + entry.compressedSize
            let next = rank + 1 < order.count ? entries[order[rank + 1]].localOffset : directoryStart
            guard entry.localOffset == position, dataEnd <= next else { throw damaged }
            let gap = next - dataEnd
            if entry.flags & 0x08 != 0 {
                guard gap == 12 || gap == 16, let descriptor = file.bytes(at: dataEnd, count: Int(gap)) else { throw damaged }
                let body = gap == 16 ? descriptor.dropFirst(4) : descriptor[...]
                guard gap == 12 || descriptor.littleEndian(at: 0, bytes: 4) == 0x0807_4B50,
                      body.littleEndian(at: 0, bytes: 4) == Int(entry.crc), body.littleEndian(at: 4, bytes: 4).map(Int64.init) == entry.compressedSize,
                      body.littleEndian(at: 8, bytes: 4).map(Int64.init) == entry.uncompressedSize else { throw damaged }
            } else {
                guard gap == 0 else { throw damaged }
            }
            entries[index].extent = entry.localOffset..<next
            position = next
        }
        guard position == directoryStart else { throw damaged }
    }

    /// Stored or deflated, inflated within `limit`, and matching its checksum.
    static func part(_ entry: Entry, _ file: EmbeddedFileReader, limit: Int) throws -> Data {
        guard entry.compressedSize <= Int64(limit), entry.uncompressedSize <= Int64(limit),
              let raw = file.bytes(at: entry.dataStart, count: Int(entry.compressedSize)) else { throw damaged }
        let data: Data?
        switch entry.method {
        case 0: data = raw
        case 8: data = BoundedInflate.raw(raw, limit: Int(entry.uncompressedSize))
        default: data = nil
        }
        guard let data, Int64(data.count) == entry.uncompressedSize, CRC32.checksum(data) == entry.crc else { throw damaged }
        return data
    }

    func coreXML() throws -> Data { try Self.part(entries[coreIndex], file, limit: SafeXML.maxBytes) }

    /// Where the package's relationships say the core properties are, as a part name.
    private static func coreTarget(_ relations: Data) -> Data? {
        guard let events = SafeXML.events(relations) else { return nil }
        let type = SafeXML.Name(uri: "", local: "Type"), target = SafeXML.Name(uri: "", local: "Target")
        let found = events.compactMap { event -> String? in
            guard case .open(let name, _, let attributes, _) = event, name.local == "Relationship",
                  attributes[type]?.hasSuffix("/metadata/core-properties") == true else { return nil }
            return attributes[target]
        }
        guard found.count == 1, let path = found.first else { return nil }
        return Data((path.hasPrefix("/") ? String(path.dropFirst()) : path).utf8)
    }

    // MARK: Writing

    /// Every other entry's header and data copied by range; core.xml replaced, stored; the directory rewritten with the new offsets.
    func rewritten(core xml: Data) throws -> [TagPiece] {
        let core = entries[coreIndex]
        let crc = CRC32.checksum(xml)
        var header = Data.littleEndian(0x0403_4B50, bytes: 4) + core.record.subdata(in: 6..<8)
        header += Data.littleEndian(core.flags & 0x0800, bytes: 2) + Data.littleEndian(0, bytes: 2) + core.record.subdata(in: 12..<16)
        header += Data.littleEndian(Int(crc), bytes: 4) + Data.littleEndian(xml.count, bytes: 4) + Data.littleEndian(xml.count, bytes: 4)
        header += Data.littleEndian(core.name.count, bytes: 2) + Data.littleEndian(0, bytes: 2) + core.name
        let delta = Int64(header.count + xml.count) - Int64(core.extent.count)
        let newDirectoryStart = directory.lowerBound + delta
        guard xml.count < 0xFFFF_FFFF, newDirectoryStart > 0, newDirectoryStart < 0xFFFF_FFFF else { throw EmbeddedFailure.writeFailed }

        var central = Data()
        for (index, entry) in entries.enumerated() {
            var record = Data(entry.record)
            if index == coreIndex {
                record.replaceSubrange(8..<12, with: Data.littleEndian(core.flags & 0x0800, bytes: 2) + Data.littleEndian(0, bytes: 2))
                record.replaceSubrange(16..<28, with: Data.littleEndian(Int(crc), bytes: 4) + Data.littleEndian(xml.count, bytes: 4) + Data.littleEndian(xml.count, bytes: 4))
            } else if entry.localOffset > core.localOffset {
                record.replaceSubrange(42..<46, with: Data.littleEndian(Int(entry.localOffset + delta), bytes: 4))
            }
            central += record
        }
        var end = Data(self.end)
        end.replaceSubrange(16..<20, with: Data.littleEndian(Int(newDirectoryStart), bytes: 4))
        return [.copy(0..<core.extent.lowerBound), .bytes(header + xml), .copy(core.extent.upperBound..<directory.lowerBound), .bytes(central), .bytes(end)]
    }
}

/// ZIP's checksum (the IEEE polynomial, reflected).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
