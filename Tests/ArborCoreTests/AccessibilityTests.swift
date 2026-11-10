import Foundation
import Testing
@testable import ArborCore

@Suite("Focus regions (FE-062, FE-199)")
struct FocusCycleTests {
    let all = Set(FocusRegion.allCases)

    @Test func forwardFollowsExplorerOrderAndWraps() {
        #expect(FocusCycle.next(from: .tabs, forward: true, available: all) == .address)
        #expect(FocusCycle.next(from: .address, forward: true, available: all) == .search)
        #expect(FocusCycle.next(from: .search, forward: true, available: all) == .commandBar)
        #expect(FocusCycle.next(from: .commandBar, forward: true, available: all) == .navigationPane)
        #expect(FocusCycle.next(from: .navigationPane, forward: true, available: all) == .items)
        #expect(FocusCycle.next(from: .items, forward: true, available: all) == .sidePane)
        #expect(FocusCycle.next(from: .sidePane, forward: true, available: all) == .tabs)
    }

    @Test func backwardAndSkipsHiddenRegions() {
        var available = all
        available.remove(.sidePane)
        available.remove(.navigationPane)
        #expect(FocusCycle.next(from: .tabs, forward: false, available: available) == .items)
        #expect(FocusCycle.next(from: .items, forward: false, available: available) == .commandBar)
        #expect(FocusCycle.next(from: .items, forward: true, available: available) == .tabs)
    }

    @Test func fromNowhereStartsAtItems() {
        #expect(FocusCycle.next(from: nil, forward: true, available: all) == .items)
        #expect(FocusCycle.next(from: nil, forward: false, available: all) == .navigationPane)
        #expect(FocusCycle.next(from: .items, forward: true, available: []) == nil)
    }
}

@Suite("Announcements (spec §16.2)")
struct AnnouncementTests {
    @Test func throttlesBurstsAndSkipsRepeats() {
        var throttle = AnnouncementThrottle(interval: 1)
        #expect(throttle.submit("2 items selected", at: 10) == .now)
        #expect(throttle.submit("3 items selected", at: 10.5) == .after(0.5))
        throttle.spoke("3 items selected", at: 11)
        #expect(throttle.submit("3 items selected", at: 12.5) == .skip)
        #expect(throttle.submit("4 items selected", at: 12.5) == .now)
        #expect(throttle.submit("4 items selected", at: 30) == .now)
    }

    @Test func selectionTextOnlyForMultipleOrCleared() {
        #expect(AnnouncementText.selection(count: 1, previous: 0) == nil)
        #expect(AnnouncementText.selection(count: 3, previous: 1) == "3 items selected")
        #expect(AnnouncementText.selection(count: 3, previous: 3) == nil)
        #expect(AnnouncementText.selection(count: 0, previous: 5) == "Selection cleared")
        #expect(AnnouncementText.selection(count: 0, previous: 1) == nil)
        #expect(AnnouncementText.selection(count: 1200, previous: 2)?.hasPrefix("1") == true)
    }

    @Test func locationAndStatusText() {
        #expect(AnnouncementText.location("Documents", itemCount: 12) == "Documents, 12 items")
        #expect(AnnouncementText.location("Empty", itemCount: 0) == "Empty, empty")
        #expect(AnnouncementText.location("Home", itemCount: nil) == "Home")
        #expect(AnnouncementText.shouldSpeakStatus("3 items copied to “Docs”."))
        #expect(!AnnouncementText.shouldSpeakStatus("Loading “Docs”…"))
        #expect(!AnnouncementText.shouldSpeakStatus("  "))
        #expect(!AnnouncementText.shouldSpeakStatus(nil))
    }
}

@Suite("Text size (FE-050, FE-202)")
struct TextSizeTests {
    @Test func levelsStepUpAndDown() {
        #expect(TextSizeLevel.standard.bigger == .larger)
        #expect(TextSizeLevel.largest.bigger == nil)
        #expect(TextSizeLevel.large.smaller == .larger)
        #expect(TextSizeLevel.standard.smaller == nil)
    }

    @Test func rowsGrowWithTheFontSoGlyphsAreNotClipped() {
        for level in TextSizeLevel.allCases {
            let font = level.fontSize(13)
            let row = level.rowHeight(28, fontSize: 13)
            // A system font line is about 1.25 × the point size; rows keep at least 8 pt of padding.
            #expect(row >= (font * 1.25).rounded(.up) + 8)
            #expect(level.rowHeight(24, fontSize: 13) >= (font * 1.25).rounded(.up) + 4)
        }
        #expect(TextSizeLevel.standard.rowHeight(28, fontSize: 13) == 28)
        #expect(TextSizeLevel.largest.fontSize(13) == 19.5)
    }
}

@Suite("Input devices (FE-016, FE-061)")
struct InputDeviceTests {
    @Test func horizontalSwipeAtTheEdgeNavigates() {
        #expect(SwipeNavigation.decision(deltaX: 6, deltaY: 0.5, canScrollLeft: false, canScrollRight: true) == .back)
        #expect(SwipeNavigation.decision(deltaX: -6, deltaY: 0, canScrollLeft: true, canScrollRight: false) == .forward)
    }

    @Test func scrollableContentAndVerticalScrollsAreLeftAlone() {
        #expect(SwipeNavigation.decision(deltaX: 6, deltaY: 0, canScrollLeft: true, canScrollRight: true) == nil)
        #expect(SwipeNavigation.decision(deltaX: -6, deltaY: 0, canScrollLeft: false, canScrollRight: true) == nil)
        #expect(SwipeNavigation.decision(deltaX: 3, deltaY: 4, canScrollLeft: false, canScrollRight: false) == nil)
        #expect(SwipeNavigation.decision(deltaX: 0.2, deltaY: 0, canScrollLeft: false, canScrollRight: false) == nil)
        #expect(SwipeNavigation.direction(swipeDeltaX: 1) == .back)
        #expect(SwipeNavigation.direction(swipeDeltaX: -1) == .forward)
        #expect(SwipeNavigation.direction(swipeDeltaX: 0) == nil)
    }

    @Test func expandAllIsBreadthFirstAndBounded() {
        // A tree where every node has 3 children, forever.
        let plan = TreeExpansion.plan(root: "r", children: { node in (0..<3).map { "\(node).\($0)" } }, maxNodes: 10, maxDepth: 6)
        #expect(plan.truncated)
        #expect(plan.nodes.count == 10)
        #expect(plan.nodes.prefix(4) == ["r", "r.0", "r.1", "r.2"])
        let shallow = TreeExpansion.plan(root: "r", children: { node in node.count < 5 ? ["\(node)x"] : [] })
        #expect(!shallow.truncated)
        #expect(shallow.nodes == ["r", "rx", "rxx", "rxxx", "rxxxx"])
        let deep = TreeExpansion.plan(root: 0, children: { [$0 + 1] }, maxNodes: 100, maxDepth: 3)
        #expect(deep.nodes == [0, 1, 2, 3])
    }

    @Test func keyNamesParse() {
        let f10 = KeyNames.parse("shift+F10")
        #expect(f10?.code == 109)
        #expect(f10?.modifiers == ["shift"])
        #expect(KeyNames.parse("cmd+opt+left")?.modifiers == ["command", "option"])
        #expect(KeyNames.parse("menu")?.code == 110)
        #expect(KeyNames.parse("hyper+x") == nil)
        #expect(KeyNames.parse("a")?.characters == "a")
    }
}
