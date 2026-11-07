# Arbor architecture and extension points

Read this before adding a feature. Goal: each feature lives in **its own files** and touches shared files only through
**one line in `Sources/Arbor/Features.swift`**. Keep it that way so parallel branches merge cleanly.

## Map

| Folder | Holds |
|---|---|
| `Sources/ArborCore` | UI-free, unit-tested logic: `Location`, `NavigationHistory`, `ViewMode`, listing, sorting, paths, names, transfers |
| `Window/` | `BrowserWindowController` (one per window), `TabState` (one per tab), tab strip, address bar, search box, command bar, status bar |
| `Views/` | `ItemViewController` protocol + `ViewModeRegistry`, `DetailsViewController`, `IconProvider`, row styling |
| `Commands/` | `ExplorerCommand`, `CommandRegistry`, menu building, all core commands, menu bar |
| `Locations/` | `LocationProvider` + `LocationRegistry`, `FolderProvider`, placeholder Home / This Mac / "not available yet" pages |
| `Panes/` | navigation pane, `SidePaneRegistry`, Preview pane, basic Details pane |
| `Support/` | `Theme` (all colors/metrics), `ChromeButton`, `Prefs`, `QuickAccess`, clipboard, `OperationCenter` (jobs, undo) |

**Registering.** Write `enum MyFeature { static func register() { … } }` in your files, then replace *your* slot comment in
`Features.registerAll()` with `MyFeature.register()`. Don't reorder slots or remove the blank lines between them.
Later registrations win, so you replace a core placeholder by registering, never by editing it. Avoid editing
`PlaceholderPages.swift`, `CoreFeature`, or another feature's files; add a hook instead and say so in your report.

## Window, tabs, locations

A window has one set of views. Each `TabState` holds history (`NavigationHistory` of `Location`s), view mode, sort, search
text, selection names, scroll anchor and a cached listing (global LRU of 8). `BrowserWindowController` API you'll use:
`navigate(to:select:)`, `goBack/goForward/goUp/reload()`, `openTab(_:)`, `activeTab`, `location`, `itemView`,
`selectedItems`, `visibleItems`, `applyFilter(_:)`, `setViewMode(_:)`, `setSortOrder(_:)`, `toggleSidePane(_:)`,
`startTransfer(_:_:to:)`, `refreshSelecting(_:rename:)`, `statusBar.setMessage(_:isError:)`, `context(surface:sender:)`.

`Location` (`ArborCore/Location.swift`): `.folder(URL)`, `.home`, `.thisMac`, `.gallery`, `.network`, `.trash`,
`.search(SearchRequest)`, `.archive(URL, innerPath:)`, `.library(String)`. It has `displayName`, `key` / `init?(key:)`
(persistence; equality uses the key), and `parent()` (Up). Add cases only with tests in `LocationTests.swift`.

## 1. Location provider (Home, This Mac, Trash, Gallery, archives, network, search results)

```swift
final class TrashProvider: LocationProvider {
    func handles(_ location: Location) -> Bool { location == .trash }
    func load(_ location: Location, context: LocationLoadContext,
              completion: @escaping (Result<LocationContent, Error>) -> Void) -> LoadHandle? {
        let handle = LoadHandle()
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.trashedItems()                      // [FileItem]
            DispatchQueue.main.async { if !handle.isCancelled { completion(.success(.items(items))) } }
        }
        return handle            // .items → standard views: sort, filter, selection, rename, drag all work
    }                            // .custom(NSViewController) → your own page (Home, This Mac tiles)
    func allowsItemEditing(in location: Location) -> Bool { false }   // disables Rename/New/Delete commands
    func targetFolder(for location: Location) -> URL? { nil }         // where New/Paste write
    // Optional: watch(_:onChange:) -> AnyObject?, title(for:), icon(for:size:), emptyText(for:)
}
// register(): LocationRegistry.register(TrashProvider())
```
Pages get `context.host` (`LocationHost`: `navigate(to:select:)`, `openInNewTab(_:)`, `showStatusMessage`), and may adopt
`LocationPageStatus` for status-bar text. Open hooks: `LocationRegistry.registerOpenHandler { item in item.url.pathExtension == "zip" ? .archive(item.url, innerPath: "") : nil }`.
Breadcrumbs for new kinds: `Breadcrumbs.register { location in … [Crumb] or nil }`.

## 2. Commands and menu slots

Every action is an `ExplorerCommand` placed in named slots. Menus, the command bar and context menus are built from the
registry when shown; unavailable commands are left out, disabled ones greyed. Sections (`MenuSection`) get separators.
Slots: `.commandBar` (Cut…Delete), `.commandBarContextual`, `.commandBarTrailing`, `.statusBarTrailing`, `.newMenu`,
`.sortMenu`, `.viewMenu`, `.showMenu`, `.seeMore`, `.itemContextMenu`, `.backgroundContextMenu`, `.treeContextMenu`,
`.tabContextMenu`, `.mainMenu("File" | "Edit" | "View" | "Go" | "Window" | new title)`.

```swift
CommandRegistry.shared.register(ExplorerCommand(
    id: "archive.extractAll", title: "Extract All…", symbol: "archivebox",   // arguments in declaration order
    shortcut: Shortcut("e", [.command, .shift]),             // menu key equivalent (shown in menus)
    keyBindings: [KeyBinding(14, [.command, .shift], scope: .window)],   // optional physical-key binding
    placements: [.commandBarContextual(10), .itemContextMenu(.archive, 10), .mainMenu("File", .archive, 10)],
    showsTitle: true,                                        // icon + title in the command bar
    isAvailable: { ctx in ctx.single?.url.pathExtension.lowercased() == "zip" },   // hidden when false
    isEnabled: { ctx in ctx.targetFolder != nil },
    perform: { ctx in ArchiveFeature.extract(ctx.selection, into: ctx.targetFolder!, window: ctx.window) }))
```
`CommandContext` is frozen when the menu opens or the button is pressed: `window`, `location`, `selection` (FileItems),
`targetFolder`, `surface`, `sender` (anchor view), `tabIndex` (tab menu), `treeLocation` (tree menu), `allowsEditing`.
Also: `dynamicTitle`, `state` (checkmarks/toggles), `submenu`, `menuAction` (responder selector so text fields win, e.g.
`cut:`), `yieldsToTextInput`. Re-registering an id replaces a command. Keys inside the file list (F2, Delete, Space)
use `KeyBinding(code)` with the default `.itemView` scope. Run any command from scripts with `click:<id>`.

## 3. View modes

```swift
final class IconGridViewController: NSViewController, ItemViewController { … }
ViewModeRegistry.register([.extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons]) { IconGridViewController() }
```
Implement `ItemViewController` (`Views/ItemViewController.swift`): `display(_ update: ItemViewUpdate)` receives items
already filtered and sorted by the window, plus `select` (nil = keep), `scrollTo`, `locationChanged`, `emptyText`,
`allowsEditing`, `folder` (drop target). Report through `itemDelegate` (`ItemViewDelegate`: open, selection changed,
context menu, rename, transfer, sort changed, unhandled keys) exactly as `DetailsViewController` does. Return true from
`canDisplay(_:)` for modes the same instance can switch between (icon sizes); the window sets `viewMode`. Unregistered
modes are disabled in View ▾ and fall back to Details. "Compact view" is `Prefs.compactView`; re-read it in `reloadRows()`.

## 4. Side panes (Preview / Details / your own)

```swift
final class PropertiesPane: NSView, SidePaneProvider {
    var view: NSView { self }
    func update(selection: [FileItem], location: Location?) { … }   // called while visible
    func releaseResources() { … }                                   // free previews before removal
}
SidePaneRegistry.register(SidePaneDescriptor(id: "details", title: "Details pane") { PropertiesPane() })
```
Registering id `"details"` or `"preview"` replaces the core pane. One pane shows at a time (`Prefs.sidePane`); toggle a new
pane with a command calling `ctx.window?.toggleSidePane("myPane")`. Panes are created when shown and released when hidden.

## 5. Search

```swift
final class IndexedSearch: SearchController {
    weak var window: BrowserWindowController?
    init(window: BrowserWindowController) { self.window = window }
    func placeholder(for location: Location) -> String { "Search \(location.displayName)" }
    func queryChanged(_ text: String) { /* debounce; or window?.applyFilter(text) for in-folder filtering */ }
    func submit(_ text: String) {
        guard let scope = window?.location.folderURL else { return }
        window?.navigate(to: .search(SearchRequest(query: text, scope: scope, recursive: true)))
    }
    func locationDidChange(_ location: Location) {}
}
SearchRegistry.register { window in IndexedSearch(window: window) }   // one instance per window
```
Pair it with a `LocationProvider` for `.search` locations.

## Look and feel

All colors and metrics live in `Support/Theme.swift` (light/dark dynamic). Draw custom chrome in `draw(_:)` (fill
`bounds`, not `dirtyRect`: views don't clip on macOS 14+), use `ChromeButton` for flat buttons and
`ExplorerRowView` for list rows. Folder/drive/location icons come from `IconProvider.shared` (code-drawn folders + SF
Symbols; never Microsoft assets, DEC-018). Don't subclass `NSTableHeaderView` or its cells (rows stop drawing on macOS 26).

## Testing your feature

Unit-test logic in `ArborCore`. Drive the app headless (TESTING.md). Add script steps and log lines from your own files:
`DebugScript.registerStep("emptytrash") { arg, window in …; return 0.8 }` and `DebugScript.registerLogger { w in "trash: …" }`.
Keep `scripts/build-app.sh debug` at zero warnings, update your rows in docs/FEATURE-STATUS.md, and record new decisions in
docs/DECISIONS.md.
