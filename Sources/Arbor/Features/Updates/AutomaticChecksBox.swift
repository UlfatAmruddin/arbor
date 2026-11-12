import AppKit
import ArborCore

/// "Check for updates automatically" on Folder Options' General page (FE-259), bound to the updater:
/// it applies at once and follows changes made elsewhere.
final class AutomaticChecksBox: NSButton {
    static let identifier = NSUserInterfaceItemIdentifier("updates.automaticChecks")
    private var observation: NSKeyValueObservation?

    static func group() -> NSView {
        let group = GroupBoxView(title: L10n.tr("Updates"), symbol: "arrow.down.circle")
        group.content.addArrangedSubview(AutomaticChecksBox())
        let note = NSTextField(wrappingLabelWithString: L10n.tr("About once a day. A newer version shows an Update button beside the tabs; nothing is installed until you choose."))
        note.font = DialogStyle.noteFont
        note.textColor = Theme.secondaryText
        note.isSelectable = false
        note.preferredMaxLayoutWidth = 300
        // Aligned with the switch's title, like the dialog's other notes.
        let indent = NSStackView(views: [note])
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        group.content.addArrangedSubview(indent)
        return group
    }

    private init() {
        super.init(frame: .zero)
        setButtonType(.switch)
        title = L10n.tr("Check for updates automatically")
        font = DialogStyle.font
        identifier = Self.identifier
        target = self
        action = #selector(toggled)
        observation = AppUpdater.shared?.observeAutomaticChecks { [weak self] on in self?.state = on ? .on : .off }
        isEnabled = observation != nil
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() { AppUpdater.shared?.checksAutomatically = state == .on }
}
