import Foundation
import Testing
@testable import ArborCore

@Suite("Background sorting of large listings (FE-228)")
struct BackgroundSortTests {
    private func sample(_ count: Int) -> [FileItem] {
        let kinds = ["PDF document", "Plain Text", "Folder", "JPEG image", "Markdown"]
        return (0..<count).map { i in
            let name = "\(["Report", "report", "résumé", "file 10", "file 9", "Zeta"][i % 6]) \(i % 101).txt"
            return FileItem(url: URL(fileURLWithPath: "/fixture/\(i)/\(name)"), name: name, isFolder: i % 13 == 0,
                            size: Int64((i * 7919) % 5000), modified: Date(timeIntervalSince1970: Double((i * 104_729) % 100_000)),
                            typeDescription: kinds[i % kinds.count])
        }
    }

    /// The rows sorted on a background thread are exactly the rows the main thread would produce.
    @Test(.serialized, arguments: [(SortKey.type, true), (.name, false), (.type, false), (.size, false), (.dateModified, true)])
    func backgroundOrderIsTheSameOrder(_ key: SortKey, _ ascending: Bool) {
        let items = sample(BackgroundSort.threshold + 5_000).shuffled()
        let order = FileSortOrder(key: key, ascending: ascending)
        let reference = items.sorted { FileSorter.precedes($0, $1, order) }
        var background: [FileItem] = []
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            background = FileSorter.sorted(items, by: order)
            done.signal()
        }
        done.wait()
        #expect(background == reference)
        #expect(FileSorter.sorted(items, by: order) == background)   // and again on this thread: deterministic
    }

    @Test func onlyLargeListingsOnListingColumnsGoToTheBackground() {
        let byType = FileSortOrder(key: .type)
        #expect(BackgroundSort.shouldSortInBackground(100_000, byType))
        #expect(!BackgroundSort.shouldSortInBackground(BackgroundSort.threshold - 1, byType))
        var byColumn = FileSortOrder(key: .name)
        byColumn.column = ColumnID("dateTaken")   // read from the main thread's metadata cache
        #expect(!BackgroundSort.isThreadSafe(byColumn))
        var tieBreak = FileSortOrder(key: .size)
        tieBreak.thenBy = [SortCriterion(ColumnID("name"), ascending: true)]
        #expect(BackgroundSort.isThreadSafe(tieBreak))
    }
}
