import AppKit
import ArborCore

/// Geometry and fonts for one non-Details layout (windows11-reference §7). Values are our own
/// approximations of Windows 11 at 100 % scale (1 epx = 1 pt), not measured reference values
/// (spec §4.3). "Compact view" (FE-032) tightens padding and gaps but keeps icon and text sizes.
struct IconLayoutMetrics {
    enum Style { case iconAbove, iconLeft, tile, content }

    let mode: ViewMode
    let compact: Bool
    let style: Style
    /// Icon (or thumbnail) square, in points.
    let iconSize: CGFloat
    /// Cell size; List computes its width from the names, Content stretches to the view.
    var cellSize: CGSize
    let spacing: CGSize
    let insets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)
    /// Lines of name text under the icon before it's shortened (icon layouts).
    let labelLines: Int
    let nameFont: NSFont
    let detailFont: NSFont
    /// Padding inside the highlight above the icon and around the label.
    let padding: CGFloat
    let iconLabelGap: CGFloat

    var lineHeight: CGFloat { Self.lineHeight(nameFont) }
    var detailLineHeight: CGFloat { Self.lineHeight(detailFont) }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// Space for the check box column in row layouts when Item check boxes is on (FE-047).
    static let checkboxSize: CGFloat = 16
    static let checkboxColumn: CGFloat = 22

    init(mode: ViewMode, compact: Bool) {
        self.mode = mode
        self.compact = compact
        let label = Theme.listSmallFont   // View ▸ Text size (FE-050)
        let body = Theme.listFont
        let small = Theme.listSmallFont
        func iconCell(icon: CGFloat, width: CGFloat, compactWidth: CGFloat, lines: Int) -> (CGSize, CGFloat, CGFloat) {
            let pad: CGFloat = compact ? 4 : 6
            let gap: CGFloat = compact ? 3 : 5
            let height = pad + icon + gap + CGFloat(lines) * Self.lineHeight(label) + pad
            return (CGSize(width: compact ? compactWidth : width, height: ceil(height)), pad, gap)
        }
        switch mode {
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            let spec: (CGFloat, CGFloat, CGFloat, Int)
            switch mode {
            case .extraLargeIcons: spec = (256, 276, 268, 3)
            case .largeIcons: spec = (96, 124, 112, 2)
            default: spec = (48, 92, 84, 2)
            }
            let (size, pad, gap) = iconCell(icon: spec.0, width: spec.1, compactWidth: spec.2, lines: spec.3)
            style = .iconAbove
            iconSize = spec.0
            cellSize = size
            spacing = compact ? CGSize(width: 0, height: 0) : CGSize(width: 2, height: 4)
            insets = compact ? (4, 6, 8, 6) : (8, 10, 12, 10)
            labelLines = spec.3
            nameFont = label
            detailFont = small
            padding = pad
            iconLabelGap = gap
        case .smallIcons, .list:
            style = .iconLeft
            iconSize = 16
            cellSize = CGSize(width: mode == .smallIcons ? 236 : 220, height: Theme.scaledBlock(compact ? 22 : 26, lines: 1))
            spacing = mode == .list ? CGSize(width: compact ? 8 : 14, height: 0) : CGSize(width: compact ? 4 : 8, height: compact ? 0 : 2)
            insets = compact ? (4, 6, 6, 6) : (6, 10, 10, 10)
            labelLines = 1
            nameFont = body
            detailFont = small
            padding = 4
            iconLabelGap = 6
        case .tiles:
            style = .tile
            iconSize = 48
            cellSize = CGSize(width: compact ? 252 : 268, height: Theme.scaledBlock(compact ? 60 : 72, lines: 3))
            spacing = compact ? CGSize(width: 2, height: 2) : CGSize(width: 6, height: 6)
            insets = compact ? (4, 6, 6, 6) : (8, 10, 12, 10)
            labelLines = 1
            nameFont = body
            detailFont = small
            padding = 8
            iconLabelGap = 10
        case .content, .details:
            style = .content
            iconSize = 48
            cellSize = CGSize(width: 0, height: Theme.scaledBlock(compact ? 60 : 72, lines: 3))
            spacing = .zero
            insets = compact ? (2, 6, 6, 6) : (4, 8, 10, 8)
            labelLines = 1
            nameFont = body
            detailFont = small
            padding = 10
            iconLabelGap = 12
        }
    }

    func makeLayout() -> ItemFlowLayout {
        ItemFlowLayout(flow: mode == .list ? .columns : .rows, itemSize: cellSize, spacing: spacing,
                       insets: insets, stretchesWidth: style == .content, minimumStretchWidth: 420)
    }

    /// List columns are as wide as the longest name (Explorer sizes List columns to the names), within
    /// limits. Measures at most a few hundred of the longest names so 100k-item folders stay fast.
    static func listColumnWidth(names: [String], font: NSFont, checkBoxes: Bool) -> CGFloat {
        let sample: [String]
        if names.count > 400 {
            sample = Array(names.sorted { $0.utf16.count > $1.utf16.count }.prefix(200))
        } else {
            sample = names
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for name in sample { widest = max(widest, (name as NSString).size(withAttributes: attributes).width) }
        let chrome: CGFloat = 4 + 16 + 6 + 10 + (checkBoxes ? checkboxColumn : 0)
        return min(max(ceil(widest) + chrome, 150), 420)
    }
}

/// Where each part of one item is drawn, in grid coordinates.
struct ItemGeometry {
    var cell: CGRect
    /// The rounded hover/selection shape.
    var highlight: CGRect
    var icon: CGRect
    /// The name text (the rename box goes here).
    var name: CGRect
    var checkbox: CGRect
}
