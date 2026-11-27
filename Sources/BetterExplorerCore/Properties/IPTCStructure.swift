import Foundation

/// A bounded walk of a JPEG's Photoshop segments to their IPTC records, of which ImageIO keeps only those it has keys for (FE-152).
enum IPTCStructure {
    struct DataSet: Hashable {
        let record, number: Int
    }

    struct Entry: Hashable {
        let set: DataSet
        let value: Data
    }

    static let objectName = DataSet(record: 2, number: 5), caption = DataSet(record: 2, number: 120)
    static let dateCreated = DataSet(record: 2, number: 55), timeCreated = DataSet(record: 2, number: 60)

    /// What ImageIO's copy kept when each dataset was rewritten alone on generated files; the rest vanish.
    static let carried = Set([4, 5, 7, 10, 12, 15, 20, 22, 25, 26, 27, 40, 42, 45, 47, 50, 55, 60, 62, 63, 65, 70, 80, 85, 90, 92, 95,
                              100, 101, 103, 105, 110, 115, 116, 120, 122, 130, 131, 135].map { DataSet(record: 2, number: $0) })
    /// Character set and record version: ImageIO writes its own whatever was there, and they describe only the record itself.
    private static let regenerated: Set<DataSet> = [characterSet, DataSet(record: 2, number: 0)]
    private static let characterSet = DataSet(record: 1, number: 90)
    private static let declaresUTF8 = Data([0x1B, 0x25, 0x47])

    private static let signature = Data("Photoshop 3.0\0".utf8), resourceType = Data("8BIM".utf8)
    private static let iptcResource = 0x0404
    private static let digestHeader = resourceType + [0x04, 0x25, 0, 0, 0, 0, 0, 0x10], digestSize = 16
    /// ImageIO ignores a shorter resource and leaves it beside the one it writes.
    private static let shortestRead = 9
    private static let maxEntries = 4096

    /// nil when `segments` can't be followed, or IPTC sits outside the first one, the only one ImageIO rewrites; the caller treats that as doubt.
    static func read(_ segments: [Data]) -> Set<Entry>? {
        var first = Set<Entry>()
        for (index, segment) in segments.enumerated() {
            guard let found = entries(in: Data(segment)), index == 0 || found.isEmpty else { return nil }
            if index == 0 { first = found }
        }
        return first
    }

    /// True when a rewrite can only hand every entry back unchanged.
    static func rewriteKeeps(_ entries: Set<Entry>) -> Bool {
        let utf8 = entries.filter { $0.set == characterSet }.map(\.value) == [declaresUTF8]
        return entries.allSatisfy { regenerated.contains($0.set) || (carried.contains($0.set) && valueIsKept($0.value, utf8: utf8)) }
    }

    /// Empty values and NULs are dropped; bytes outside ASCII are transcoded unless declared and valid UTF-8.
    private static func valueIsKept(_ value: Data, utf8: Bool) -> Bool {
        guard !value.isEmpty, !value.contains(0) else { return false }
        return value.allSatisfy { $0 < 0x80 } || (utf8 && String(data: value, encoding: .utf8) != nil)
    }

    /// Every entry of `before` is byte-identical in `after`, bar those the edit may change.
    static func survives(_ before: Set<Entry>, in after: Set<Entry>, changeable: Set<DataSet>) -> Bool {
        before.allSatisfy { regenerated.contains($0.set) || changeable.contains($0.set) || after.contains($0) }
    }

    /// `segment` is zero-based. A second non-empty IPTC resource is doubt too: ImageIO would read only the last.
    private static func entries(in segment: Data) -> Set<Entry>? {
        guard segment.starts(with: signature) else { return nil }
        var found: Set<Entry>?
        var index = signature.count
        // ImageIO's own writer can push a resource's padding to the very end of the segment.
        while index < segment.count, !segment[index...].allSatisfy({ $0 == 0 }) {
            // Type, id, the shortest name and the size.
            guard segment.count - index >= 12, segment.subdata(in: index..<(index + 4)) == resourceType else {
                return found != nil && isWornDigest(segment[index...]) ? found : nil
            }
            let id = Int(segment[index + 4]) << 8 | Int(segment[index + 5])
            let sizeOffset = index + 6 + ((Int(segment[index + 6]) + 2) & ~1)
            guard sizeOffset <= segment.count - 4 else { return nil }
            let size = (0..<4).reduce(0) { $0 << 8 | Int(segment[sizeOffset + $1]) }
            let body = sizeOffset + 4
            guard size <= segment.count - body else { return nil }
            if id == iptcResource, size > 0 {
                guard found == nil, size >= shortestRead, let records = records(segment.subdata(in: body..<(body + size))) else { return nil }
                found = records
            }
            index = body + size
            if size & 1 == 1 {
                // ImageIO misreads the last byte of an odd resource that ends the segment unpadded.
                guard index < segment.count else { return nil }
                if segment[index] == 0 { index += 1 }
            }
        }
        return found ?? []
    }

    /// ImageIO's reader skips a padding byte its writer left out, so each later save eats into the digest it stores after an odd IPTC resource.
    private static func isWornDigest(_ tail: Data) -> Bool {
        var worn = Data(tail)
        while worn.last == 0 { worn.removeLast() }
        guard worn.count <= digestHeader.count + digestSize else { return false }
        return digestHeader.suffix(max(worn.count - digestSize, 0)) == worn.prefix(max(worn.count - digestSize, 0))
    }

    /// `block` is zero-based. Writers may pad the end with zeros, but anything else that isn't a dataset is doubt.
    private static func records(_ block: Data) -> Set<Entry>? {
        var entries = Set<Entry>()
        var index = 0
        while index < block.count {
            guard block[index] == 0x1C else { return block[index...].allSatisfy { $0 == 0 } ? entries : nil }
            guard block.count - index >= 5, entries.count < maxEntries else { return nil }
            let length = Int(block[index + 3]) << 8 | Int(block[index + 4])
            // The top bit announces an extended dataset, whose length is stored elsewhere.
            guard length & 0x8000 == 0, length <= block.count - index - 5 else { return nil }
            let set = DataSet(record: Int(block[index + 1]), number: Int(block[index + 2]))
            entries.insert(Entry(set: set, value: block.subdata(in: (index + 5)..<(index + 5 + length))))
            index += 5 + length
        }
        return entries
    }
}
