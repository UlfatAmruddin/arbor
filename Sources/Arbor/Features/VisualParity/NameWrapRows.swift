import AppKit
import ArborCore

/// Measures wrapped Details names and remembers their heights (FE-055). Main thread; only exists while the option is on.
final class NameWrapRows {
    private(set) var metrics = NameWrapMetrics(fieldWidth: 1, lineHeight: 1, baseRowHeight: 1, showsExtensions: true)
    private var heights = NameWrapHeights()
    private var measuringBounds = NSRect(x: 0, y: 0, width: 1000, height: 100_000)
    private let probe = NSTextField(labelWithString: "")
    /// Rows were answered one line tall and need asking again.
    private let onRefusedRows: () -> Void
    var refitScheduled = false

    init(onRefusedRows: @escaping () -> Void) {
        self.onRefusedRows = onRefusedRows
        NameWrapRows.styleForWrapping(probe)
    }

    /// The same settings on the cell that measures and the cells that draw, so the two can't disagree.
    static func styleForWrapping(_ field: NSTextField) {
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
    }

    var measuredCount: Int { heights.count }

    /// True when anything a row's height depends on changed.
    func refit(fieldWidth: CGFloat, baseRowHeight: CGFloat, showsExtensions: Bool) -> Bool {
        probe.font = Theme.listFont
        let lineHeight = measure("X")
        let next = NameWrapMetrics(fieldWidth: fieldWidth, lineHeight: lineHeight, baseRowHeight: baseRowHeight, showsExtensions: showsExtensions)
        guard next != metrics else { return false }
        metrics = next
        // Constraints place the field's alignment rect; the cell measures with the frame.
        measuringBounds.size.width = probe.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: max(fieldWidth, 1), height: lineHeight)).width
        heights.removeAll()
        return true
    }

    func forgetHeights() { heights.removeAll() }

    func rowHeight(for text: NameWrapText) -> CGFloat { metrics.rowHeight(textHeight: textHeight(for: text)) }

    func textHeight(for text: NameWrapText) -> CGFloat { metrics.textHeight(measured: measuredHeight(of: text)) }

    func shownText(for text: NameWrapText) -> String {
        guard !metrics.fitsWithinLines(measuredHeight(of: text)) else { return text.display }
        return text.shortened { self.metrics.fitsWithinLines(self.measure($0)) }
    }

    private func measuredHeight(of text: NameWrapText) -> CGFloat {
        if let known = heights.height(of: text) { return known }
        switch heights.requestMeasurement() {
        case .refused:
            return metrics.lineHeight
        case .first:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.heights.endTurn() else { return }
                self.onRefusedRows()
            }
        case .granted:
            break
        }
        let height = measure(text.display)
        heights.record(height, for: text)
        return height
    }

    private func measure(_ display: String) -> CGFloat {
        probe.stringValue = display
        return probe.cell?.cellSize(forBounds: measuringBounds).height ?? metrics.lineHeight
    }
}
