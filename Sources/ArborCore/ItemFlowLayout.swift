import Foundation
import CoreGraphics

/// Grid geometry for the non-Details layouts (FE-029, FE-030, FE-031): every cell has the same size, so
/// frames, hit tests and keyboard moves are arithmetic. Nothing is stored per item, which keeps
/// 100,000-item folders cheap (spec §15.3).
///
/// - `.rows` fills left → right, then the next row (icons, Small icons, Tiles, Content); scrolls vertically.
/// - `.columns` fills top → bottom, then the next column (List); scrolls horizontally.
public struct ItemFlowLayout: Equatable, Sendable {
    public enum Flow: Sendable { case rows, columns }

    public enum Move: Sendable { case left, right, up, down, home, end, pageUp, pageDown }

    public var flow: Flow
    /// Cell size. With `stretchesWidth` the width is computed from the viewport.
    public var itemSize: CGSize
    /// Gap between neighboring cells (width: horizontal, height: vertical).
    public var spacing: CGSize
    public var insetTop: CGFloat
    public var insetLeft: CGFloat
    public var insetBottom: CGFloat
    public var insetRight: CGFloat
    /// One full-width column (Content layout).
    public var stretchesWidth: Bool
    public var minimumStretchWidth: CGFloat

    public private(set) var count = 0
    public private(set) var viewport = CGSize.zero
    /// Cells per row (`.rows`) or number of columns in use (`.columns`).
    public private(set) var columns = 1
    /// Rows in use (`.rows`) or cells per column (`.columns`).
    public private(set) var rows = 0

    public init(flow: Flow, itemSize: CGSize, spacing: CGSize = .zero,
                insets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) = (0, 0, 0, 0),
                stretchesWidth: Bool = false, minimumStretchWidth: CGFloat = 320) {
        self.flow = flow
        self.itemSize = itemSize
        self.spacing = spacing
        insetTop = insets.top
        insetLeft = insets.left
        insetBottom = insets.bottom
        insetRight = insets.right
        self.stretchesWidth = stretchesWidth
        self.minimumStretchWidth = minimumStretchWidth
    }

    /// Recomputes rows and columns for `count` items in a visible area of `viewport`.
    public mutating func update(count: Int, viewport: CGSize) {
        self.count = max(0, count)
        self.viewport = viewport
        switch flow {
        case .rows:
            if stretchesWidth {
                itemSize.width = max(minimumStretchWidth, viewport.width - insetLeft - insetRight)
                columns = 1
            } else {
                let usable = viewport.width - insetLeft - insetRight + spacing.width
                columns = max(1, Int((usable / max(1, itemSize.width + spacing.width)).rounded(.down)))
            }
            rows = self.count == 0 ? 0 : (self.count + columns - 1) / columns
        case .columns:
            let usable = viewport.height - insetTop - insetBottom + spacing.height
            rows = max(1, Int((usable / max(1, itemSize.height + spacing.height)).rounded(.down)))
            columns = self.count == 0 ? 0 : (self.count + rows - 1) / rows
        }
    }

    /// Size of the scrollable content (at least the viewport along the non-scrolling axis).
    public var contentSize: CGSize {
        switch flow {
        case .rows:
            let height = insetTop + CGFloat(rows) * itemSize.height + CGFloat(max(0, rows - 1)) * spacing.height + insetBottom
            let width = stretchesWidth ? insetLeft + itemSize.width + insetRight : viewport.width
            return CGSize(width: max(viewport.width, width), height: max(viewport.height, height))
        case .columns:
            let width = insetLeft + CGFloat(columns) * itemSize.width + CGFloat(max(0, columns - 1)) * spacing.width + insetRight
            return CGSize(width: max(viewport.width, width), height: viewport.height)
        }
    }

    /// Row and column of an item in the grid.
    public func position(of index: Int) -> (row: Int, column: Int) {
        switch flow {
        case .rows: return (index / columns, index % columns)
        case .columns: return (index % max(1, rows), index / max(1, rows))
        }
    }

    public func index(row: Int, column: Int) -> Int? {
        guard row >= 0, column >= 0 else { return nil }
        let index: Int
        switch flow {
        case .rows:
            guard column < columns else { return nil }
            index = row * columns + column
        case .columns:
            guard row < rows else { return nil }
            index = column * rows + row
        }
        return index < count ? index : nil
    }

    /// Frame of a cell in content coordinates (top-left origin).
    public func frame(at index: Int) -> CGRect {
        let (row, column) = position(of: index)
        return CGRect(x: insetLeft + CGFloat(column) * (itemSize.width + spacing.width),
                      y: insetTop + CGFloat(row) * (itemSize.height + spacing.height),
                      width: itemSize.width, height: itemSize.height)
    }

    private func rowRange(_ minY: CGFloat, _ maxY: CGFloat, limit: Int) -> ClosedRange<Int>? {
        let pitch = itemSize.height + spacing.height
        let first = max(0, Int(((minY - insetTop) / pitch).rounded(.down)))
        let last = min(limit - 1, Int(((maxY - insetTop) / pitch).rounded(.down)))
        return first <= last ? first...last : nil
    }

    private func columnRange(_ minX: CGFloat, _ maxX: CGFloat, limit: Int) -> ClosedRange<Int>? {
        let pitch = itemSize.width + spacing.width
        let first = max(0, Int(((minX - insetLeft) / pitch).rounded(.down)))
        let last = min(limit - 1, Int(((maxX - insetLeft) / pitch).rounded(.down)))
        return first <= last ? first...last : nil
    }

    /// Items whose cells intersect `rect`, in index order.
    public func indexes(in rect: CGRect) -> [Int] {
        guard count > 0, !rect.isNull, rect.width >= 0, rect.height >= 0 else { return [] }
        guard let rowSpan = rowRange(rect.minY, rect.maxY, limit: rows),
              let columnSpan = columnRange(rect.minX, rect.maxX, limit: columns) else { return [] }
        var result: [Int] = []
        result.reserveCapacity(rowSpan.count * columnSpan.count)
        for row in rowSpan {
            for column in columnSpan {
                guard let index = index(row: row, column: column) else { continue }
                if frame(at: index).intersects(rect) { result.append(index) }
            }
        }
        return result.sorted()
    }

    /// The item whose cell contains `point`, if any (gaps and insets return nil).
    public func index(at point: CGPoint) -> Int? {
        let rowPitch = itemSize.height + spacing.height
        let columnPitch = itemSize.width + spacing.width
        guard point.x >= insetLeft, point.y >= insetTop else { return nil }
        let row = Int(((point.y - insetTop) / rowPitch).rounded(.down))
        let column = Int(((point.x - insetLeft) / columnPitch).rounded(.down))
        guard let index = index(row: row, column: column) else { return nil }
        return frame(at: index).contains(point) ? index : nil
    }

    /// The item nearest to the start of the visible area (for scroll restoration): the first cell of the
    /// first row (or column) that is at least half visible.
    public func firstVisibleIndex(in visible: CGRect) -> Int? {
        guard count > 0 else { return nil }
        switch flow {
        case .rows:
            let pitch = itemSize.height + spacing.height
            let row = max(0, Int(((visible.minY - insetTop + itemSize.height / 2) / pitch).rounded(.down)))
            return min(row * columns, count - 1)
        case .columns:
            let pitch = itemSize.width + spacing.width
            let column = max(0, Int(((visible.minX - insetLeft + itemSize.width / 2) / pitch).rounded(.down)))
            return min(column * rows, count - 1)
        }
    }

    /// Scroll origin that puts `index`'s row (or column) at the top (or left) edge, clamped to the content.
    public func scrollOrigin(toShowAtStart index: Int) -> CGPoint {
        let frame = frame(at: index)
        let content = contentSize
        switch flow {
        case .rows:
            let y = min(max(0, frame.minY - insetTop), max(0, content.height - viewport.height))
            return CGPoint(x: 0, y: y)
        case .columns:
            let x = min(max(0, frame.minX - insetLeft), max(0, content.width - viewport.width))
            return CGPoint(x: x, y: 0)
        }
    }

    /// Number of whole rows (`.rows`) or columns (`.columns`) that fit in the visible area.
    public func pageLines(visible: CGSize) -> Int {
        switch flow {
        case .rows: return max(1, Int((visible.height / max(1, itemSize.height + spacing.height)).rounded(.down)))
        case .columns: return max(1, Int((visible.width / max(1, itemSize.width + spacing.width)).rounded(.down)))
        }
    }

    /// Keyboard target for a spatial move (FE-060). With no current item every move lands on the first
    /// item, except End. Moves never wrap past the first or last item. Down/Right into a partial last
    /// row (or column) lands on the last item, like Explorer.
    public func target(from current: Int?, move: Move, visible: CGSize = .zero) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return move == .end ? count - 1 : 0 }
        let (row, column) = position(of: current)
        let page = pageLines(visible: visible)
        // "Line step" moves across lines (rows in .rows flow, columns in .columns flow).
        let lineStep = flow == .rows ? columns : rows
        let lastLine = flow == .rows ? rows - 1 : columns - 1
        let currentLine = flow == .rows ? row : column
        func acrossLines(_ lines: Int) -> Int {
            let candidate = current + lines * lineStep
            if candidate < 0 { return current }
            if candidate >= count { return currentLine < lastLine ? count - 1 : current }
            return candidate
        }
        switch (flow, move) {
        case (_, .home): return 0
        case (_, .end): return count - 1
        case (.rows, .left), (.columns, .up): return max(0, current - 1)
        case (.rows, .right), (.columns, .down): return min(count - 1, current + 1)
        case (.rows, .up), (.columns, .left): return acrossLines(-1)
        case (.rows, .down), (.columns, .right): return acrossLines(1)
        case (_, .pageUp):
            return current - min(page, currentLine) * lineStep
        case (_, .pageDown):
            let candidate = current + page * lineStep
            return candidate < count ? candidate : (currentLine < lastLine ? count - 1 : current)
        }
    }
}
