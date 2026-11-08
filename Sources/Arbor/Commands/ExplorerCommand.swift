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

/// One user-visible action. Register with `CommandRegistry.shared.register(...)`, once per id. Other
/// features change how it behaves in their places (Trash, archives, Gallery…) with
/// `CommandRegistry.shared.override(...)`, never by assigning its closures, so the result doesn't
/// depend on registration order (DEC-024).
final class ExplorerCommand {
    let id: String
    var title: String
    /// Optional context-dependent title ("Pin to Quick access" / "Unpin from Quick access").
    let dynamicTitle: ((CommandContext) -> String)?
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
    /// The command's own rules, as registered. Callers use `isAvailable(_:)` & co., which apply overrides.
    private let ownIsAvailable: (CommandContext) -> Bool
    private let ownIsEnabled: (CommandContext) -> Bool
    private let ownState: (CommandContext) -> NSControl.StateValue
    private let ownSubmenu: ((CommandContext) -> [NSMenuItem])?
    private let ownPerform: (CommandContext) -> Void
    /// What other features contributed (shared with the registry, which may hold it before the command exists).
    fileprivate(set) var extensions: CommandExtensions

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
        self.ownIsAvailable = isAvailable
        self.ownIsEnabled = isEnabled
        self.ownState = state
        self.ownSubmenu = submenu
        self.ownPerform = perform
        self.extensions = CommandExtensions(commandID: id)
    }

    // MARK: Effective behavior (the first matching override, else the command's own)

    func isAvailable(_ context: CommandContext) -> Bool {
        extensions.isAvailable.first(context) ?? ownIsAvailable(context)
    }

    func isEnabled(_ context: CommandContext) -> Bool {
        extensions.isEnabled.first(context) ?? ownIsEnabled(context)
    }

    func state(_ context: CommandContext) -> NSControl.StateValue {
        extensions.state.first(context) ?? ownState(context)
    }

    func title(in context: CommandContext) -> String {
        if let title = extensions.title.first(context) { return L10n.tr(title) }
        return dynamicTitle.map { L10n.tr($0(context)) } ?? title
    }

    /// Whether the title can change with the context (its own dynamic title, or an override's).
    var hasDynamicTitle: Bool { dynamicTitle != nil || !extensions.title.isEmpty }

    /// Whether the command shows a submenu (Open with ▸, Sort by ▸) instead of performing an action.
    var hasSubmenu: Bool { ownSubmenu != nil || !extensions.submenu.isEmpty }

    /// The submenu's items: an override's or the command's own, then every submenu adjustment.
    func submenuItems(_ context: CommandContext) -> [NSMenuItem] {
        let items = extensions.submenu.first(context) ?? ownSubmenu?(context) ?? []
        return extensions.submenuItems.apply(items, context)
    }

    func perform(_ context: CommandContext) {
        extensions.willPerform.send(context)
        if extensions.perform.first(context) == nil { ownPerform(context) }
    }

    /// What `perform` would do without override `overrideID` and the overrides that run before it:
    /// for an override that adds to the behavior it replaces ("forget the tile, then delete as usual").
    func perform(_ context: CommandContext, after overrideID: String) {
        if extensions.perform.first(context, after: overrideID) == nil { ownPerform(context) }
    }

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

// MARK: - Overrides

/// Per-command extension points (DEC-024). Each holds contributions by id; an override contributes to
/// the aspects it changes. For every aspect the first override (in run order) whose condition holds
/// decides; with none, the command's own closure does.
final class CommandExtensions {
    let commandID: String
    private(set) lazy var isAvailable = Handlers<CommandContext, Bool>(point("isAvailable"), "Where the command is listed.")
    private(set) lazy var isEnabled = Handlers<CommandContext, Bool>(point("isEnabled"), "Whether the command can run.")
    private(set) lazy var state = Handlers<CommandContext, NSControl.StateValue>(point("state"), "Check mark or toggle state.")
    private(set) lazy var title = Handlers<CommandContext, String>(point("title"), "The command's title.")
    private(set) lazy var submenu = Handlers<CommandContext, [NSMenuItem]>(point("submenu"), "The command's submenu.")
    private(set) lazy var submenuItems = Pipeline<[NSMenuItem], CommandContext>(
        point("submenuItems"), "Adjusts the submenu's items (extra entries, recording opened files).")
    private(set) lazy var perform = Handlers<CommandContext, Void>(point("perform"), "What the command does.")
    private(set) lazy var willPerform = Observers<CommandContext>(point("willPerform"), "Runs before the command performs.")
    /// The feature that replaced the command with its own version, if any (at most one).
    private(set) lazy var replacement = Provided<Bool>(point("replacement"), "A newer version of the command replaced it.",
                                                       default: false)

    init(commandID: String) { self.commandID = commandID }

    private func point(_ aspect: String) -> String { "commands[\(commandID)].\(aspect)" }

    /// The aspects that have contributions.
    var points: [ExtensionPointInfo] {
        let all: [ExtensionPointInfo] = [replacement, isAvailable, isEnabled, state, title, submenu, submenuItems, perform, willPerform]
        return all.filter { !$0.contributions.isEmpty }
    }
}

// MARK: - Registry

final class CommandRegistry {
    static let shared = CommandRegistry()
    static let changed = Notification.Name("ArborCommandsChanged")

    private var commands: [String: ExplorerCommand] = [:]
    private var registrationOrder: [String] = []
    /// Overrides by command id; kept here so a feature may override a command registered after it.
    private var extensionsByID: [String: CommandExtensions] = [:]
    /// The feature that registered each command.
    private var owners: [String: String] = [:]

    /// Registers a command. Each id is registered once: a second registration is an extension error
    /// (use `override` to change another feature's command).
    func register(_ command: ExplorerCommand) {
        let registry = ExtensionRegistry.shared
        if let existing = commands[command.id] {
            let owner = owners[command.id].map { "feature \"\($0)\"" } ?? "an earlier registration"
            registry.report(ExtensionError(point: "CommandRegistry", problem: .duplicateID, existing: owner,
                                           rejected: existing.id + (registry.currentFeature.map { " (feature \"\($0)\")" } ?? "")
                                               + "; use CommandRegistry.replace or override"))
            return
        }
        owners[command.id] = registry.currentFeature
        registrationOrder.append(command.id)
        if let shared = extensionsByID[command.id] { command.extensions = shared } else { extensionsByID[command.id] = command.extensions }
        commands[command.id] = command
        for rule in prefixRules where rule.matches(command.id) { rule.apply(command.id) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func extensions(for commandID: String) -> CommandExtensions {
        if let existing = extensionsByID[commandID] { return existing }
        let created = CommandExtensions(commandID: commandID)
        extensionsByID[commandID] = created
        return created
    }

    /// Changes a command where `when` holds (a location such as the Trash or Gallery): each closure given
    /// replaces the command's own for that aspect. Elsewhere the command is unchanged. `id` names the
    /// contribution ("trash.delete-permanently"); `order` decides between overrides whose conditions
    /// overlap (the first that holds wins).
    func override(_ commandID: String, _ id: String, order: ExtensionOrder = .normal,
                  when condition: @escaping (CommandContext) -> Bool,
                  isAvailable: ((CommandContext) -> Bool)? = nil,
                  isEnabled: ((CommandContext) -> Bool)? = nil,
                  state: ((CommandContext) -> NSControl.StateValue)? = nil,
                  title: ((CommandContext) -> String)? = nil,
                  submenu: ((CommandContext) -> [NSMenuItem])? = nil,
                  perform: ((CommandContext) -> Void)? = nil) {
        let ext = extensions(for: commandID)
        if let isAvailable { ext.isAvailable.register(id, order: order) { condition($0) ? isAvailable($0) : nil } }
        if let isEnabled { ext.isEnabled.register(id, order: order) { condition($0) ? isEnabled($0) : nil } }
        if let state { ext.state.register(id, order: order) { condition($0) ? state($0) : nil } }
        if let title { ext.title.register(id, order: order) { condition($0) ? title($0) : nil } }
        if let submenu { ext.submenu.register(id, order: order) { condition($0) ? submenu($0) : nil } }
        if let perform {
            ext.perform.register(id, order: order) { context -> Void? in
                guard condition(context) else { return nil }
                perform(context)
                return ()
            }
        }
    }

    /// Hides a command where `condition` holds.
    func hide(_ commandID: String, _ id: String, order: ExtensionOrder = .normal, when condition: @escaping (CommandContext) -> Bool) {
        override(commandID, id, order: order, when: condition, isAvailable: { _ in false })
    }

    /// Hides, where `condition` holds, every command whose id starts with `prefix` (except `excluded`),
    /// including commands registered later.
    func hide(prefix: String, except excluded: Set<String> = [], _ id: String, order: ExtensionOrder = .normal,
              when condition: @escaping (CommandContext) -> Bool) {
        let feature = ExtensionRegistry.shared.currentFeature
        let rule = PrefixRule(prefix: prefix, excluded: excluded) { [unowned self] commandID in
            // Recorded as the rule's feature, also for commands that register later.
            let registry = ExtensionRegistry.shared
            let current = registry.currentFeature
            registry.currentFeature = feature
            self.hide(commandID, id, order: order, when: condition)
            registry.currentFeature = current
        }
        prefixRules.append(rule)
        registrationOrder.filter(rule.matches).forEach(rule.apply)
    }

    private struct PrefixRule {
        let prefix: String
        let excluded: Set<String>
        let apply: (String) -> Void
        func matches(_ commandID: String) -> Bool { commandID.hasPrefix(prefix) && !excluded.contains(commandID) }
    }

    private var prefixRules: [PrefixRule] = []

    /// Replaces a registered command with a new version (a feature upgrading a core command: Sort ▾ items
    /// that know about column sorts). It keeps its place and the overrides made for it; each command can
    /// be replaced once. The feature replacing it must require the feature that registered it.
    func replace(_ command: ExplorerCommand, _ id: String) {
        guard commands[command.id] != nil else {
            ExtensionRegistry.shared.report(point: "commands[\(command.id)].replacement",
                                            "there is no command to replace (is the feature that registers it required?).",
                                            contribution: id)
            return
        }
        let ext = extensions(for: command.id)
        guard ext.replacement.providerID == nil else {
            ext.replacement.provide(id, true)   // records the second replacement as an error
            return
        }
        ext.replacement.provide(id, true)
        command.extensions = ext
        commands[command.id] = command
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Adjusts a command's submenu items after they are built (every contribution, in run order).
    func adjustSubmenu(_ commandID: String, _ id: String, order: ExtensionOrder = .normal,
                       _ transform: @escaping ([NSMenuItem], CommandContext) -> [NSMenuItem]) {
        extensions(for: commandID).submenuItems.add(id, order: order, transform)
    }

    /// Runs `observer` before a command performs (the command still does what it would).
    func beforePerform(_ commandID: String, _ id: String, order: ExtensionOrder = .normal,
                       _ observer: @escaping (CommandContext) -> Void) {
        extensions(for: commandID).willPerform.observe(id, order: order, observer)
    }

    /// Every per-command point with contributions, by command id.
    var extensionPoints: [ExtensionPointInfo] {
        extensionsByID.keys.sorted().flatMap { extensionsByID[$0]?.points ?? [] }
    }

    /// Records an extension error for every override of a command that was never registered (a typo,
    /// or a feature that went away). Run once all features registered.
    func checkOverrides() {
        for id in extensionsByID.keys.sorted() where commands[id] == nil {
            guard let ext = extensionsByID[id], !ext.points.isEmpty else { continue }
            let contributors = Set(ext.points.flatMap(\.contributionIDs)).sorted().joined(separator: ", ")
            ExtensionRegistry.shared.report(point: "commands[\(id)]", "no command has this id (contributions: \(contributors)).",
                                            contribution: contributors)
        }
    }

    func register(_ list: [ExplorerCommand]) { list.forEach(register) }

    func command(_ id: String) -> ExplorerCommand? { commands[id] }

    var all: [ExplorerCommand] { registrationOrder.compactMap { commands[$0] } }

    /// Per-slot section order (section name → rank) where a surface orders sections differently from
    /// the shared ranks, e.g. Explorer's background menu starts with View / Sort by / Group by.
    var sectionRanks: [CommandSlot: [String: Int]] = [:]

    /// Commands placed in a slot, ordered by section then order (then registration order).
    func entries(in slot: CommandSlot) -> [(command: ExplorerCommand, placement: CommandPlacement)] {
        var result: [(ExplorerCommand, CommandPlacement, Int)] = []
        for (index, id) in registrationOrder.enumerated() {
            guard let command = commands[id] else { continue }
            for placement in command.placements where placement.slot == slot { result.append((command, placement, index)) }
        }
        let ranks = sectionRanks[slot] ?? [:]
        func rank(_ s: MenuSection) -> Int { ranks[s.name] ?? s.rank }
        result.sort {
            if $0.1.section != $1.1.section, rank($0.1.section) != rank($1.1.section) { return rank($0.1.section) < rank($1.1.section) }
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
        super.init(title: context.map { CommandDispatcher.menuTitle(command, context: $0) } ?? command.title, action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) { fatalError() }
}

/// Builds menus from registry slots and dispatches menu items. It is the explicit target of every
/// command menu item, except responder-chain items (`menuAction`), which go through the window.
final class CommandDispatcher: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = CommandDispatcher()

    /// Adjusts a command's title in menus (not buttons), e.g. Explorer's sentence case in context menus.
    static let menuTitleHook = Pipeline<String, (command: ExplorerCommand, context: CommandContext)>(
        "CommandDispatcher.menuTitleHook", "Adjusts a command's title in menus (sentence case in context menus).",
        signature: "(title, (command, context)) -> title")

    static func menuTitle(_ command: ExplorerCommand, context: CommandContext) -> String {
        menuTitleHook.apply(command.title(in: context), (command, context))
    }

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
        if command.hasSubmenu {
            let menu = NSMenu(title: command.title)
            if let context { command.submenuItems(context).forEach(menu.addItem) }
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
        item.title = CommandDispatcher.menuTitle(command, context: context)
        item.state = command.state(context)
        if command.yieldsToTextInput, context.window?.isEditingText == true { return false }
        return command.isAvailable(context) && command.isEnabled(context)
    }

    // Submenus in the menu bar are filled when opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let parent = menu.supermenu?.items.first(where: { $0.submenu === menu }),
              let id = parent.representedObject as? String, let command = CommandRegistry.shared.command(id),
              command.hasSubmenu else { return }
        menu.removeAllItems()
        command.submenuItems(liveContext(surface: .menuBar)).forEach(menu.addItem)
    }
}
