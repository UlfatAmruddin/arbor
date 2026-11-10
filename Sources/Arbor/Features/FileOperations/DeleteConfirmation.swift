import AppKit
import ArborCore

/// Delete confirmations (windows11-reference §9.5). Trash asks only if the pref is on (Windows default: off);
/// permanent deletion always asks. Trash never silently becomes a permanent delete.
final class DeleteConfirmation: FileOpsDialog {
    enum Mode: Equatable {
        case trash
        case permanent
        /// The items can't go to the Trash; `reason` says why.
        case cannotTrash(reason: String)
    }

    private let completion: (Bool) -> Void
    private var answered = false

    init(_ items: [FileItem], mode: Mode, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let single = items.count == 1 ? items[0] : nil
        let title = single.map { $0.isFolder ? L10n.tr("Delete Folder") : L10n.tr("Delete File") } ?? L10n.tr("Delete Multiple Items")
        super.init(title: title, width: 470)
        let count = StatusText.number(items.count)
        let text: String
        switch mode {
        case .trash:
            text = single.map { $0.isFolder ? L10n.tr("Are you sure you want to move this folder to the Trash?") : L10n.tr("Are you sure you want to move this file to the Trash?") }
                ?? L10n.format("Are you sure you want to move these %@ items to the Trash?", count)
        case .permanent:
            text = single.map { $0.isFolder ? L10n.tr("Are you sure you want to permanently delete this folder?") : L10n.tr("Are you sure you want to permanently delete this file?") }
                ?? L10n.format("Are you sure you want to permanently delete these %@ items?", count)
        case .cannotTrash:
            text = single.map { $0.isFolder ? L10n.tr("This folder can't be moved to the Trash. Do you want to permanently delete it?") : L10n.tr("This file can't be moved to the Trash. Do you want to permanently delete it?") }
                ?? L10n.format("These %@ items can't be moved to the Trash. Do you want to permanently delete them?", count)
        }
        let message = FileOpsStyle.label(text, font: FileOpsStyle.bodyFont, wraps: true)
        message.preferredMaxLayoutWidth = 420
        var views: [NSView] = [message]
        if case .cannotTrash(let reason) = mode {
            let why = FileOpsStyle.label(reason, font: FileOpsStyle.captionFont, color: Theme.secondaryText, wraps: true)
            why.preferredMaxLayoutWidth = 420
            views.append(why)
        }
        if let single { views.append(Self.details(single)) }
        if mode != .trash {
            views.append(FileOpsStyle.label(L10n.tr("This can't be undone."), font: FileOpsStyle.captionFont, color: Theme.secondaryText))
        }
        setBody(views, spacing: 14, insets: NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22))
        let yes = WinButton(L10n.tr("Yes"), accent: mode == .trash) { [weak self] in self?.answer(true) }
        let no = WinButton(L10n.tr("No"), accent: mode != .trash) { [weak self] in self?.answer(false) }
        if mode != .trash { yes.keyEquivalent = "" }   // Return answers No for destructive deletes
        setButtons([yes, no])
    }

    /// Icon, name, type, size and date of a single item.
    static func details(_ item: FileItem) -> NSView {
        let icon = NSImageView(image: IconProvider.shared.icon(for: item, size: 48))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        var lines = [FileOpsStyle.label(item.name, font: .systemFont(ofSize: 13, weight: .semibold))]
        let caption = { (text: String) in FileOpsStyle.label(text, font: FileOpsStyle.captionFont, color: Theme.secondaryText) }
        lines.append(caption(L10n.format("Type: %@", "\(item.typeDescription)")))
        if let size = item.size { lines.append(caption(L10n.format("Size: %@", "\(StatusText.bytes(size))"))) }
        if let date = item.modified { lines.append(caption(L10n.format("Date modified: %@", "\(ConflictFlow.dates.string(from: date))"))) }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 12
        row.alignment = .top
        return row
    }

    private func answer(_ yes: Bool) {
        guard !answered else { return }
        answered = true
        dismiss()
        completion(yes)
    }

    override func cancelled() { answer(false) }
}

/// Replaces the core Delete commands (same ids, placements, shortcuts) via `CommandRegistry.replace`.
enum DeleteCommands {
    static func register() {
        let backspace = String(Character(UnicodeScalar(8)))
        let commands = [
            ExplorerCommand(
                id: "file.trash", title: "Move to Trash", symbol: "trash", tooltip: "Delete (move to the Trash)",
                shortcut: Shortcut(backspace),
                placements: [.commandBar(60), .itemContextMenu(.organize, 20), .mainMenu("File", .organize, 10)],
                yieldsToTextInput: true,
                isAvailable: { $0.surface != .itemContextMenu || $0.hasSelection },
                isEnabled: { $0.hasSelection && $0.allowsEditing },
                perform: { ctx in
                    let items = ctx.selection
                    guard !items.isEmpty, let window = ctx.window else { NSSound.beep(); return }
                    guard Prefs.displayDeleteConfirmation else { return moveToTrash(items, window: window) }
                    DeleteConfirmation(items, mode: .trash) { yes in
                        if yes { moveToTrash(items, window: window) }
                    }.present(over: window.window)
                }),
            ExplorerCommand(
                id: "file.deletePermanently", title: "Delete Permanently…",
                shortcut: Shortcut(backspace, [.command, .option]),
                placements: [.mainMenu("File", .organize, 20)],
                yieldsToTextInput: true,
                isEnabled: { $0.hasSelection && $0.allowsEditing },
                perform: { ctx in
                    guard let window = ctx.window else { NSSound.beep(); return }
                    confirmPermanentDelete(ctx.selection, window: window, mode: .permanent)
                }),
        ]
        commands.forEach { CommandRegistry.shared.replace($0, "file-operations.delete-confirmation") }
    }

    static func moveToTrash(_ items: [FileItem], window: BrowserWindowController) {
        DeleteFlow.moveToTrash(items, window: window) { failed, reason in
            confirmPermanentDelete(failed, window: window, mode: .cannotTrash(reason: reason))
        }
    }

    static func confirmPermanentDelete(_ items: [FileItem], window: BrowserWindowController, mode: DeleteConfirmation.Mode) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let next = window.neighborURL(after: items)
        DeleteConfirmation(items, mode: mode) { [weak window] yes in
            guard yes else { return }
            DeleteFlow.deletePermanently(items, selecting: next, window: window)
        }.present(over: window.window)
    }
}
