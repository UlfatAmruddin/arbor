import Foundation
import CoreGraphics
import Testing
@testable import ArborCore

@Suite("Icon view layout (FE-029, FE-030, FE-031, FE-060)")
struct ItemFlowLayoutTests {
    /// 100×100 cells, no gaps, 10 pt insets: a 420 pt wide viewport fits 4 columns.
    private func grid(count: Int, width: CGFloat = 420, height: CGFloat = 300) -> ItemFlowLayout {
        var layout = ItemFlowLayout(flow: .rows, itemSize: CGSize(width: 100, height: 100), insets: (10, 10, 10, 10))
        layout.update(count: count, viewport: CGSize(width: width, height: height))
        return layout
    }

    private func list(count: Int, height: CGFloat = 100) -> ItemFlowLayout {
        var layout = ItemFlowLayout(flow: .columns, itemSize: CGSize(width: 200, height: 20), spacing: CGSize(width: 8, height: 0))
        layout.update(count: count, viewport: CGSize(width: 500, height: height))
        return layout
    }

    @Test func rowFlowFillsRowsLeftToRight() {
        let layout = grid(count: 10)
        #expect(layout.columns == 4)
        #expect(layout.rows == 3)
        #expect(layout.frame(at: 0) == CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(layout.frame(at: 5) == CGRect(x: 110, y: 110, width: 100, height: 100))
        #expect(layout.contentSize == CGSize(width: 420, height: 320))
    }

    @Test func columnFlowFillsColumnsTopToBottom() {
        let layout = list(count: 12)
        #expect(layout.rows == 5)
        #expect(layout.columns == 3)
        #expect(layout.frame(at: 0).origin == CGPoint(x: 0, y: 0))
        #expect(layout.frame(at: 4).origin == CGPoint(x: 0, y: 80))
        #expect(layout.frame(at: 5).origin == CGPoint(x: 208, y: 0))
        #expect(layout.contentSize.width == CGFloat(616))
        #expect(layout.contentSize.height == 100)
    }

    @Test func narrowViewportStillHasOneColumn() {
        let layout = grid(count: 3, width: 50)
        #expect(layout.columns == 1)
        #expect(layout.rows == 3)
    }

    @Test func stretchedContentRowsUseTheViewportWidth() {
        var layout = ItemFlowLayout(flow: .rows, itemSize: CGSize(width: 0, height: 60), insets: (0, 6, 0, 6),
                                    stretchesWidth: true, minimumStretchWidth: 100)
        layout.update(count: 3, viewport: CGSize(width: 812, height: 400))
        #expect(layout.columns == 1)
        #expect(layout.frame(at: 2) == CGRect(x: 6, y: 120, width: 800, height: 60))
    }

    @Test func hitTestingSkipsGapsAndEmptyCells() {
        var layout = ItemFlowLayout(flow: .rows, itemSize: CGSize(width: 100, height: 100), spacing: CGSize(width: 10, height: 10))
        layout.update(count: 5, viewport: CGSize(width: 330, height: 300))
        #expect(layout.columns == 3)
        #expect(layout.index(at: CGPoint(x: 50, y: 50)) == 0)
        #expect(layout.index(at: CGPoint(x: 105, y: 50)) == nil)      // horizontal gap
        #expect(layout.index(at: CGPoint(x: 120, y: 150)) == 4)
        #expect(layout.index(at: CGPoint(x: 250, y: 150)) == nil)     // past the last item
    }

    @Test func rectQueryReturnsIntersectingItemsInOrder() {
        let layout = grid(count: 10)
        #expect(layout.indexes(in: CGRect(x: 60, y: 60, width: 100, height: 100)) == [0, 1, 4, 5])
        #expect(layout.indexes(in: CGRect(x: 0, y: 215, width: 420, height: 50)) == [8, 9])
        #expect(layout.indexes(in: CGRect(x: 0, y: 900, width: 420, height: 50)).isEmpty)
    }

    @Test func visibleRangeIsBoundedForHugeFolders() {
        var layout = ItemFlowLayout(flow: .columns, itemSize: CGSize(width: 220, height: 26))
        layout.update(count: 100_000, viewport: CGSize(width: 900, height: 520))
        let visible = layout.indexes(in: CGRect(x: 44_000, y: 0, width: 900, height: 520))
        #expect(visible.count <= 6 * 20)
        #expect(!visible.isEmpty)
    }

    @Test func arrowsMoveSpatiallyInGrid() {
        let layout = grid(count: 10)   // 4 per row, last row has 2
        #expect(layout.target(from: 5, move: .left) == 4)
        #expect(layout.target(from: 4, move: .left) == 3)        // wraps to the previous row's end
        #expect(layout.target(from: 3, move: .right) == 4)
        #expect(layout.target(from: 1, move: .down) == 5)
        #expect(layout.target(from: 5, move: .up) == 1)
        #expect(layout.target(from: 1, move: .up) == 1)          // top row stays
        #expect(layout.target(from: 7, move: .down) == 9)        // into the partial last row
        #expect(layout.target(from: 9, move: .down) == 9)
        #expect(layout.target(from: 9, move: .right) == 9)
        #expect(layout.target(from: 0, move: .left) == 0)
    }

    @Test func arrowsMoveByColumnInList() {
        let layout = list(count: 12)   // 5 per column
        #expect(layout.target(from: 1, move: .down) == 2)
        #expect(layout.target(from: 4, move: .down) == 5)        // next column's top
        #expect(layout.target(from: 1, move: .right) == 6)
        #expect(layout.target(from: 8, move: .right) == 11)      // partial last column
        #expect(layout.target(from: 6, move: .left) == 1)
        #expect(layout.target(from: 1, move: .left) == 1)
    }

    @Test func homeEndAndPages() {
        let layout = grid(count: 30)   // 4 per row, 8 rows
        let visible = CGSize(width: 420, height: 300)   // 3 rows per page
        #expect(layout.target(from: 13, move: .home) == 0)
        #expect(layout.target(from: 13, move: .end) == 29)
        #expect(layout.target(from: 1, move: .pageDown, visible: visible) == 13)
        #expect(layout.target(from: 25, move: .pageDown, visible: visible) == 29)
        #expect(layout.target(from: 13, move: .pageUp, visible: visible) == 1)
        #expect(layout.target(from: 5, move: .pageUp, visible: visible) == 1)
        #expect(layout.target(from: nil, move: .down) == 0)
        #expect(layout.target(from: nil, move: .end) == 29)
    }

    @Test func scrollAnchorsRoundTrip() {
        let layout = grid(count: 100)
        let origin = layout.scrollOrigin(toShowAtStart: 41)
        #expect(origin == CGPoint(x: 0, y: 1000))
        let visible = CGRect(origin: origin, size: CGSize(width: 420, height: 300))
        #expect(layout.firstVisibleIndex(in: visible) == 40)
        let columns = list(count: 50)
        let x = columns.scrollOrigin(toShowAtStart: 23)
        #expect(x.x == CGFloat(832))
        #expect(columns.firstVisibleIndex(in: CGRect(origin: x, size: CGSize(width: 500, height: 100))) == 20)
    }
}

@Suite("Icon view selection (FE-058, FE-060)")
struct ItemSelectionTests {
    @Test func clickShiftAndCommandClick() {
        var s = ItemSelection()
        s.click(3, .none)
        #expect(s.selected == [3] && s.anchor == 3 && s.focus == 3)
        s.click(6, .extend)
        #expect(s.selected == IndexSet(3...6) && s.anchor == 3 && s.focus == 6)
        s.click(1, .extend)
        #expect(s.selected == IndexSet(1...3))
        s.click(9, .toggle)
        #expect(s.selected == IndexSet([1, 2, 3, 9]) && s.anchor == 9)
        s.click(11, .extendAdding)
        #expect(s.selected == IndexSet([1, 2, 3, 9, 10, 11]))
        s.click(2, .toggle)
        #expect(!s.selected.contains(2))
    }

    @Test func keyboardExtendAndFocusOnly() {
        var s = ItemSelection()
        s.move(to: 4, extend: false, focusOnly: false)
        s.move(to: 7, extend: true, focusOnly: false)
        #expect(s.selected == IndexSet(4...7) && s.anchor == 4)
        s.move(to: 2, extend: true, focusOnly: false)
        #expect(s.selected == IndexSet(2...4))
        s.move(to: 9, extend: false, focusOnly: true)
        #expect(s.selected == IndexSet(2...4) && s.focus == 9)
        s.toggleFocused()
        #expect(s.selected == IndexSet([2, 3, 4, 9]))
    }

    @Test func backgroundClickAndMarquee() {
        var s = ItemSelection(selected: [1, 2], focus: 2, anchor: 1)
        s.clickBackground(keepSelection: true)
        #expect(s.selected == [1, 2])
        s.clickBackground(keepSelection: false)
        #expect(s.selected.isEmpty && s.focus == 2)
        let base: IndexSet = [1, 2, 3]
        let hits: IndexSet = [3, 4]
        #expect(ItemSelection.marquee(base: base, hits: hits, toggle: false, add: false) == [3, 4])
        #expect(ItemSelection.marquee(base: base, hits: hits, toggle: false, add: true) == [1, 2, 3, 4])
        #expect(ItemSelection.marquee(base: base, hits: hits, toggle: true, add: false) == [1, 2, 4])
    }

    @Test func clampAfterShrink() {
        var s = ItemSelection(selected: [1, 8, 9], focus: 9, anchor: 8)
        s.clamp(to: 5)
        #expect(s.selected == [1] && s.focus == 4 && s.anchor == nil)
    }
}

@Suite("Type-to-select")
struct TypeSelectTests {
    let names = ["apple", "Avocado", "banana", "Blueberry", "cherry", "Ångström.txt"]

    @Test func prefixExtendsAndTimesOut() {
        var t = TypeSelect()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(t.input("b", at: t0, names: names, current: nil) == 2)
        #expect(t.input("l", at: t0.addingTimeInterval(0.3), names: names, current: 2) == 3)
        #expect(t.isActive(at: t0.addingTimeInterval(0.5)))
        #expect(!t.isActive(at: t0.addingTimeInterval(2)))
        #expect(t.input("c", at: t0.addingTimeInterval(2), names: names, current: 3) == 4)
    }

    @Test func repeatedLetterCycles() {
        var t = TypeSelect()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(t.input("a", at: t0, names: names, current: nil) == 0)
        #expect(t.input("a", at: t0.addingTimeInterval(0.2), names: names, current: 0) == 1)
        #expect(t.input("a", at: t0.addingTimeInterval(0.4), names: names, current: 1) == 5)   // Å matches a
        #expect(t.input("a", at: t0.addingTimeInterval(0.6), names: names, current: 5) == 0)
    }

    @Test func noMatchReturnsNil() {
        var t = TypeSelect()
        #expect(t.input("z", at: Date(), names: names, current: 1) == nil)
    }
}

@Suite("Thumbnail cache (FE-149, FE-242, FE-243)")
struct ThumbnailCacheTests {
    @Test func evictsLeastRecentlyUsedPastBudget() {
        let cache = ByteBudgetCache<String, Int>(byteLimit: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "b", cost: 40)
        _ = cache.value(for: "a")             // a is now newest
        cache.insert(3, for: "c", cost: 40)   // evicts b
        #expect(cache.peek("b") == nil)
        #expect(cache.keysByAge == ["a", "c"])
        #expect(cache.totalCost == 80)
    }

    @Test func oversizedEntriesAreNotKeptAndTrimWorks() {
        let cache = ByteBudgetCache<String, Int>(byteLimit: 100)
        cache.insert(1, for: "huge", cost: 500)
        #expect(cache.count == 0)
        for i in 0..<10 { cache.insert(i, for: "k\(i)", cost: 10) }
        #expect(cache.totalCost == 100)
        cache.trim(toBytes: 25)
        #expect(cache.keysByAge == ["k8", "k9"])
        cache.byteLimit = 10
        #expect(cache.keysByAge == ["k9"])
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalCost == 0)
    }

    @Test func replacingAnEntryUpdatesCost() {
        let cache = ByteBudgetCache<String, Int>(byteLimit: 100)
        cache.insert(1, for: "a", cost: 30)
        cache.insert(2, for: "a", cost: 50)
        #expect(cache.totalCost == 50 && cache.value(for: "a") == 2)
    }

    @Test func keyIncludesVersionAndPixelSize() {
        let url = URL(fileURLWithPath: "/tmp/x/photo.jpg")
        let a = FileItem(url: url, name: "photo.jpg", isFolder: false, size: 10, modified: Date(timeIntervalSinceReferenceDate: 5))
        let b = FileItem(url: url, name: "photo.jpg", isFolder: false, size: 10, modified: Date(timeIntervalSinceReferenceDate: 6))
        #expect(ThumbnailKey(item: a, pixels: 96) != ThumbnailKey(item: b, pixels: 96))
        #expect(ThumbnailKey(item: a, pixels: 96) != ThumbnailKey(item: a, pixels: 192))
        #expect(ThumbnailKey(item: a, pixels: 96).resized(192) == ThumbnailKey(item: a, pixels: 192))
    }

    @Test func thumbnailEligibility() {
        func file(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isFolder: false) }
        #expect(ThumbnailPolicy.wantsThumbnail(file("a.jpg"), iconPoints: 96, iconsOnly: false))
        #expect(ThumbnailPolicy.wantsThumbnail(file("a.PNG"), iconPoints: 48, iconsOnly: false))
        #expect(ThumbnailPolicy.wantsThumbnail(file("a.pdf"), iconPoints: 256, iconsOnly: false))
        #expect(ThumbnailPolicy.wantsThumbnail(file("a.mov"), iconPoints: 96, iconsOnly: false))
        #expect(!ThumbnailPolicy.wantsThumbnail(file("a.mp3"), iconPoints: 96, iconsOnly: false))
        #expect(!ThumbnailPolicy.wantsThumbnail(file("a.txt"), iconPoints: 96, iconsOnly: false))
        #expect(!ThumbnailPolicy.wantsThumbnail(file("a.jpg"), iconPoints: 16, iconsOnly: false))
        #expect(!ThumbnailPolicy.wantsThumbnail(file("a.jpg"), iconPoints: 96, iconsOnly: true))
        let folder = FileItem(url: URL(fileURLWithPath: "/tmp/pics.jpg"), name: "pics.jpg", isFolder: true)
        #expect(!ThumbnailPolicy.wantsThumbnail(folder, iconPoints: 96, iconsOnly: false))
        #expect(ThumbnailPolicy.decodedCost(width: 512, height: 256) == 512 * 256 * 4)
    }

    @Test func middleTruncationKeepsExtension() {
        let fits: (String) -> Bool = { $0.count <= 12 }
        #expect(MiddleTruncation.fit("short.txt", fits: fits) == "short.txt")
        let cut = MiddleTruncation.fit("a very long holiday photo.jpeg", fits: fits)
        #expect(cut.count == 12)
        #expect(cut.hasSuffix(".jpeg"))
        #expect(cut.hasPrefix("a ve"))
        #expect(cut.contains("…"))
    }
}
