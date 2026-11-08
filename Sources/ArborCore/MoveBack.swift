import Foundation

/// Undo/Redo Move (FE-129). Never overwrites: a gone item or a retaken old place is reported and left alone.
/// Same volume: one rename each. Other volume: a normal move job per destination folder.
public enum MoveBack {
    public struct Item: Equatable, Sendable {
        public let from: URL
        public let to: URL
        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public struct Transfer: Equatable, Sendable {
        public let folder: URL
        public var items: [Item]
    }

    public struct Plan: Equatable, Sendable {
        public var renames: [Item] = []
        /// Grouped by destination folder, in first-seen order.
        public var transfers: [Transfer] = []
        /// Gone, old place taken, or old folder missing.
        public var refused: [Item] = []
    }

    /// Touches the disk: call off the main thread.
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

    /// Renames restoring old names after the job (e.g. "a (2).txt" back to "a.txt" after Keep Both).
    public static func renamesAfterTransfer(_ items: [Item], committed: [(source: URL, destination: URL)]) -> [Item] {
        committed.compactMap { pair in
            guard let item = items.first(where: { $0.from.standardizedFileURL == pair.source.standardizedFileURL }),
                  pair.destination.lastPathComponent != item.to.lastPathComponent else { return nil }
            return Item(from: pair.destination, to: item.to)
        }
    }
}
