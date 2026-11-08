import Foundation

/// Undo Move and Redo Move: putting moved items back where they were (FE-129).
///
/// Undo never overwrites anything: an item that is gone, or whose old place is taken again, is left
/// alone and reported. Items on the same volume as their old place go back with one rename each; items
/// on another volume go back through a normal move job (progress, pause, cancel, journal, each original
/// removed only after its own copy), one job per folder they return to.
public enum MoveBack {
    /// One item to put back: it is at `from` now and goes to `to`.
    public struct Item: Equatable, Sendable {
        public let from: URL
        public let to: URL
        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    /// Items that go back to one folder through a move job.
    public struct Transfer: Equatable, Sendable {
        public let folder: URL
        public var items: [Item]
    }

    public struct Plan: Equatable, Sendable {
        /// Same volume: renamed in place, instantly.
        public var renames: [Item] = []
        /// Another volume: copied back by a job, grouped by the folder they return to (in first-seen order).
        public var transfers: [Transfer] = []
        /// Gone, the old place is taken, or the old folder no longer exists.
        public var refused: [Item] = []
    }

    /// Sorts `items` into renames, jobs and refusals. Touches the disk (call off the main thread).
    public static func plan(_ items: [Item], exists: (URL) -> Bool = FileOps.exists,
                            sameVolume: (URL, URL) -> Bool = { FileOps.sameVolume($0, $1) }) -> Plan {
        var plan = Plan()
        for item in items {
            let folder = item.to.deletingLastPathComponent()
            guard exists(item.from), !exists(item.to), exists(folder) else { plan.refused.append(item); continue }
            if sameVolume(item.from, folder) {
                plan.renames.append(item)
            } else if let index = plan.transfers.firstIndex(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
                plan.transfers[index].items.append(item)
            } else {
                plan.transfers.append(Transfer(folder: folder, items: [item]))
            }
        }
        return plan
    }

    /// After a job moved `items` into their folder under their current names, the renames that give them
    /// back their old names ("a (2).txt" was "a.txt" before a Keep Both). `committed` is the job's
    /// (source, where it arrived) list.
    public static func renamesAfterTransfer(_ items: [Item], committed: [(source: URL, destination: URL)]) -> [Item] {
        committed.compactMap { pair in
            guard let item = items.first(where: { $0.from.standardizedFileURL == pair.source.standardizedFileURL }),
                  pair.destination.lastPathComponent != item.to.lastPathComponent else { return nil }
            return Item(from: pair.destination, to: item.to)
        }
    }
}
