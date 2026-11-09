import AppKit
import ArborCore

// MARK: - Where a command appears

enum CommandSurface: String {
    case menuBar, commandBar, itemContextMenu, backgroundContextMenu, treeContextMenu, tabContextMenu,
         statusBar, keyboard, script
}

/// A separator-delimited menu group, ordered by `rank`. Features may add their own.
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

/// Where commands are listed; built from the registry at display time.
enum CommandSlot: Hashable {
    /// Icon buttons after "New ▾" (Cut, Copy, Paste…).
    case commandBar
    /// After "View ▾", only while available ("Extract all" for a zip).
    case commandBarContextual
    /// Right end of the command bar ("Details").
    case commandBarTrailing
    /// Right end of the status bar (view toggles).
    case statusBarTrailing
    case newMenu, sortMenu, viewMenu, showMenu, seeMore
    case itemContextMenu, backgroundContextMenu, treeContextMenu, tabContextMenu
    /// A menu bar menu by title ("File", "Edit"… or a new one).
    case mainMenu(String)
}

struct CommandPlacement: Hashable {
    var slot: CommandSlot
    var section: MenuSection
    /// Lower comes first within the section.
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

/// A key handled outside the menu bar (F2, ⌥←…). `itemView` fires only while the file list
/// has focus; `window` fires anywhere except text fields.
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

/// Frozen when the menu opens or the button is pressed, not read when async work ends (spec §7.1).
struct CommandContext {
    weak var window: BrowserWindowController?
    /// Of the active tab, or of the tab the menu was opened on.
    var location: Location?
    /// Selected items, or the right-clicked tree node.
    var selection: [FileItem]
    /// Where New/Paste would put items, if a real folder.
    var targetFolder: URL?
    var surface: CommandSurface
    /// The triggering control or menu item (popover anchor).
    var sender: Any?
    /// The right-clicked tab (tab context menu).
    var tabIndex: Int?
    /// The right-clicked tree node (also Home, This Mac…, which have no file).
    var treeLocation: Location?

    var tab: TabState? { window?.tab(at: tabIndex) }
    var single: FileItem? { selection.count == 1 ? selection[0] : nil }
    var hasSelection: Bool { !selection.isEmpty }
    /// Rename/delete/new allowed (real folders yes, This Mac no).
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

    var anchorView: NSView? { (sender as? NSView) ?? window?.commandBar }
}

// MARK: - Command

/// A user-visible action, registered once per id. Other features change it with `override(...)`,
/// never by assigning its closures, so registration order doesn't matter (DEC-024).
final class ExplorerCommand {
    let id: String
    var title: String
    /// Context-dependent title (Pin / Unpin from Quick access).
    let dynamicTitle: ((CommandContext) -> String)?
    var symbol: String?
    var tooltip: String?
    var shortcut: Shortcut?
    var keyBindings: [KeyBinding]
    var placements: [CommandPlacement]
    /// Sent nil-targeted from the main menu so text fields handle it first; the window forwards it here.
    var menuAction: Selector?
    /// Disabled while a text field is editing, so ⌘⌫ etc. edit text.
    var yieldsToTextInput: Bool
    /// Command bar: title next to the icon.
    var showsTitle: Bool
    /// As registered; callers use `isAvailable(_:)` & co., which apply overrides.
    private let ownIsAvailable: (CommandContext) -> Bool
    private let ownIsEnabled: (CommandContext) -> Bool
    private let ownState: (CommandContext) -> NSControl.StateValue
    private let ownSubmenu: ((CommandContext) -> [NSMenuItem])?
    private let ownPerform: (CommandContext) -> Void
    /// Other features' contributions; the registry may hold them before the command exists.
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
        self.title = L10n.tr(title)   // string table (FE-204)
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

    /// Its own or an override's dynamic title.
    var hasDynamicTitle: Bool { dynamicTitle != nil || !extensions.title.isEmpty }

    /// Shows a submenu (Open with ▸) instead of performing.
    var hasSubmenu: Bool { ownSubmenu != nil || !extensions.submenu.isEmpty }

    /// An override's or its own items, then every submenu adjustment.
    func submenuItems(_ context: CommandContext) -> [NSMenuItem] {
        let items = extensions.submenu.first(context) ?? ownSubmenu?(context) ?? []
        return extensions.submenuItems.apply(items, context)
    }

    func perform(_ context: CommandContext) {
        extensions.willPerform.send(context)
        if extensions.perform.first(context) == nil { ownPerform(context) }
    }

    /// `perform` skipping `overrideID` and earlier overrides, so an override can extend what it replaces.
    func perform(_ context: CommandContext, after overrideID: String) {
        if extensions.perform.first(context, after: overrideID) == nil { ownPerform(context) }
    }

    /// What this command asks of a location, if a location can refuse it.
    var locationAction: LocationAction? { LocationAction(commandID: id) }

    /// "Cut (⌘X)" for tooltips.
    var tooltipText: String {
        let base = tooltip ?? title
        guard let shortcut else { return base }
        return "\(base) (\(shortcut.displayString))"
    }
}

extension Shortcut {
    /// An upper-case key equivalent means Shift, as in AppKit.
    private var impliesShift: Bool { key.count == 1 && key.uppercased() == key && key.lowercased() != key }

    /// Compares as AppKit does a menu key equivalent; the Delete key reports 127 where shortcuts say 8.
    func matches(_ event: NSEvent) -> Bool {
        var expected = modifiers.intersection([.command, .option, .shift, .control])
        if impliesShift { expected.insert(.shift) }
        guard event.modifierFlags.intersection([.command, .option, .shift, .control]) == expected,
              let typed = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return typed.replacingOccurrences(of: "\u{7F}", with: "\u{8}") == key.lowercased()
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) || impliesShift { s += "⇧" }
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

/// Per-command extension points (DEC-024): per aspect, the first override whose condition holds wins.
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
    /// At most one feature may replace the command.
    private(set) lazy var replacement = Provided<Bool>(point("replacement"), "A newer version of the command replaced it.",
                                                       default: false)

    init(commandID: String) { self.commandID = commandID }

    private func point(_ aspect: String) -> String { "commands[\(commandID)].\(aspect)" }

    /// Aspects with contributions.
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
    /// Kept here so a feature may override a command registered after it.
    private var extensionsByID: [String: CommandExtensions] = [:]
    /// Command id → registering feature.
    private var owners: [String: String] = [:]

    /// Once per id; a second registration is an extension error (use `override`).
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

    /// Replaces the given closures where `when` holds (Trash, Gallery…). `order` picks between
    /// overlapping overrides; the first that holds wins.
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

    func hide(_ commandID: String, _ id: String, order: ExtensionOrder = .normal, when condition: @escaping (CommandContext) -> Bool) {
        override(commandID, id, order: order, when: condition, isAvailable: { _ in false })
    }

    /// Also hides matching commands registered later.
    func hide(prefix: String, except excluded: Set<String> = [], _ id: String, order: ExtensionOrder = .normal,
              when condition: @escaping (CommandContext) -> Bool) {
        let feature = ExtensionRegistry.shared.currentFeature
        let rule = PrefixRule(prefix: prefix, excluded: excluded) { [unowned self] commandID in
            // Attributed to the rule's feature, even for later commands.
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

    /// A new version keeps the command's place and overrides. Once per command; the replacing
    /// feature must require the original's.
    func replace(_ command: ExplorerCommand, _ id: String) {
        guard commands[command.id] != nil else {
            ExtensionRegistry.shared.report(point: "commands[\(command.id)].replacement",
                                            "there is no command to replace (is the feature that registers it required?).",
                                            contribution: id)
            return
        }
        let ext = extensions(for: command.id)
        guard ext.replacement.providerID == nil else {
            ext.replacement.provide(id, true)   // a second replacement is an error
            return
        }
        ext.replacement.provide(id, true)
        command.extensions = ext
        commands[command.id] = command
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Runs every contribution, in order, on the built submenu items.
    func adjustSubmenu(_ commandID: String, _ id: String, order: ExtensionOrder = .normal,
                       _ transform: @escaping ([NSMenuItem], CommandContext) -> [NSMenuItem]) {
        extensions(for: commandID).submenuItems.add(id, order: order, transform)
    }

    /// Runs `observer` first; the command still performs as usual.
    func beforePerform(_ commandID: String, _ id: String, order: ExtensionOrder = .normal,
                       _ observer: @escaping (CommandContext) -> Void) {
        extensions(for: commandID).willPerform.observe(id, order: order, observer)
    }

    /// Points with contributions, by command id.
    var extensionPoints: [ExtensionPointInfo] {
        extensionsByID.keys.sorted().flatMap { extensionsByID[$0]?.points ?? [] }
    }

    /// Flags overrides of never-registered commands (typos, removed features). Run after registration.
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

    /// Per-slot ranks that differ from the shared ones (Explorer's background menu starts with View).
    var sectionRanks: [CommandSlot: [String: Int]] = [:]

    /// Ordered by section, order, then registration.
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

    /// In menu bar order.
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

    /// The location-bound command this event's shortcut would run.
    func locationCommand(forShortcut event: NSEvent) -> ExplorerCommand? {
        all.first { $0.locationAction != nil && $0.shortcut?.matches(event) == true }
    }

    func command(forMenuAction action: Selector) -> ExplorerCommand? {
        all.first { $0.menuAction == action }
    }

    /// False if the command is unavailable or disabled.
    @discardableResult
    func perform(_ id: String, context: CommandContext) -> Bool {
        guard let command = commands[id], command.isAvailable(context), command.isEnabled(context) else { return false }
        command.perform(context)
        return true
    }
}

// MARK: - Menus

/// Context menus carry a frozen context.
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

/// Target of every command menu item except responder-chain ones (`menuAction`), which go via the window.
final class CommandDispatcher: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = CommandDispatcher()

    /// Menus only, not buttons (e.g. sentence case in context menus).
    static let menuTitleHook = Pipeline<String, (command: ExplorerCommand, context: CommandContext)>(
        "CommandDispatcher.menuTitleHook", "Adjusts a command's title in menus (sentence case in context menus).",
        signature: "(title, (command, context)) -> title")

    /// A slot's menu is complete and about to be shown.
    static let menuBuilt = Observers<(slot: CommandSlot, menu: NSMenu)>(
        "CommandDispatcher.menuBuilt", "A slot's menu was built (per-slot AppKit settings).", signature: "((slot, menu)) -> Void")

    static func menuTitle(_ command: ExplorerCommand, context: CommandContext) -> String {
        menuTitleHook.apply(command.title(in: context), (command, context))
    }

    /// Menu bar context: the frontmost browser window's active tab.
    func liveContext(surface: CommandSurface, sender: Any? = nil) -> CommandContext {
        if let window = BrowserWindowController.active { return window.context(surface: surface, sender: sender) }
        return CommandContext(window: nil, location: nil, surface: surface, sender: sender)
    }

    /// Skips unavailable commands; separates sections.
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
        Self.menuBuilt.send((slot, menu))
        return menu
    }

    /// Context menus pass a frozen context; the menu bar passes nil (live).
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
        guard command.isAvailable(context), command.isEnabled(context) else { refuse(command, context); return }
        command.perform(context)
    }

    /// Why the location can't run `action`; nil when it can, or when no location or action is involved.
    func limitation(of action: LocationAction?, in context: CommandContext) -> String? {
        guard let action, let location = context.location else { return nil }
        return LocationRegistry.provider(for: location).limitation(of: action, in: location)
    }

    /// The one way a command says no: a beep, and the location's reason in the status bar when it has one.
    func refuse(_ command: ExplorerCommand, _ context: CommandContext) {
        NSSound.beep()
        if let reason = limitation(of: command.locationAction, in: context) { context.window?.statusBar.setMessage(reason) }
    }

    /// Explains a shortcut the location blocks, since a disabled menu item never sends its action; false if it isn't blocked.
    func refuseIfLocationBlocks(_ command: ExplorerCommand, _ context: CommandContext) -> Bool {
        guard !(command.isAvailable(context) && command.isEnabled(context)),
              limitation(of: command.locationAction, in: context) != nil else { return false }
        refuse(command, context)
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item = menuItem as? CommandMenuItem, let command = CommandRegistry.shared.command(item.commandID) else { return true }
        let context = item.frozenContext ?? liveContext(surface: .menuBar)
        return validate(command, item: menuItem, context: context)
    }

    /// Also used by the window's responder-chain validation.
    func validate(_ command: ExplorerCommand, item: NSMenuItem, context: CommandContext) -> Bool {
        item.title = CommandDispatcher.menuTitle(command, context: context)
        item.state = command.state(context)
        item.toolTip = nil
        if command.yieldsToTextInput, context.window?.isEditingText == true { return false }
        guard command.isAvailable(context), command.isEnabled(context) else {
            item.toolTip = limitation(of: command.locationAction, in: context)
            return false
        }
        return true
    }

    // Menu bar submenus fill when opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let parent = menu.supermenu?.items.first(where: { $0.submenu === menu }),
              let id = parent.representedObject as? String, let command = CommandRegistry.shared.command(id),
              command.hasSubmenu else { return }
        menu.removeAllItems()
        command.submenuItems(liveContext(surface: .menuBar)).forEach(menu.addItem)
    }
}
