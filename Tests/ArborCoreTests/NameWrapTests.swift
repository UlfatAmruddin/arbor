import Testing
import Foundation
@testable import ArborCore

@Suite("Wrapped names in Details (FE-055)")
struct NameWrapTests {
    private let metrics = NameWrapMetrics(fieldWidth: 200, lineHeight: 16, baseRowHeight: 28, showsExtensions: true)

    @Test func oneLineKeepsTheOrdinaryRowHeight() {
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: 16)) == 28)
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: 15)) == 28)
    }

    @Test func extraLinesAddTheirHeightUpToTheLimit() {
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: 32)) == 44)
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: 48)) == 60)
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: 480)) == 60)
    }

    @Test func aTallFallbackFontLineStillFits() {
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: 21)) == 33)
    }

    @Test(arguments: [CGFloat.infinity, -CGFloat.infinity, CGFloat.nan])
    func nonFiniteMeasurementsCountAsOneLine(_ value: CGFloat) {
        #expect(metrics.textHeight(measured: value) == 16)
        #expect(metrics.rowHeight(textHeight: metrics.textHeight(measured: value)) == 28)
    }

    @Test func aBreakGoesBeforeTheExtension() {
        #expect(NameWrapText("report.final.pdf", keepsExtension: true).display == "report.final\u{200B}.pdf")
    }

    @Test(arguments: [".zshrc", "name.", "plain", "no extension here"])
    func namesWithoutAnExtensionAreLeftAlone(_ name: String) {
        #expect(NameWrapText(name, keepsExtension: true).display == name)
    }

    @Test func foldersAndHiddenExtensionsGetNoBreak() {
        #expect(NameWrapText("My.Folder", keepsExtension: false).display == "My.Folder")
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"])
    func lineBreaksInANameBecomeSpaces(_ separator: String) {
        let text = NameWrapText("invoice.pdf" + separator + "evil.command", keepsExtension: true)
        #expect(text.display == "invoice.pdf evil\u{200B}.command")
        let hasBreak = text.display.contains { $0.isNewline }
        #expect(!hasBreak)
    }

    @Test func shorteningKeepsTheExtensionWhole() {
        let text = NameWrapText(String(repeating: "a", count: 200) + ".pdf", keepsExtension: true)
        let shown = text.shortened { $0.count <= 40 }
        #expect(shown.count <= 40)
        #expect(shown.hasSuffix(NameWrapText.extensionBreak + ".pdf"))
        #expect(shown.contains("…"))
    }

    @Test func measuredHeightsAreRememberedPerText() {
        var heights = NameWrapHeights()
        let file = NameWrapText("a.b", keepsExtension: true), folder = NameWrapText("a.b", keepsExtension: false)
        heights.record(32, for: file)
        #expect(heights.height(of: file) == 32)
        #expect(heights.height(of: folder) == nil)
        heights.removeAll()
        #expect(heights.height(of: file) == nil)
    }

    @Test func oneTurnStopsMeasuringAtItsAllowanceAndAsksAgain() {
        var heights = NameWrapHeights()
        let answers = (1...NameWrapHeights.measurementsPerTurn + 1).map { _ in heights.requestMeasurement() }
        #expect(answers.first == .first)
        #expect(answers.dropFirst().dropLast().allSatisfy { $0 == .granted })
        #expect(answers.last == .refused)
        let askAgain = heights.endTurn()
        #expect(askAgain)
        let nextTurn = heights.requestMeasurement()
        #expect(nextTurn == .first)
    }

    @Test func aTurnWithinItsAllowanceNeedsNoSecondPass() {
        var heights = NameWrapHeights()
        let answer = heights.requestMeasurement()
        #expect(answer == .first)
        let askAgain = heights.endTurn()
        #expect(!askAgain)
    }
}
