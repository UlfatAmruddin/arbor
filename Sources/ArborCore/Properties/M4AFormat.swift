import Foundation

/// MPEG-4 audio with an iTunes-style metadata list (FE-152). The list is edited only when the audio stays exactly where it is, so no chunk offset ever needs rewriting.
struct M4AFormat: TagRegionFormat {
    static let identifier = "com.apple.m4a-audio"
    let typeIdentifier = identifier

    private static let audioBrands: Set<String> = ["M4A ", "M4B "]
    private static let brands = audioBrands.union(["mp42", "mp41", "isom", "iso2"])
    private static let maxAtoms = 4096
    private static let maxFieldAtom: Int64 = 1 << 16
    private static let minimumFreeAtom: Int64 = 8
    private static let damaged = L10n.tr("This M4A file is damaged or uses features Arbor doesn't understand, so its properties are read-only.")

    private static let fieldAtoms: [String: EmbeddedField] = ["\u{A9}nam": .title, "\u{A9}ART": .artist, "\u{A9}alb": .album, "\u{A9}day": .year,
                                                              "trkn": .track, "\u{A9}gen": .genre, "gnre": .genre, "\u{A9}cmt": .comment]

    private struct Atom {
        let type: String
        let range: Range<Int64>
        let body: Range<Int64>
        /// A plain 32-bit size, the only kind a rewrite can adjust.
        let isPlain: Bool
    }

    /// The path to the metadata list, and the free space beside it.
    private struct Structure {
        let moov, udta, meta, ilst: Atom
        let moovChildren, udtaChildren, metaChildren, ilstChildren: [Atom]
        let metaSlack: Range<Int64>
        let moovSlack: Range<Int64>
        let isPinned: Bool

        var region: Range<Int64> { moov.range.lowerBound..<moovSlack.upperBound }
    }

    private enum Parsed {
        case other, blocked(String), found(Structure)
    }

    /// Children of `range`; nil if they don't fill it exactly or there are too many.
    private static func atoms(in range: Range<Int64>, _ file: EmbeddedFileReader) -> [Atom]? {
        let walked = walk(range, file)
        return walked.isComplete ? walked.atoms : nil
    }

    /// Children of `range` as far as they can be followed; `isComplete` when they fill it exactly within the budget.
    private static func walk(_ range: Range<Int64>, _ file: EmbeddedFileReader) -> (atoms: [Atom], isComplete: Bool) {
        var found: [Atom] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard found.count < maxAtoms, range.upperBound - offset >= 8, let header = file.bytes(at: offset, count: 8),
                  let short = header.bigEndian(at: 0, bytes: 4) else { return (found, false) }
            let type = String(String.UnicodeScalarView(header[4..<8].map { Unicode.Scalar($0) }))
            var size = Int64(short), headerSize: Int64 = 8
            if short == 1 {
                guard let wide = file.bytes(at: offset + 8, count: 8), let high = wide.bigEndian(at: 0, bytes: 4), let low = wide.bigEndian(at: 4, bytes: 4),
                      high < 0x8000_0000 else { return (found, false) }
                size = Int64(high) << 32 | Int64(low)
                headerSize = 16
            } else if short == 0 {
                // "Runs to the end of the file" only means something at the top level.
                guard range.lowerBound == 0, range.upperBound == file.size else { return (found, false) }
                size = range.upperBound - offset
            }
            guard size >= headerSize, size <= range.upperBound - offset else { return (found, false) }
            let atomRange = offset..<(offset + size)
            found.append(Atom(type: type, range: atomRange, body: (offset + headerSize)..<atomRange.upperBound, isPlain: short > 1))
            offset = atomRange.upperBound
        }
        return (found, true)
    }

    private static func parse(_ file: EmbeddedFileReader) -> Parsed {
        guard let head = file.bytes(at: 0, count: 12), head.subdata(in: 4..<8) == Data("ftyp".utf8) else { return .other }
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        guard brands.contains(brand) else { return .other }
        // Video shares the other brands, so a file whose tracks can't be examined is called damaged only when its brand says audio.
        let unproven: Parsed = audioBrands.contains(brand) ? .blocked(damaged) : .other
        let (top, walkedAll) = walk(0..<file.size, file)
        let moovs = top.indices.filter { top[$0].type == "moov" }
        guard let index = moovs.first else { return walkedAll ? .other : unproven }
        let moov = top[index]
        guard moovs.count == 1, let moovChildren = atoms(in: moov.body, file) else { return unproven }
        guard isAudio(moovChildren, file) else { return .other }
        if top.contains(where: { $0.type == "moof" }) || moovChildren.contains(where: { $0.type == "mvex" }) {
            return .blocked(L10n.tr("This M4A file is fragmented, so its properties are read-only."))
        }
        guard walkedAll else { return .blocked(damaged) }
        let missing = L10n.tr("This M4A file has no metadata list to edit, so its properties are read-only.")
        guard moov.isPlain, let udta = single("udta", moovChildren), udta.isPlain, let udtaChildren = atoms(in: udta.body, file),
              let meta = single("meta", udtaChildren), meta.isPlain, meta.body.count64 >= 4,
              file.bytes(at: meta.body.lowerBound, count: 4) == Data(count: 4),
              let metaChildren = atoms(in: (meta.body.lowerBound + 4)..<meta.body.upperBound, file),
              let handler = single("hdlr", metaChildren), file.bytes(at: handler.body.lowerBound + 8, count: 4) == Data("mdir".utf8),
              let ilstIndex = metaChildren.firstIndex(where: { $0.type == "ilst" }), metaChildren.filter({ $0.type == "ilst" }).count == 1,
              metaChildren[ilstIndex].isPlain, let ilstChildren = atoms(in: metaChildren[ilstIndex].body, file) else { return .blocked(missing) }
        let ilst = metaChildren[ilstIndex]
        let metaSlack = slack(after: ilstIndex, in: metaChildren, from: ilst.range.upperBound)
        let moovSlack = slack(after: index, in: top, from: moov.range.upperBound)
        let isPinned = moovSlack.upperBound < file.size
        return .found(Structure(moov: moov, udta: udta, meta: meta, ilst: ilst, moovChildren: moovChildren, udtaChildren: udtaChildren,
                                metaChildren: metaChildren, ilstChildren: ilstChildren, metaSlack: metaSlack, moovSlack: moovSlack, isPinned: isPinned))
    }

    private static func single(_ type: String, _ atoms: [Atom]) -> Atom? {
        let matches = atoms.filter { $0.type == type }
        return matches.count == 1 ? matches.first : nil
    }

    /// Free atoms directly after `index`; the empty range at `start` when there are none.
    private static func slack(after index: Int, in atoms: [Atom], from start: Int64) -> Range<Int64> {
        var end = start, next = index + 1
        while next < atoms.count, atoms[next].type == "free" || atoms[next].type == "skip" {
            end = atoms[next].range.upperBound
            next += 1
        }
        return start..<end
    }

    /// At least one sound track and no video; a chapter text track is fine.
    private static func isAudio(_ moovChildren: [Atom], _ file: EmbeddedFileReader) -> Bool {
        var hasSound = false
        for track in moovChildren where track.type == "trak" {
            guard let children = atoms(in: track.body, file), let media = single("mdia", children),
                  let mediaChildren = atoms(in: media.body, file), let handler = single("hdlr", mediaChildren),
                  let kind = file.bytes(at: handler.body.lowerBound + 8, count: 4) else { return false }
            if kind == Data("vide".utf8) { return false }
            if kind == Data("soun".utf8) { hasSound = true }
        }
        return hasSound
    }

    func layout(of file: EmbeddedFileReader) -> TagLayout? {
        switch Self.parse(file) {
        case .other: return nil
        case .blocked(let reason): return TagLayout(blocked: reason)
        case .found(let found): return Self.layout(found, file)
        }
    }

    private static func layout(_ s: Structure, _ file: EmbeddedFileReader) -> TagLayout {
        var layout = TagLayout(region: s.region)
        layout.suffixIsPinned = s.isPinned
        if s.isPinned, s.metaSlack.isEmpty, s.moovSlack.isEmpty {
            layout.block(L10n.tr("This M4A file has no free space beside its metadata, and changing its size would move the audio, so its properties are read-only."))
        }
        func kept(_ atoms: [Atom], skipping target: Atom, _ inner: () -> Void) {
            for atom in atoms {
                if atom.range == target.range { inner() } else { layout.items.append(TagItem(range: atom.range, field: nil)) }
            }
        }
        kept(s.moovChildren, skipping: s.udta) {
            kept(s.udtaChildren, skipping: s.meta) {
                layout.items.append(TagItem(range: s.meta.body.lowerBound..<(s.meta.body.lowerBound + 4), field: nil))
                for atom in s.metaChildren where !s.metaSlack.contains(atom.range.lowerBound) {
                    guard atom.range == s.ilst.range else {
                        layout.items.append(TagItem(range: atom.range, field: nil))
                        continue
                    }
                    for item in s.ilstChildren {
                        let field = fieldAtoms[item.type]
                        if let field { layout.record(field, value(of: item, file)) }
                        layout.items.append(TagItem(range: item.range, field: field))
                    }
                }
            }
        }
        return layout
    }

    /// One `data` child with a type this field understands, else shown but not offered.
    private static func value(of item: Atom, _ file: EmbeddedFileReader) -> EmbeddedReader.Raw {
        let unreadable = EmbeddedReader.Raw(text: "", canEdit: false)
        guard item.range.count64 <= maxFieldAtom, let children = atoms(in: item.body, file), let first = children.first, first.type == "data",
              first.body.count64 >= 8, first.body.count64 <= maxFieldAtom, let body = file.bytes(first.body),
              let kind = body.bigEndian(at: 0, bytes: 4) else { return unreadable }
        let isSingle = children.count == 1 && body.subdata(in: 4..<8) == Data(count: 4)
        let payload = body.subdata(in: 8..<body.count)
        switch item.type {
        case "trkn":
            guard kind == 0, payload.count >= 6, let number = payload.bigEndian(at: 2, bytes: 2), let total = payload.bigEndian(at: 4, bytes: 2) else { return unreadable }
            let spare = payload.prefix(2) + payload.dropFirst(6)
            return EmbeddedReader.Raw(text: total == 0 ? String(number) : "\(number)/\(total)", canEdit: isSingle && number > 0 && spare.allSatisfy { $0 == 0 })
        case "gnre":
            guard kind == 0, payload.count == 2, let code = payload.bigEndian(at: 0, bytes: 2), let name = ID3Genre.name(code - 1) else { return unreadable }
            return EmbeddedReader.Raw(text: name, canEdit: isSingle)
        default:
            guard kind == 1, let text = String(data: payload, encoding: .utf8) else { return unreadable }
            return EmbeddedReader.Raw(text: text, canEdit: isSingle)
        }
    }

    // MARK: Writing

    func regionPieces(for edits: [EmbeddedField: String], in layout: TagLayout, of file: EmbeddedFileReader) throws -> [TagPiece] {
        guard case .found(let s) = Self.parse(file) else { throw EmbeddedFailure.changedSinceRead }
        var list: [TagPiece] = [], listSize: Int64 = 0
        var placed = Set<EmbeddedField>()
        func add(_ atom: Data) {
            list.append(.bytes(atom))
            listSize += Int64(atom.count)
        }
        for item in s.ilstChildren {
            guard let field = Self.fieldAtoms[item.type], let value = edits[field] else {
                list.append(.copy(item.range))
                listSize += item.range.count64
                continue
            }
            placed.insert(field)
            if !value.isEmpty { add(try Self.atom(field, value)) }
        }
        for field in EmbeddedField.allCases where edits[field]?.isEmpty == false && !placed.contains(field) {
            add(try Self.atom(field, edits[field] ?? ""))
        }

        let delta = listSize - s.ilst.body.count64
        var metaSlack = s.metaSlack.count64, moovSlack = s.moovSlack.count64
        if s.isPinned, delta != 0 {
            if Self.fits(metaSlack - delta) {
                metaSlack -= delta
            } else if Self.fits(moovSlack - delta) {
                moovSlack -= delta
            } else {
                throw EmbeddedFailure.noRoomBesideMetadata
            }
        }
        let keepSlackBytes = !s.isPinned || delta == 0
        let growth = delta + (metaSlack - s.metaSlack.count64)
        func header(_ atom: Atom, _ newSize: Int64) throws -> Data {
            guard newSize < 1 << 32 else { throw EmbeddedFailure.writeFailed }
            return Data.bigEndian(Int(newSize), bytes: 4) + Data(atom.type.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        }
        func slack(_ old: Range<Int64>, _ size: Int64, unchanged: Bool) throws -> [TagPiece] {
            if size == 0 { return [] }
            if unchanged { return [.copy(old)] }
            guard size < 1 << 32 else { throw EmbeddedFailure.writeFailed }
            return [.bytes(Data.bigEndian(Int(size), bytes: 4) + Data("free".utf8)), .zeros(size - Self.minimumFreeAtom)]
        }

        var pieces: [TagPiece] = [.bytes(try header(s.moov, s.moov.range.count64 + growth)), .copy(s.moov.body.lowerBound..<s.udta.range.lowerBound)]
        pieces.append(.bytes(try header(s.udta, s.udta.range.count64 + growth)))
        pieces.append(.copy(s.udta.body.lowerBound..<s.meta.range.lowerBound))
        pieces.append(.bytes(try header(s.meta, s.meta.range.count64 + growth)))
        pieces.append(.copy(s.meta.body.lowerBound..<s.ilst.range.lowerBound))
        pieces.append(.bytes(try header(s.ilst, s.ilst.range.count64 + delta)))
        pieces += list
        pieces += try slack(s.metaSlack, metaSlack, unchanged: keepSlackBytes || metaSlack == s.metaSlack.count64)
        pieces.append(.copy(s.metaSlack.upperBound..<s.meta.range.upperBound))
        pieces.append(.copy(s.meta.range.upperBound..<s.udta.range.upperBound))
        pieces.append(.copy(s.udta.range.upperBound..<s.moov.range.upperBound))
        pieces += try slack(s.moovSlack, moovSlack, unchanged: keepSlackBytes || moovSlack == s.moovSlack.count64)
        return pieces
    }

    /// A free atom needs its own header; consuming one entirely would leave no room for the next edit.
    private static func fits(_ size: Int64) -> Bool { size >= minimumFreeAtom }

    private static func atom(_ field: EmbeddedField, _ value: String) throws -> Data {
        let name: String, kind: Int, payload: Data
        switch field {
        case .title: (name, kind, payload) = ("\u{A9}nam", 1, Data(value.utf8))
        case .artist: (name, kind, payload) = ("\u{A9}ART", 1, Data(value.utf8))
        case .album: (name, kind, payload) = ("\u{A9}alb", 1, Data(value.utf8))
        case .year: (name, kind, payload) = ("\u{A9}day", 1, Data(value.utf8))
        case .genre: (name, kind, payload) = ("\u{A9}gen", 1, Data(value.utf8))
        case .comment: (name, kind, payload) = ("\u{A9}cmt", 1, Data(value.utf8))
        case .track:
            guard let track = EmbeddedTrack(value) else { throw EmbeddedFailure.writeFailed }
            (name, kind, payload) = ("trkn", 0, Data(count: 2) + Data.bigEndian(Int(track.number), bytes: 2) + Data.bigEndian(Int(track.total), bytes: 2) + Data(count: 2))
        default: throw EmbeddedFailure.notEditable
        }
        let data = Data.bigEndian(payload.count + 16, bytes: 4) + Data("data".utf8) + Data.bigEndian(kind, bytes: 4) + Data(count: 4) + payload
        return Data.bigEndian(data.count + 8, bytes: 4) + Data(name.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) + data
    }
}

private extension Range where Bound == Int64 {
    var count64: Int64 { upperBound - lowerBound }
}
