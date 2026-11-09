import CoreGraphics
import Foundation
import Testing
@testable import ArborCore

@Suite struct MarqueeGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 1000)
    private func drag(at start: CGPoint = CGPoint(x: 100, y: 200), base: IndexSet = [], toggle: Bool = false, add: Bool = false) -> MarqueeDrag {
        MarqueeDrag(start: start, base: base, toggle: toggle, add: add)
    }

    @Test func bandCoversAllFourDirections() {
        let d = drag()
        #expect(d.band(to: CGPoint(x: 150, y: 260), within: bounds) == CGRect(x: 100, y: 200, width: 50, height: 60))
        #expect(d.band(to: CGPoint(x: 40, y: 260), within: bounds) == CGRect(x: 40, y: 200, width: 60, height: 60))
        #expect(d.band(to: CGPoint(x: 150, y: 90), within: bounds) == CGRect(x: 100, y: 90, width: 50, height: 110))
        #expect(d.band(to: CGPoint(x: 40, y: 90), within: bounds) == CGRect(x: 40, y: 90, width: 60, height: 110))
    }

    @Test func bandStaysInsideBounds() {
        let d = drag()
        #expect(d.band(to: CGPoint(x: -300, y: 5000), within: bounds) == CGRect(x: 0, y: 200, width: 100, height: 800))
        #expect(d.band(to: CGPoint(x: 9000, y: -40), within: bounds) == CGRect(x: 100, y: 0, width: 400, height: 200))
    }

    @Test func autoscrollIsZeroInsideAndBoundedOutside() {
        #expect(MarqueeDrag.autoscrollStep(pointer: 50, low: 0, high: 100) == 0)
        #expect(MarqueeDrag.autoscrollStep(pointer: 0, low: 0, high: 100) == 0)
        #expect(MarqueeDrag.autoscrollStep(pointer: 100, low: 0, high: 100) == 0)
        #expect(MarqueeDrag.autoscrollStep(pointer: 101, low: 0, high: 100) == 6)
        #expect(MarqueeDrag.autoscrollStep(pointer: -1, low: 0, high: 100) == -6)
        #expect(MarqueeDrag.autoscrollStep(pointer: 150, low: 0, high: 100) == 30)
        #expect(MarqueeDrag.autoscrollStep(pointer: 100_000, low: 0, high: 100) == 80)
        #expect(MarqueeDrag.autoscrollStep(pointer: -100_000, low: 0, high: 100) == -80)
    }

    @Test func selectionFollowsModifiers() {
        let base: IndexSet = [1, 2, 3]
        let hits: IndexSet = [3, 4]
        #expect(drag(base: base).selection(hits: hits) == [3, 4])
        #expect(drag(base: base, add: true).selection(hits: hits) == [1, 2, 3, 4])
        #expect(drag(base: base, toggle: true).selection(hits: hits) == [1, 2, 4])
        // ⌘ wins when both are held.
        #expect(drag(base: base, toggle: true, add: true).selection(hits: hits) == [1, 2, 4])
    }
}

@Suite struct DetailsNameShapeTests {
    private let column: ClosedRange<CGFloat> = 10...350

    @Test func leftToRightLayout() {
        let shape = DetailsNameShape(column: column, hasCheckbox: false, rightToLeft: false)
        #expect(shape.icon == 16...32)
        #expect(shape.field == 40...348)
        #expect(shape.extent(textWidth: 100, fillsField: false) == 16...(40 + 100 + DetailsNameShape.textMargin))
    }

    @Test func checkBoxesPushTheIconAlong() {
        let shape = DetailsNameShape(column: column, hasCheckbox: true, rightToLeft: false)
        #expect(shape.icon.lowerBound == 36)
        #expect(shape.field == 60...348)
    }

    @Test func mirroredLayoutCountsTheWholeField() {
        let shape = DetailsNameShape(column: column, hasCheckbox: false, rightToLeft: true)
        #expect(shape.icon == 328...344)
        #expect(shape.field == 12...320)
        // Whatever the width: a Latin name sits at the far side of the field in this layout.
        #expect(shape.extent(textWidth: 20, fillsField: false) == 12...344)
    }

    @Test func textIsClampedToTheField() {
        let shape = DetailsNameShape(column: column, hasCheckbox: false, rightToLeft: false)
        let fieldWidth = shape.field.upperBound - shape.field.lowerBound
        #expect(shape.extent(textWidth: 5000, fillsField: false).upperBound == shape.field.upperBound)
        #expect(shape.extent(textWidth: fieldWidth - 1, fillsField: false).upperBound == shape.field.upperBound)
        #expect(shape.extent(textWidth: 0, fillsField: false).upperBound == shape.field.lowerBound + DetailsNameShape.textMargin)
        #expect(shape.extent(textWidth: -40, fillsField: false).upperBound == shape.field.lowerBound + DetailsNameShape.textMargin)
    }

    @Test func fillsFieldIgnoresTheMeasuredWidth() {
        let shape = DetailsNameShape(column: column, hasCheckbox: false, rightToLeft: false)
        #expect(shape.extent(textWidth: 1, fillsField: true).upperBound == shape.field.upperBound)
    }

    @Test func narrowColumnNeverGivesANegativeField() {
        for rightToLeft in [false, true] {
            let shape = DetailsNameShape(column: 0...10, hasCheckbox: true, rightToLeft: rightToLeft)
            #expect(shape.field.lowerBound == shape.field.upperBound)
            let extent = shape.extent(textWidth: 100, fillsField: false)
            #expect(extent.upperBound - extent.lowerBound >= DetailsNameShape.iconSize)
        }
    }

    @Test func reachTiers() {
        let shape = DetailsNameShape(column: column, hasCheckbox: false, rightToLeft: false)
        #expect(shape.reach(band: 20...25) == .everyRow)
        #expect(shape.reach(band: 0...500) == .everyRow)
        #expect(shape.reach(band: 200...300) == .measure)
        #expect(shape.reach(band: 0...12) == .none)
        #expect(shape.reach(band: 400...500) == .none)
        // A straight vertical drag has no width and still counts.
        #expect(shape.reach(band: 20...20) == .everyRow)
    }

    @Test func zeroWidthBandHitsTheEdgeOfTheName() {
        let shape = DetailsNameShape(column: column, hasCheckbox: false, rightToLeft: false)
        let extent = shape.extent(textWidth: 100, fillsField: false)
        #expect(extent.overlaps(50...50))
        #expect(extent.overlaps(extent.upperBound...extent.upperBound))
        #expect(!extent.overlaps((extent.upperBound + 0.5)...(extent.upperBound + 0.5)))
    }

    @Test func rightToLeftScriptDetection() {
        #expect(!DetailsNameShape.containsRightToLeftScript(""))
        #expect(!DetailsNameShape.containsRightToLeftScript("report-final (2).txt"))
        #expect(!DetailsNameShape.containsRightToLeftScript("日本語のファイル.txt"))
        #expect(DetailsNameShape.containsRightToLeftScript("שלום.txt"))
        #expect(DetailsNameShape.containsRightToLeftScript("ملف.pdf"))
        #expect(DetailsNameShape.containsRightToLeftScript("invoice\u{202E}cod.exe"))
        #expect(DetailsNameShape.containsRightToLeftScript("a\u{200F}b"))
        #expect(DetailsNameShape.containsRightToLeftScript("a\u{2067}b"))
    }
}
