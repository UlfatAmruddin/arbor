import Foundation

/// Re-sorts large listings off the main thread (FE-228; 100,000 rows took ~230 ms). Same order as
/// `FileSorter.sorted`; the caller shows the old order meanwhile and drops stale results.
public enum BackgroundSort {
    /// Smaller listings sort on the main thread in a few milliseconds.
    public static let threshold = 20_000

    /// Extra Details columns read the metadata cache, which belongs to the main thread.
    public static func isThreadSafe(_ order: FileSortOrder) -> Bool {
        let columns = [order.column ?? ColumnID(order.key.rawValue)] + order.thenBy.map(\.column)
        return columns.allSatisfy { SortKey(rawValue: $0.rawValue) != nil }   // the same rule as LargeSort
    }

    public static func shouldSortInBackground(_ count: Int, _ order: FileSortOrder) -> Bool {
        count >= threshold && isThreadSafe(order)
    }

    private static let queue = DispatchQueue(label: "Arbor sorting", qos: .userInitiated)

    /// `completion` runs on the main queue unless `isCurrent` (checked there) says the request was superseded.
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
