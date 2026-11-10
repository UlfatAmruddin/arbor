import CoreGraphics

/// Widths for a row of dialog tabs that has to stay inside its window (FE-204): a long translation gives up padding first, then text.
public enum TabRowFit {
    private static let minimumPadding: CGFloat = 6

    /// `natural` holds each tab's text width plus `padding`. Unchanged when it fits or the row has no width yet.
    public static func widths(_ natural: [CGFloat], padding: CGFloat, available: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard available > 0, total > available, !natural.isEmpty else { return natural }
        let spare = max(0, padding - minimumPadding)
        let perTab = (total - available) / CGFloat(natural.count)
        if perTab <= spare { return natural.map { $0 - perTab } }
        let text = natural.map { max(1, $0 - padding) }
        let room = max(1, available - minimumPadding * CGFloat(natural.count))
        let scale = room / text.reduce(0, +)
        return text.map { $0 * scale + minimumPadding }
    }
}
