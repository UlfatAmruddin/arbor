import AppKit
import ArborCore

extension BrowserWindowController: NSMenuItemValidation {
    // MARK: - Commands

    /// A context for the active tab, with a frozen selection snapshot.
    func context(surface: CommandSurface, sender: Any?) -> CommandContext {
        guard !tabs.isEmpty else { return CommandContext(window: self, location: nil, surface: surface, sender: sender) }
        let shown = activeTab.displayedLocation ?? activeTab.location
        return CommandContext(window: self, location: shown, selection: selectedItems,
                              targetFolder: LocationRegistry.provider(for: shown).targetFolder(for: shown),
                              surface: surface, sender: sender)
    }

    @discardableResult
    func perform(_ id: String, surface: CommandSurface = .script, sender: Any? = nil) -> Bool {
        CommandRegistry.shared.perform(id, context: context(surface: surface, sender: sender))
    }

    // Edit menu actions: text fields get them first, then the window.
    @objc func cut(_ sender: Any?) { performMenuAction(#selector(cut(_:)), sender) }
    @objc func copy(_ sender: Any?) { performMenuAction(#selector(copy(_:)), sender) }
    @objc func paste(_ sender: Any?) { performMenuAction(#selector(paste(_:)), sender) }
    @objc override func selectAll(_ sender: Any?) { performMenuAction(#selector(selectAll(_:)), sender) }

    private func performMenuAction(_ action: Selector, _ sender: Any?) {
        guard let command = CommandRegistry.shared.command(forMenuAction: action) else { return }
        let ctx = context(surface: .menuBar, sender: sender)
        guard command.isAvailable(ctx), command.isEnabled(ctx) else { CommandDispatcher.shared.refuse(command, ctx); return }
        command.perform(ctx)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let command = CommandRegistry.shared.command(forMenuAction: action) else { return true }
        return CommandDispatcher.shared.validate(command, item: menuItem, context: context(surface: .menuBar, sender: nil))
    }

    func contextMenu(for surface: CommandSurface) -> NSMenu {
        let ctx = context(surface: surface, sender: nil)
        return CommandDispatcher.shared.menu(for: surface == .itemContextMenu ? .itemContextMenu : .backgroundContextMenu, context: ctx)
    }
}
