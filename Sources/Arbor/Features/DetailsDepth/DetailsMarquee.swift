import AppKit
import ArborCore

/// Rubber-band selection in Details (FE-058, DEC-iconviews-10): a press outside the icon and name drags a band.
extension DetailsViewController {
    enum PressTarget: String {
        case item, rowSpace, belowRows
    }

    /// The latest press, for the `detailsmarquee:` log line.
    static var marqueeTrace = (press: "none", hits: 0, band: CGRect.zero)

    /// Nil when the location's columns have no name column; every press then stays native.
    var nameShape: DetailsNameShape? {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0 else { return nil }
        return DetailsNameShape(column: table.rect(ofColumn: column).xExtent, hasCheckbox: Prefs.itemCheckBoxes,
                                rightToLeft: table.userInterfaceLayoutDirection == .rightToLeft)
    }

    func nameExtent(of item: FileItem, in shape: DetailsNameShape) -> ClosedRange<CGFloat> {
        let name = shownName(item)
        return shape.extent(textWidth: TextWidthCache.width(name, font: Theme.listFont),
                          fillsField: DetailsNameShape.containsRightToLeftScript(name))
    }

    func pressTarget(at point: CGPoint, shape: DetailsNameShape) -> PressTarget? {
        let row = table.row(at: point)
        guard row >= 0 else { return .belowRows }
        guard let item = item(atRow: row) else { return nil }
        return nameExtent(of: item, in: shape).contains(point.x) ? .item : .rowSpace
    }

    /// True if the press was consumed; false leaves it to NSTableView.
    func marqueePress(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.control), event.clickCount == 1, !isEditingName, let shape = nameShape,
              let target = pressTarget(at: table.convert(event.locationInWindow, from: nil), shape: shape) else { return false }
        Self.marqueeTrace = (target.rawValue, 0, .zero)
        switch target {
        case .item:
            return false
        case .belowRows:
            runMarquee(from: event, seed: nil, shape: shape)
            return true
        case .rowSpace:
            switch PointerTracking.awaitDrag(in: table, from: event) {
            case .dragged(let drag):
                runMarquee(from: event, seed: drag, shape: shape)
                return true
            case .released(let up):
                PointerTracking.replayRelease(up)
                return false
            case .abandoned:
                return true
            }
        }
    }

    private func runMarquee(from press: NSEvent, seed: NSEvent?, shape: DetailsNameShape) {
        table.pressBecameMarquee = true
        isTrackingMarquee = true
        let sweep = DetailsBandSweep(owner: self, press: press, shape: shape)
        defer {
            // First, or the deferred update would just be deferred again.
            isTrackingMarquee = false
            sweep.finish()
            applyDeferredUpdate()
        }
        sweep.begin()
        if let seed { sweep.move(toWindowPoint: seed.locationInWindow) }
        PointerTracking.followMarquee(in: table, from: seed ?? press, alreadyMoved: seed != nil,
                                      moved: sweep.move(toWindowPoint:), autoscroll: sweep.autoscroll(toward:))
    }
}

/// One band drag over the rows; lives only for the synchronous tracking loop.
private final class DetailsBandSweep {
    private let owner: DetailsViewController
    private let table: FileTableView
    private let drag: MarqueeDrag
    private let shape: DetailsNameShape
    /// A different count later means rows were rebuilt and row indexes no longer mean the same items.
    private let rowCount: Int
    private let bandView = MarqueeBandView()
    /// The band re-tests the same rows many times a second; each name is measured once.
    private var nameExtents: [Int: ClosedRange<CGFloat>] = [:]
    private var hits = IndexSet()
    private var lastBand = CGRect.zero

    init(owner: DetailsViewController, press: NSEvent, shape: DetailsNameShape) {
        self.owner = owner
        self.shape = shape
        table = owner.table
        rowCount = owner.rows.count
        let toggle = press.modifierFlags.contains(.command), add = press.modifierFlags.contains(.shift)
        // A focused group header must never join a multiple selection.
        let base = toggle || add ? owner.table.selectedRowIndexes.filteredIndexSet { owner.item(atRow: $0) != nil } : IndexSet()
        drag = MarqueeDrag(start: owner.table.convert(press.locationInWindow, from: nil), base: base, toggle: toggle, add: add)
    }

    func begin() {
        table.window?.makeFirstResponder(table)
        if drag.base != table.selectedRowIndexes { table.selectRowIndexes(drag.base, byExtendingSelection: false) }
        // Outside the table: an overlay inside it would disturb its row views and the macOS 26 header.
        bandView.frame = owner.view.convert(owner.rowsViewport, from: table)
        owner.view.addSubview(bandView)
    }

    func move(toWindowPoint point: NSPoint) {
        lastBand = drag.band(to: table.convert(point, from: nil), within: table.bounds)
        bandView.band = bandView.convert(lastBand, from: table)
        guard owner.rows.count == rowCount else { return }
        hits = hitRows(in: lastBand)
        let selection = drag.selection(hits: hits)
        if selection != table.selectedRowIndexes { table.selectRowIndexes(selection, byExtendingSelection: false) }
    }

    func autoscroll(toward point: NSPoint) -> Bool {
        guard let scroll = table.enclosingScrollView else { return false }
        let clip = scroll.contentView
        let pointer = table.convert(point, from: nil), viewport = owner.rowsViewport
        var target = clip.bounds
        target.origin.x += MarqueeDrag.autoscrollStep(pointer: pointer.x, low: viewport.minX, high: viewport.maxX)
        target.origin.y += MarqueeDrag.autoscrollStep(pointer: pointer.y, low: viewport.minY, high: viewport.maxY)
        let origin = clip.constrainBoundsRect(target).origin
        guard origin != clip.bounds.origin else { return false }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// Shift-arrows continue from the band's first and last hit, as in the icon layouts.
    func finish() {
        DetailsViewController.marqueeTrace.hits = hits.count
        DetailsViewController.marqueeTrace.band = lastBand
        if owner.rows.count == rowCount, let first = hits.first, let last = hits.last,
           let anchor = owner.item(atRow: first), let lead = owner.item(atRow: last) {
            owner.restoreSelectionEnds(SelectionEnds(anchor: anchor.url, lead: lead.url))
        }
        bandView.removeFromSuperview()
    }

    private func hitRows(in band: CGRect) -> IndexSet {
        let extent = band.xExtent
        let reach = shape.reach(band: extent)
        // Full width and at least a point high: a straight drag along either axis has no area.
        let query = CGRect(x: table.bounds.minX, y: band.minY, width: table.bounds.width, height: max(band.height, 1))
        guard reach != .none, let candidates = Range(table.rows(in: query)) else { return [] }
        if reach == .everyRow || candidates.count > MarqueeDrag.preciseHitLimit { return itemRows(in: candidates) }
        return IndexSet(candidates.filter { row in
            guard let item = owner.item(atRow: row) else { return false }
            return nameExtent(row: row, item: item).overlaps(extent)
        })
    }

    private func itemRows(in range: Range<Int>) -> IndexSet {
        var rows = IndexSet(integersIn: range)
        if !owner.groups.isEmpty {
            for row in range where owner.headerIndex(atRow: row) != nil { rows.remove(row) }
        }
        return rows
    }

    private func nameExtent(row: Int, item: FileItem) -> ClosedRange<CGFloat> {
        if let known = nameExtents[row] { return known }
        let extent = owner.nameExtent(of: item, in: shape)
        nameExtents[row] = extent
        return extent
    }
}

private extension CGRect {
    var xExtent: ClosedRange<CGFloat> { minX...maxX }
}
