import AppKit
import ArborCore

// MARK: - Where a command appears

/// Where a command is being invoked from.
enum CommandSurface: String {
    case menuBar, commandBar, itemContextMenu, backgroundContextMenu, treeContextMenu, tabContextMenu,
         statusBar, keyboard, script
}

/// A group inside a menu. Sections are separated by a separator and ordered by `rank`.
/// Features may define their own: `static let archive = MenuSection(rank: 450, name: "archive")`.
struct MenuSection: Hashable, Comparable {
    let rank: Int
    let name: String
    static func < (a: MenuSection, b: MenuSection) -> Bool { a.rank < b.rank }

    static let main = MenuSection(rank: 0, name: "main")
    static let open = MenuSection(rank: 100, name: "open")
    static let navigation = MenuSection(rank: 150, name: "navigation")
    static let new = MenuSection(rank: 200, name: "new")
    static let tabs = MenuSection(rank: 250, name: "tabs")
    static let clipboard = MenuSection(rank: 300, name: "clipboard")
    static let organize = MenuSection(rank: 400, name: "organize")
    static let archive = MenuSection(rank: 450, name: "archive")
    static let pin = MenuSection(rank: 500, name: "pin")
    static let share = MenuSection(rank: 600, name: "share")
    static let tools = MenuSection(rank: 700, name: "tools")
    static let view = MenuSection(rank: 800, name: "view")
    static let places = MenuSection(rank: 850, name: "places")
    static let selection = MenuSection(rank: 870, name: "selection")
    static let properties = MenuSection(rank: 900, name: "properties")
    static let window = MenuSection(rank: 950, name: "window")
}

/// Named places commands are listed. Each surface is built from the registry at display time.
enum CommandSlot: Hashable {
    /// Primary icon buttons after "New ▾": Cut, Copy, Paste, Rename, Share, Delete.
    case commandBar
    /// Shown after "View ▾" only while available (e.g. "Extract all" for a selected zip).
    case commandBarContextual
    /// Right end of the command bar ("Details").
    case commandBarTrailing
    /// Right end of the status bar (view toggles).
    case statusBarTrailing
    case newMenu, sortMenu, viewMenu, showMenu, seeMore
    case itemContextMenu, backgroundContextMenu, treeContextMenu, tabContextMenu
    /// A top-level menu bar menu by title ("File", "Edit", "View", "Go", "Window", or a new title).
    case mainMenu(String)
}

struct CommandPlacement: Hashable {
    var slot: CommandSlot
    var section: MenuSection
    /// Order within the section; lower comes first.
    var order: Double

    static func commandBar(_ order: Double) -> Self { .init(slot: .commandBar, section: .main, order: order) }
    static func commandBarContextual(_ order: Double) -> Self { .init(slot: .commandBarContextual, section: .main, order: order) }
    static func commandBarTrailing(_ order: Double) -> Self { .init(slot: .commandBarTrailing, section: .main, order: order) }
    static func statusBarTrailing(_ order: Double) -> Self { .init(slot: .statusBarTrailing, section: .main, order: order) }
    static func newMenu(_ section: MenuSection = .main, _ order: Double) -> Self { .init(slot: .newMenu, section: section, order: order) }
    static func sortMenu(_ section: MenuSection = .main, _ order: Double) -> Self { .init(slot: .sortMenu, section: section, order: order) }
    static func viewMenu(_ section: MenuSection = .main, _ order: Double) -> Self { .init(slot: .viewMenu, section: section, order: order) }
    static func showMenu(_ section: MenuSection = .main, _ order: Double) -> Self { .init(slot: .showMenu, section: section, order: order) }
    static func seeMore(_ section: MenuSection = .main, _ order: Double) -> Self { .init(slot: .seeMore, section: section, order: order) }
    static func itemContextMenu(_ section: MenuSection, _ order: Double) -> Self { .init(slot: .itemContextMenu, section: section, order: order) }
    static func backgroundContextMenu(_ section: MenuSection, _ order: Double) -> Self { .init(slot: .backgroundContextMenu, section: section, order: order) }
    static func treeContextMenu(_ section: MenuSection, _ order: Double) -> Self { .init(slot: .treeContextMenu, section: section, order: order) }
    static func tabContextMenu(_ section: MenuSection, _ order: Double) -> Self { .init(slot: .tabContextMenu, section: section, order: order) }
    static func mainMenu(_ title: String, _ section: MenuSection, _ order: Double) -> Self {
        .init(slot: .mainMenu(title), section: section, order: order)
    }
}

/// A menu key equivalent, e.g. `Shortcut("t")` = ⌘T, `Shortcut("n", [.command, .shift])` = ⇧⌘N.
struct Shortcut {
    var key: String
    var modifiers: NSEvent.ModifierFlags
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    static func function(_ code: Int, _ modifiers: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(String(Character(UnicodeScalar(code)!)), modifiers)
    }
}

/// A physical key handled outside the menu bar (F2, Delete, ⌥←, ⇧⌘1…). `itemView` bindings only
/// fire while the file list has focus; `window` bindings fire anywhere in the window except text fields.
struct KeyBinding {
    enum Scope { case itemView, window }
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var scope: Scope

    init(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], scope: Scope = .itemView) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.scope = scope
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection([.command, .option, .shift, .control]) == modifiers
    }
}

// MARK: - Context

/// Everything a command needs, frozen when the menu opens or the button is pressed (spec §7.1:
/// an action uses a frozen target snapshot, not whatever is selected when async work finishes).
struct CommandContext {
    weak var window: BrowserWindowController?
    /// The active tab's location (or the tab the menu was opened on).
    var location: Location?
    /// Selected items (item menus, command bar) or the right-clicked tree node.
    var selection: [FileItem]
    /// The real folder where New/Paste would put items, if any.
    var targetFolder: URL?
    var surface: CommandSurface
    /// The control or menu item that triggered the command (anchor for popovers/share).
    var sender: Any?
    /// Tab context menu: the tab that was right-clicked.
    var tabIndex: Int?
    /// Tree context menu: the node's location (also set for Home, This Mac… which have no file).
    var treeLocation: Location?

    var tab: TabState? { window?.tab(at: tabIndex) }
    var single: FileItem? { selection.count == 1 ? selection[0] : nil }
    var hasSelection: Bool { !selection.isEmpty }
    /// Whether the location allows rename/delete/new items (real folders do; This Mac doesn't).
    var allowsEditing: Bool { location.map { LocationRegistry.provider(for: $0).allowsItemEditing(in: $0) } ?? false }

    init(window: BrowserWindowController?, location: Location?, selection: [FileItem] = [], targetFolder: URL? = nil,
         surface: CommandSurface, sender: Any? = nil, tabIndex: Int? = nil, treeLocation: Location? = nil) {
        self.window = window
        self.location = location
        self.selection = selection
        self.targetFolder = targetFolder
        self.surface = surface
        self.sender = sender
        self.tabIndex = tabIndex
        self.treeLocation = treeLocation
    }

    /// The anchor view for popovers (Share).
    var anchorView: NSView? { (sender as? NSView) ?? window?.commandBar }
}

// MARK: - Command

/// One user-visible action. Register with `CommandRegistry.shared.register(...)`; registering an
/// existing id replaces it (a feature can upgrade a core command).
final class ExplorerCommand {
    let id: String
    var title: String
    /// Optional context-dependent title ("Pin to Quick access" / "Unpin from Quick access").
    var dynamicTitle: ((CommandContext) -> String)?
    var symbol: String?
    var tooltip: String?
    var shortcut: Shortcut?
    var keyBindings: [KeyBinding]
    var placements: [CommandPlacement]
    /// Main menu items with a responder selector (cut:, copy:, paste:, undo:…) are sent nil-targeted
    /// so text fields handle them first; the window controller forwards them to this command.
    var menuAction: Selector?
    /// Disabled while a text field is being edited, so ⌘⌫ etc. keep editing text.
    var yieldsToTextInput: Bool
    /// Command bar: show the title next to the icon.
    var showsTitle: Bool
    var isAvailable: (CommandContext) -> Bool
    var isEnabled: (CommandContext) -> Bool
    var state: (CommandContext) -> NSControl.StateValue
    /// A submenu instead of an action (Open with ▸, Sort by ▸).
    var submenu: ((CommandContext) -> [NSMenuItem])?
    var perform: (CommandContext) -> Void

    init(id: String, title: String, symbol: String? = nil, tooltip: String? = nil, shortcut: Shortcut? = nil,
         keyBindings: [KeyBinding] = [], placements: [CommandPlacement] = [], menuAction: Selector? = nil,
         yieldsToTextInput: Bool = false, showsTitle: Bool = false,
         dynamicTitle: ((CommandContext) -> String)? = nil,
         isAvailable: @escaping (CommandContext) -> Bool = { _ in true },
         isEnabled: @escaping (CommandContext) -> Bool = { _ in true },
         state: @escaping (CommandContext) -> NSControl.StateValue = { _ in .off },
         submenu: ((CommandContext) -> [NSMenuItem])? = nil,
         perform: @escaping (CommandContext) -> Void = { _ in }) {
        self.id = id
        self.title = L10n.tr(title)   // user-visible strings go through the string table (FE-204)
        self.symbol = symbol
        self.tooltip = tooltip.map { L10n.tr($0) }
        self.shortcut = shortcut
        self.keyBindings = keyBindings
        self.placements = placements
        self.menuAction = menuAction
        self.yieldsToTextInput = yieldsToTextInput
        self.showsTitle = showsTitle
        self.dynamicTitle = dynamicTitle
        self.isAvailable = isAvailable
        self.isEnabled = isEnabled
        self.state = state
        self.submenu = submenu
        self.perform = perform
    }

    func title(in context: CommandContext) -> String { dynamicTitle.map { L10n.tr($0(context)) } ?? title }

    /// "Cut (⌘X)" for tooltips.
    var tooltipText: String {
        let base = tooltip ?? title
        guard let shortcut else { return base }
        return "\(base) (\(shortcut.displayString))"
    }
}

extension Shortcut {
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        let impliedShift = key.count == 1 && key.uppercased() == key && key.lowercased() != key
        if modifiers.contains(.shift) || impliedShift { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key.unicodeScalars.first.map({ Int($0.value) }) {
        case NSF2FunctionKey: s += "F2"
        case NSF5FunctionKey: s += "F5"
        case 8: s += "⌫"
        case NSUpArrowFunctionKey: s += "↑"
        case 9: s += "⇥"
        case 13: s += "↩"
        default: s += key.uppercased()
        }
        return s
    }
}

// MARK: - Registry

final class CommandRegistry {
    static let shared = CommandRegistry()
    static let changed = Notification.Name("ArborCommandsChanged")

    private var commands: [String: ExplorerCommand] = [:]
    private var registrationOrder: [String] = []

    func register(_ command: ExplorerCommand) {
        if commands[command.id] == nil { registrationOrder.append(command.id) }
        commands[command.id] = command
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func register(_ list: [ExplorerCommand]) { list.forEach(register) }

    func command(_ id: String) -> ExplorerCommand? { commands[id] }

    var all: [ExplorerCommand] { registrationOrder.compactMap { commands[$0] } }

    /// Commands placed in a slot, ordered by section then order (then registration order).
    func entries(in slot: CommandSlot) -> [(command: ExplorerCommand, placement: CommandPlacement)] {
        var result: [(ExplorerCommand, CommandPlacement, Int)] = []
        for (index, id) in registrationOrder.enumerated() {
            guard let command = commands[id] else { continue }
            for placement in command.placements where placement.slot == slot { result.append((command, placement, index)) }
        }
        result.sort {
            if $0.1.section != $1.1.section { return $0.1.section < $1.1.section }
            if $0.1.order != $1.1.order { return $0.1.order < $1.1.order }
            return $0.2 < $1.2
        }
        return result.map { ($0.0, $0.1) }
    }

    /// Titles of main menus that commands use, in menu bar order.
    var mainMenuTitles: [String] {
        let fixed = ["File", "Edit", "View", "Go"]
        var extra: [String] = []
        for command in all {
            for case .mainMenu(let title) in command.placements.map(\.slot) where !fixed.contains(title) && title != "Window" && !extra.contains(title) {
                extra.append(title)
            }
        }
        return fixed + extra + ["Window"]
    }

    func command(for event: NSEvent, scope: KeyBinding.Scope) -> ExplorerCommand? {
        all.first { $0.keyBindings.contains { $0.scope == scope && $0.matches(event) } }
    }

    func command(forMenuAction action: Selector) -> ExplorerCommand? {
        all.first { $0.menuAction == action }
    }

    /// Runs a command if it is available and enabled. Returns false otherwise.
    @discardableResult
    func perform(_ id: String, context: CommandContext) -> Bool {
        guard let command = commands[id], command.isAvailable(context), command.isEnabled(context) else { return false }
        command.perform(context)
        return true
    }
}

// MARK: - Menus

/// A menu item bound to a command, optionally with a frozen context (context menus).
final class CommandMenuItem: NSMenuItem {
    let commandID: String
    var frozenContext: CommandContext?

    init(command: ExplorerCommand, context: CommandContext?) {
        commandID = command.id
        frozenContext = context
        super.init(title: context.map { command.title(in: $0) } ?? command.title, action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) { fatalError() }
}

/// Builds menus from registry slots and dispatches menu items. It is the explicit target of every
/// command menu item, except responder-chain items (`menuAction`), which go through the window.
final class CommandDispatcher: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = CommandDispatcher()

    /// Context for the menu bar: the frontmost browser window's active tab.
    func liveContext(surface: CommandSurface, sender: Any? = nil) -> CommandContext {
        if let window = BrowserWindowController.active { return window.context(surface: surface, sender: sender) }
        return CommandContext(window: nil, location: nil, surface: surface, sender: sender)
    }

    /// Menu items for a slot. Unavailable commands are left out; sections get separators.
    func items(for slot: CommandSlot, context: CommandContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        var lastSection: MenuSection?
        for (command, placement) in CommandRegistry.shared.entries(in: slot) where command.isAvailable(context) {
            if let last = lastSection, last != placement.section, !items.isEmpty { items.append(.separator()) }
            lastSection = placement.section
            items.append(menuItem(command, context: context))
        }
        return items
    }

    func menu(for slot: CommandSlot, title: String = "", context: CommandContext) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = true
        items(for: slot, context: context).forEach(menu.addItem)
        return menu
    }

    /// A menu item for a command. Context menus pass a frozen context; the menu bar passes nil (live).
    func menuItem(_ command: ExplorerCommand, context: CommandContext?, showShortcut: Bool = true) -> NSMenuItem {
        let item = CommandMenuItem(command: command, context: context)
        if let symbol = command.symbol, context?.surface != .menuBar, context != nil {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let shortcut = command.shortcut, showShortcut {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        if let submenu = command.submenu {
            let menu = NSMenu(title: command.title)
            if let context { submenu(context).forEach(menu.addItem) }
            else { menu.delegate = self }   // menu bar: fill when opened
            item.submenu = menu
            item.representedObject = command.id
            return item
        }
        if context == nil, let action = command.menuAction {
            item.action = action      // responder chain: text fields first, then the window
        } else {
            item.action = #selector(performMenuItem(_:))
            item.target = self
        }
        if let context { item.state = command.state(context) }
        return item
    }

    @objc func performMenuItem(_ sender: NSMenuItem) {
        guard let item = sender as? CommandMenuItem, let command = CommandRegistry.shared.command(item.commandID) else { return }
        var context = item.frozenContext ?? liveContext(surface: .menuBar, sender: sender)
        context.sender = context.sender ?? sender
        guard command.isAvailable(context), command.isEnabled(context) else { NSSound.beep(); return }
        command.perform(context)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item = menuItem as? CommandMenuItem, let command = CommandRegistry.shared.command(item.commandID) else { return true }
        let context = item.frozenContext ?? liveContext(surface: .menuBar)
        return validate(command, item: menuItem, context: context)
    }

    /// Shared by the dispatcher and the window's responder-chain validation.
    func validate(_ command: ExplorerCommand, item: NSMenuItem, context: CommandContext) -> Bool {
        item.title = command.title(in: context)
        item.state = command.state(context)
        if command.yieldsToTextInput, context.window?.isEditingText == true { return false }
        return command.isAvailable(context) && command.isEnabled(context)
    }

    // Submenus in the menu bar are filled when opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let parent = menu.supermenu?.items.first(where: { $0.submenu === menu }),
              let id = parent.representedObject as? String, let command = CommandRegistry.shared.command(id),
              let submenu = command.submenu else { return }
        menu.removeAllItems()
        submenu(liveContext(surface: .menuBar)).forEach(menu.addItem)
    }
}
