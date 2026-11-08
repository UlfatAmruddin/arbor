import AppKit
import ArborCore

/// Explorer command bar (FE-094), built from `CommandRegistry`:
/// New ▾ | Cut Copy Paste Rename Share Delete | Sort ▾ View ▾ | contextual… | … (See more)   ·····   Details
final class CommandBarView: ThemeBackgroundView {
    /// Supplies a fresh context for every press and every update.
    var contextProvider: ((CommandSurface, Any?) -> CommandContext)?

    private let stack = NSStackView()
    let newButton = ChromeButton(symbol: "plus.circle", title: L10n.tr("New"), tooltip: "Create a new item")
    let sortButton = ChromeButton(symbol: "arrow.up.arrow.down", title: L10n.tr("Sort"), tooltip: "Sort items")
    let viewButton = ChromeButton(symbol: "list.bullet.rectangle", title: L10n.tr("View"), tooltip: "Layout and view options")
    let moreButton = ChromeButton(symbol: "ellipsis", tooltip: "See more")
    private var primary: [(ExplorerCommand, ChromeButton)] = []
    private var contextual: [(ExplorerCommand, ChromeButton)] = []
    private var trailing: [(ExplorerCommand, ChromeButton)] = []
    private var contextualIDs: [String] = []
    private let contextualSeparator = VerticalSeparator()
    private var observer: NSObjectProtocol?

    init() {
        super.init(Theme.toolbarBackground)
        bottomLine = Theme.separator
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(L10n.tr("Commands"))
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.commandBarHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
        ])
        newButton.showsMenuIndicator = true
        newButton.symbolTint = Theme.accent
        newButton.onPress = { [weak self] b in self?.popUp(.newMenu, from: b) }
        sortButton.showsMenuIndicator = true
        sortButton.onPress = { [weak self] b in self?.popUp(.sortMenu, from: b) }
        viewButton.showsMenuIndicator = true
        viewButton.onPress = { [weak self] b in self?.popUp(.viewMenu, from: b) }
        moreButton.fixedWidth = 36
        moreButton.onPress = { [weak self] b in self?.popUp(.seeMore, from: b) }
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: CommandRegistry.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func button(for command: ExplorerCommand) -> ChromeButton {
        let b = ChromeButton(symbol: command.symbol ?? "questionmark", title: command.showsTitle ? command.title : "",
                             tooltip: command.tooltipText)
        if !command.showsTitle { b.fixedWidth = 36 }
        if command.hasSubmenu, command.showsTitle { b.showsMenuIndicator = true }   // titled drop-downs get "▾" ("Collection ▾", "Search options ▾")
        b.setAccessibilityLabel(command.title)
        b.onClick = { [weak self] sender in self?.run(command, sender: sender) }
        b.identifier = NSUserInterfaceItemIdentifier(command.id)
        return b
    }

    private func run(_ command: ExplorerCommand, sender: ChromeButton) {
        guard let context = contextProvider?(.commandBar, sender) else { return }
        if command.hasSubmenu {
            let menu = NSMenu()
            command.submenuItems(context).forEach(menu.addItem)
            sender.popUp(menu)
            return
        }
        CommandRegistry.shared.perform(command.id, context: context)
    }

    private func popUp(_ slot: CommandSlot, from button: ChromeButton) {
        guard let context = contextProvider?(.commandBar, button) else { return }
        let menu = CommandDispatcher.shared.menu(for: slot, context: context)
        if menu.items.isEmpty {
            let none = NSMenuItem(title: L10n.tr("No commands"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        button.popUp(menu)
    }

    /// Rebuilds the buttons from the registry (also when a feature registers a command later).
    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        primary = CommandRegistry.shared.entries(in: .commandBar).map { ($0.command, button(for: $0.command)) }
        trailing = CommandRegistry.shared.entries(in: .commandBarTrailing).map { ($0.command, button(for: $0.command)) }
        contextual = []
        contextualIDs = []
        stack.addArrangedSubview(newButton)
        stack.addArrangedSubview(VerticalSeparator())
        primary.forEach { stack.addArrangedSubview($0.1) }
        stack.addArrangedSubview(VerticalSeparator())
        stack.addArrangedSubview(sortButton)
        stack.addArrangedSubview(viewButton)
        stack.addArrangedSubview(contextualSeparator)
        stack.addArrangedSubview(moreButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(spacer)
        trailing.forEach { stack.addArrangedSubview($0.1) }
        contextualSeparator.isHidden = true
        if let context = contextProvider?(.commandBar, nil) { update(context) }
    }

    /// Updates enabled/toggled states and inserts contextual commands that are available now.
    func update(_ context: CommandContext) {
        // "New ▾" greys out where nothing can be created (This Mac, Trash, archives), like Explorer.
        newButton.isEnabled = CommandRegistry.shared.entries(in: .newMenu).contains {
            $0.command.isAvailable(context) && $0.command.isEnabled(context)
        }
        for (command, button) in primary + trailing + contextual {
            button.isEnabled = command.isAvailable(context) && command.isEnabled(context)
            button.isToggled = command.state(context) == .on
            if command.hasDynamicTitle, command.showsTitle { button.title = command.title(in: context) }
        }
        let available = CommandRegistry.shared.entries(in: .commandBarContextual).map(\.command).filter { $0.isAvailable(context) }
        guard available.map(\.id) != contextualIDs else { return }
        contextual.forEach { $0.1.removeFromSuperview() }
        contextualIDs = available.map(\.id)
        contextual = available.map { ($0, button(for: $0)) }
        let insertAt = (stack.arrangedSubviews.firstIndex(of: contextualSeparator) ?? 0) + 1
        for (offset, pair) in contextual.enumerated() {
            stack.insertArrangedSubview(pair.1, at: insertAt + offset)
            pair.1.isEnabled = pair.0.isEnabled(context)
        }
        contextualSeparator.isHidden = contextual.isEmpty
    }

    /// "id:enabled" for every button, for scripted checks.
    var debugState: String {
        (primary + contextual + trailing).map { "\($0.0.id)\($0.1.isEnabled ? "" : "(off)")\($0.1.isToggled ? "(on)" : "")" }
            .joined(separator: " ")
    }
}

/// Explorer status bar (FE-034): "12 items  |  1 item selected  4.1 KB  |" on the left, transfer
/// progress, then view toggles (Details, Large icons) at the right end.
final class StatusBarView: ThemeBackgroundView {
    private let summary = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let jobLabel = NSTextField(labelWithString: "")
    private let jobProgress = NSProgressIndicator()
    private let jobCancel = ChromeButton(symbol: "xmark.circle.fill", tooltip: "Cancel transfers")
    private let toggles = NSStackView()
    private var toggleButtons: [(ExplorerCommand, ChromeButton)] = []
    private var clearMessage: DispatchWorkItem?
    var onCancelJobs: (() -> Void)?
    var contextProvider: ((CommandSurface, Any?) -> CommandContext)?

    init() {
        super.init(Theme.navPaneBackground)
        for label in [summary, message, jobLabel] {
            label.font = Theme.statusFont
            label.textColor = Theme.secondaryText
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        summary.textColor = Theme.primaryText
        summary.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        summary.setAccessibilityLabel(L10n.tr("Status"))
        jobProgress.style = .bar
        jobProgress.controlSize = .small
        jobProgress.isIndeterminate = false
        jobProgress.minValue = 0
        jobProgress.maxValue = 1
        jobProgress.widthAnchor.constraint(equalToConstant: 90).isActive = true
        jobCancel.fixedWidth = 22
        jobCancel.fixedHeight = 20
        jobCancel.symbolSize = 11
        jobCancel.onClick = { [weak self] _ in self?.onCancelJobs?() }
        [jobLabel, jobProgress, jobCancel].forEach { $0.isHidden = true }
        toggles.spacing = 2

        let stack = NSStackView(views: [summary, message, NSView(), jobLabel, jobProgress, jobCancel, toggles])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.statusBarHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        rebuildToggles()
    }

    required init?(coder: NSCoder) { fatalError() }

    func rebuildToggles() {
        toggles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        toggleButtons = CommandRegistry.shared.entries(in: .statusBarTrailing).map { entry in
            let b = ChromeButton(symbol: entry.command.symbol ?? "questionmark", tooltip: entry.command.tooltipText)
            b.fixedWidth = 24
            b.fixedHeight = 20
            b.symbolSize = 11
            b.setAccessibilityLabel(entry.command.title)
            b.onClick = { [weak self] sender in
                guard let context = self?.contextProvider?(.statusBar, sender) else { return }
                CommandRegistry.shared.perform(entry.command.id, context: context)
            }
            toggles.addArrangedSubview(b)
            return (entry.command, b)
        }
    }

    func update(_ context: CommandContext) {
        for (command, button) in toggleButtons {
            button.isEnabled = command.isAvailable(context) && command.isEnabled(context)
            button.isToggled = command.state(context) == .on
        }
    }

    func setSummary(_ text: String) { summary.stringValue = text }

    var debugText: String { [summary.stringValue, message.stringValue, jobLabel.stringValue].filter { !$0.isEmpty }.joined(separator: " | ") }

    var debugToggles: String {
        toggleButtons.map { "\($0.0.id)\($0.1.isEnabled ? "" : "(off)")\($0.1.isToggled ? "(on)" : "")" }.joined(separator: " ")
    }

    /// Observers of status messages (VoiceOver announces outcomes and errors).
    static let messageHooks = Observers<(bar: StatusBarView, text: String?, isError: Bool)>(
        "StatusBarView.messageHooks", "A status bar message was set.", signature: "(bar, text?, isError)")

    func setMessage(_ text: String?, isError: Bool = false) {
        Self.messageHooks.send((self, text, isError))
        clearMessage?.cancel()
        message.stringValue = text ?? ""
        message.textColor = isError ? .systemRed : Theme.secondaryText
        guard text != nil, !isError else { return }
        let work = DispatchWorkItem { [weak self] in self?.message.stringValue = "" }
        clearMessage = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func setJob(_ job: (text: String, fraction: Double)?) {
        [jobLabel, jobProgress, jobCancel].forEach { $0.isHidden = job == nil }
        jobLabel.stringValue = job?.text ?? ""
        jobProgress.doubleValue = job?.fraction ?? 0
    }
}
