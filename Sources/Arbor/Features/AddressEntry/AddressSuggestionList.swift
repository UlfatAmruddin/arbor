import AppKit
import ArborCore

/// The rows under the address bar. Draws what it is given and reports clicks; the controller owns every decision.
final class AddressSuggestionList {
    var onPick: ((Int) -> Void)?

    private let stack = NSStackView()
    private let panel: DropdownPanel
    private var buttons: [ChromeButton] = []

    private(set) var notice: PathCompletionNotice?

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        panel = DropdownPanel(content: stack, accessibilityLabel: L10n.tr("Path suggestions"))
    }

    var isVisible: Bool { panel.isVisible }
    var dropdown: DropdownPanel { panel }

    func show(_ rows: [PathCompletionCandidate], notice: PathCompletionNotice?, below anchor: NSView) {
        self.notice = notice
        let width = anchor.bounds.width - 8
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = rows.enumerated().map { index, row in makeButton(row, index: index, width: width) }
        buttons.forEach(stack.addArrangedSubview)
        if let notice { stack.addArrangedSubview(makeFooter(Self.text(for: notice), width: width)) }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.show(below: anchor)
    }

    func hide() { panel.hide() }

    func highlight(_ index: Int?) {
        for (position, button) in buttons.enumerated() { button.isToggled = position == index }
    }

    private func makeButton(_ row: PathCompletionCandidate, index: Int, width: CGFloat) -> ChromeButton {
        let button = ChromeButton(symbol: row.isFromHistory ? "clock" : row.isFolder ? "folder" : "doc", title: row.name)
        button.symbolSize = 12
        button.symbolTint = Theme.secondaryText
        button.fixedHeight = 26
        button.horizontalPadding = 8
        button.toolTip = row.text
        button.clipsToBounds = true   // a very long name stays inside its row
        button.onClick = { [weak self] _ in self?.onPick?(index) }
        button.setAccessibilityLabel(row.isFromHistory ? L10n.format("%@, recent location", row.name) : row.name)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private static func text(for notice: PathCompletionNotice) -> String {
        switch notice {
        case .moreMatches: return L10n.tr("More items not shown. Keep typing to narrow the list.")
        case .partialListing: return L10n.tr("Only part of this folder could be read.")
        }
    }

    private func makeFooter(_ text: String, width: CGFloat) -> NSView {
        let footer = NSTextField(labelWithString: text)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.secondaryText
        footer.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [footer])
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 2, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
}
