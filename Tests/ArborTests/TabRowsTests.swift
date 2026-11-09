import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

@Suite("Tab rows and filter options (FE-039, FE-228)", .serialized)
@MainActor
struct TabRowsTests {
    private func makeTab() -> TabState {
        _ = FeatureRegistrationTests.problem   // headless preferences and registered features
        return TabState(location: .folder(URL(fileURLWithPath: "/tmp/fixture")), viewMode: .details, sortOrder: FileSortOrder())
    }

    private func files(_ count: Int) -> [FileItem] {
        (0..<count).map { FileItem(url: URL(fileURLWithPath: "/tmp/fixture/\($0)"), name: "\($0)", isFolder: false,
                                   size: 1, modified: nil, typeDescription: "File") }
    }

    @Test func aFilterChangeSupersedesARunningBackgroundSort() async throws {
        let tab = makeTab()
        tab.items = files(BackgroundSort.threshold)
        var landed = false
        #expect(tab.sortInBackground { landed = true })
        #expect(tab.isSorting)
        tab.invalidateVisibleItems()
        #expect(!tab.isSorting)
        // The queue is serial and FIFO, so this finishes after the superseded sort has reported.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            BackgroundSort.sort([], by: tab.sortOrder, isCurrent: { true }, completion: { _ in done.resume() })
        }
        #expect(!landed)
    }

    @Test func readingExistingOptionsNeverCreatesThem() {
        let tab = makeTab()
        #expect(ViewOptions.existingOptions(for: tab) == nil)
        #expect(tab.items == nil)
        let created = ViewOptions.options(for: tab)
        #expect(ViewOptions.existingOptions(for: tab) === created)
    }
}
