import CoreGraphics
import Testing
@testable import ArborCore

@Suite("Tab reordering slots (FE-019, FE-204)")
struct TabStripGeometryTests {
    // Four 100 pt tabs with 8 pt feet: content 416 pt, each view 116 pt, tab i at x = 100 * i.
    let width: CGFloat = 100, view: CGFloat = 116, content: CGFloat = 416

    func slot(_ minX: CGFloat, rtl: Bool) -> Int {
        TabStripGeometry.reorderSlot(tabMinX: minX, tabWidth: width, viewWidth: view, contentWidth: content, count: 4, rightToLeft: rtl)
    }

    @Test func leftToRightCountsFromTheLeft() {
        #expect(slot(0, rtl: false) == 0)
        #expect(slot(100, rtl: false) == 1)
        #expect(slot(140, rtl: false) == 1)
        #expect(slot(160, rtl: false) == 2)
        #expect(slot(300, rtl: false) == 3)
        #expect(slot(-50, rtl: false) == 0)
    }

    @Test func rightToLeftCountsFromTheRight() {
        // Mirrored: tab 0 sits at the right end (x = 416 - 116 = 300), tab 3 at the left end (x = 0).
        #expect(slot(300, rtl: true) == 0)
        #expect(slot(200, rtl: true) == 1)
        #expect(slot(0, rtl: true) == 3)
        // Dragging tab 0 left by 160 pt lands it in slot 2, not slot 1 as left-to-right arithmetic would say.
        #expect(slot(140, rtl: true) == 2)
    }
}
