import Foundation

/// Re-sorting a large listing off the main thread (FE-228). Sorting 100,000 rows by type, or in reverse,
/// took ~230 ms on the main thread: the window froze after a click on a column header. The order is exactly
/// `FileSorter.sorted` (same function, another thread); the caller keeps showing the old order until the
/// result arrives and drops results that a newer request made stale.
public enum BackgroundSort {
    /// Listings smaller than this sort on the main thread in a few milliseconds.
    public static let threshold = 20_000

    /// True when the order only reads values carried by the items. Orders on extra Details columns read the
    /// app's metadata cache, which belongs to the main thread.
    public static func isThreadSafe(_ order: FileSortOrder) -> Bool {
        let columns = [order.column ?? ColumnID(order.key.rawValue)] + order.thenBy.map(\.column)
        return columns.allSatisfy { SortKey(rawValue: $0.rawValue) != nil }   // the same rule as LargeSort
    }

    /// Whether `items` should be sorted in the background for `order`.
    public static func shouldSortInBackground(_ count: Int, _ order: FileSortOrder) -> Bool {
        count >= threshold && isThreadSafe(order)
    }

    private static let queue = DispatchQueue(label: "Arbor sorting", qos: .userInitiated)

    /// Sorts on a background queue and calls `completion` on the main queue unless `isCurrent` (checked on the
    /// main queue) says the request was superseded.
    public static func sort(_ items: [FileItem], by order: FileSortOrder, isCurrent: @escaping () -> Bool,
                            completion: @escaping ([FileItem]) -> Void) {
        queue.async {
            let sorted = FileSorter.sorted(items, by: order)
            DispatchQueue.main.async {
                guard isCurrent() else { return }
                completion(sorted)
            }
        }
    }
}
