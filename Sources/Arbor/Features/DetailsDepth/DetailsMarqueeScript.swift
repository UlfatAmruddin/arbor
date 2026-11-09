import AppKit
import ArborCore

/// Script steps for the Details marquee; their grammar is in docs/features/icon-views.md.
extension DetailsDepth {
    static func registerMarqueeDebugSteps() {
        func details(_ w: BrowserWindowController?) -> DetailsViewController? { w?.itemView as? DetailsViewController }

        DebugScript.registerLogger("details-depth.marquee-log") { window in
            guard let d = details(window) else { return "detailsmarquee: none" }
            let trace = DetailsViewController.marqueeTrace
            let scroll = d.table.enclosingScrollView?.contentView.bounds.origin ?? .zero
            return "detailsmarquee: press=\(trace.press) hits=\(trace.hits) band=\(Int(trace.band.width))x\(Int(trace.band.height)) \(overlayReport(d))"
                + " tableRows=\(d.table.numberOfRows) selectedRows=\(d.table.selectedRowIndexes.count) tracking=\(d.isTrackingMarquee) scrolled=\(Int(scroll.x)),\(Int(scroll.y))"
        }
        DebugScript.registerStep("detailsmarquee") { arg, window in
            guard let d = details(window), let drag = ScriptedMarquee(arg) else { return 0.3 }
            return drag.run(in: d.table, origin: d.rowsViewport.origin)
        }
        DebugScript.registerStep("detailsrowclick") { arg, window in
            guard let d = details(window), let tableWindow = d.table.window else { return 0.3 }
            let parts = arg.components(separatedBy: ":")
            let numbers = parts[0].split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 2, numbers.allSatisfy(\.isFinite) else { return 0.3 }
            let origin = d.rowsViewport.origin
            let point = d.table.convert(CGPoint(x: origin.x + numbers[0], y: origin.y + numbers[1]), to: nil)
            for count in 1...(parts.count > 1 ? max(Int(parts[1]) ?? 1, 1) : 1) {
                ScriptedMouse.postClick(in: tableWindow, at: point, count: count)
            }
            return 0.5
        }
        DebugScript.registerStep("detailspress") { arg, window in
            guard let d = details(window), let colon = arg.firstIndex(of: ":") else { return 0.3 }
            let name = String(arg[..<colon]), path = String(arg[arg.index(after: colon)...])
            PerformanceDebug.append(pressReport(d, name: name), to: path)
            return 0.3
        }
    }

    /// Reads the overlay view itself, so the log proves it is installed and placed over the rows.
    private static func overlayReport(_ d: DetailsViewController) -> String {
        guard let overlay = d.view.subviews.lazy.compactMap({ $0 as? MarqueeBandView }).first, let band = overlay.band else { return "overlay=none" }
        let viewport = d.rowsViewport
        let shown = overlay.convert(band, to: d.table)
        let area = overlay.convert(overlay.bounds, to: d.table)
        let overRows = area.insetBy(dx: -0.5, dy: -0.5).contains(viewport) && viewport.insetBy(dx: -0.5, dy: -0.5).contains(area)
        return "overlay=\(Int(shown.minX - viewport.minX)),\(Int(shown.minY - viewport.minY)),\(Int(shown.width))x\(Int(shown.height)) overRows=\(overRows)"
    }

    /// Classifies sample points on one row and compares the arithmetic shape with the laid-out cell.
    private static func pressReport(_ d: DetailsViewController, name: String) -> String {
        let table = d.table
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, let shape = d.nameShape,
              let row = (0..<table.numberOfRows).first(where: { d.item(atRow: $0)?.name == name }), let item = d.item(atRow: row),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView else { return "detailspress: none" }
        let y = table.rect(ofRow: row).midY
        func target(_ x: CGFloat) -> String { d.pressTarget(at: CGPoint(x: x, y: y), shape: shape)?.rawValue ?? "native" }
        func same(_ frame: CGRect, _ extent: ClosedRange<CGFloat>) -> Bool { abs(frame.minX - extent.lowerBound) < 0.5 && abs(frame.maxX - extent.upperBound) < 0.5 }
        let extent = d.nameExtent(of: item, in: shape)
        let trailingEdge = table.userInterfaceLayoutDirection == .rightToLeft ? extent.lowerBound : extent.upperBound
        let inward: CGFloat = table.userInterfaceLayoutDirection == .rightToLeft ? 1 : -1
        var lines = ["press icon=\(target((shape.icon.lowerBound + shape.icon.upperBound) / 2)) nameEnd=\(target(trailingEdge + inward)) justPast=\(target(trailingEdge - inward * 2))"]
        let others = table.tableColumns.indices.filter { $0 != column }.map { "\(table.tableColumns[$0].identifier.rawValue)=\(target(table.rect(ofColumn: $0).midX))" }
        lines.append("press " + others.joined(separator: " "))
        // Constraints place the field's alignment rect; its frame is outset by the label's own padding.
        let iconFrame = table.convert(cell.icon.frame, from: cell)
        let fieldRect = table.convert(cell.nameField.alignmentRect(forFrame: cell.nameField.frame), from: cell)
        lines.append("layout icon=\(same(iconFrame, shape.icon)) field=\(same(fieldRect, shape.field))")
        return lines.joined(separator: "\n")
    }
}
