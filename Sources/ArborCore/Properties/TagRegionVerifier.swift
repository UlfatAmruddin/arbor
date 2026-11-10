import Foundation
import Darwin

/// Proves a rewritten file from the two files alone, knowing nothing of how it was written (FE-152). Any doubt refuses the change.
enum TagRegionVerifier {
    static func verify(_ format: any TagRegionFormat, edits: [EmbeddedField: String], original: EmbeddedFileReader, written url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EmbeddedFailure.soundUnverified }
        defer { close(descriptor) }
        guard let written = EmbeddedFileReader(descriptor: descriptor),
              let before = format.layout(of: original), let after = format.layout(of: written),
              before.blocked == nil, after.blocked == nil,
              outsideMatches(before, original, after, written),
              keptItemsMatch(before, original, after, written, edited: Set(edits.keys)),
              fieldsMatch(before.fields, after.fields, edits: edits) else { throw EmbeddedFailure.soundUnverified }
    }

    /// Before and after the region, every byte; and what can't move hasn't.
    private static func outsideMatches(_ before: TagLayout, _ original: EmbeddedFileReader, _ after: TagLayout, _ written: EmbeddedFileReader) -> Bool {
        let tail = original.size - before.region.upperBound
        guard tail >= 0, before.region.lowerBound == after.region.lowerBound, written.size - after.region.upperBound == tail,
              before.suffixIsPinned == after.suffixIsPinned,
              !before.suffixIsPinned || before.region.count == after.region.count else { return false }
        return original.sameBytes(0..<before.region.lowerBound, as: written, 0..<after.region.lowerBound)
            && original.sameBytes(before.region.upperBound..<original.size, as: written, after.region.upperBound..<written.size)
    }

    /// Inside the region, every item the edit didn't name, in the same order.
    private static func keptItemsMatch(_ before: TagLayout, _ original: EmbeddedFileReader, _ after: TagLayout, _ written: EmbeddedFileReader,
                                       edited: Set<EmbeddedField>) -> Bool {
        let old = before.kept(excluding: edited), new = after.kept(excluding: edited)
        return old.count == new.count && zip(old, new).allSatisfy { original.sameBytes($0, as: written, $1) }
    }

    /// The re-parse shows exactly the requested values and every other field as it was, by bytes: a lookalike isn't the value asked for.
    static func fieldsMatch(_ before: [EmbeddedField: EmbeddedReader.Raw], _ after: [EmbeddedField: EmbeddedReader.Raw], edits: [EmbeddedField: String]) -> Bool {
        EmbeddedField.allCases.allSatisfy { field in
            let found = after[field]
            guard let wanted = edits[field] else { return found == before[field] }
            if wanted.isEmpty { return found == nil }
            return found?.canEdit == true && found.map { Array($0.text.utf8) == Array(wanted.utf8) } == true
        }
    }
}
