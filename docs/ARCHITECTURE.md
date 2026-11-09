# Arbor architecture and extension points

Read this before adding a feature. Goal: each feature lives in **its own files** and touches shared files only through
**one line in `Sources/Arbor/Features.swift`**. Keep it that way so parallel branches merge cleanly.

## Map

| Folder | Holds |
|---|---|
| `Sources/ArborCore` | UI-free, unit-tested logic: `Location`, `NavigationHistory`, `ViewMode`, listing, sorting, paths, names, transfers, journals, history, queue, verification. Subfolders per area: `Search/` (AQS parser, evaluator, Spotlight translation, direct scan), `Archives/` (ZIP reader, bsdtar listing, safety planner), `Properties/`, `FolderOptions/`, `Consistency/`, `Accessibility/` (string table, key names), `Performance/` (budgets, background sort, stall recorder), `PortableSettings/` (settings file allowlist, format and import plan) |
| `Sources/ArborCore` | UI-free, unit-tested logic: `Location`, `NavigationHistory`, `ViewMode`, listing, sorting, paths, names, transfers, journals, history, queue, verification. Subfolders per area: `Search/` (AQS parser, evaluator, Spotlight translation, direct scan), `Archives/` (ZIP reader, bsdtar listing, safety planner), `Properties/`, `FolderOptions/`, `Consistency/`, `Accessibility/` (string table, key names), `Performance/` (budgets, background sort, stall recorder), `Workspaces/` (saved tab sets) |
| `Window/` | `BrowserWindowController` (one per window, split by area into `BrowserWindowController+*.swift`), `TabState` (one per tab), tab strip and tear-off, address bar and breadcrumbs, navigation row, search box, command bar, status bar, `WindowHooks` |
| `Views/` | `ItemViewController` protocol + `ViewModeRegistry`, `DetailsViewController`, `DetailsColumns` (per-location column layouts), `IconProvider`, `ItemBadges`, row and tile styling |
| `Commands/` | `ExplorerCommand`, `CommandRegistry`, menu building, core commands, menu bar |
| `Locations/` | `LocationProvider` + `LocationRegistry`, `FolderProvider`, page protocols (`LocationPageSelection`, `LocationPageFiltering`, `LocationPageViewState`), placeholder pages |
| `Panes/` | navigation pane (+ `NavigationPaneExtras` for extra nodes), `SidePaneRegistry`, core Preview pane |
| `Support/` | `Theme`, `ChromeButton`, `Prefs`, `FileClipboard`, `OperationCenter` (jobs, undo), `SystemOpen` (every hand-off to other apps; logged only in headless runs), `AlertSheets` (one sheet at a time per window), `InteractionHooks`, `ItemHooks`, `SelectionEmphasis` |
| `Features/<Area>/` | One folder per feature area, each registered by one line in `Features.swift`: `IconViews`, `DetailsDepth` (grouping, filters, columns), `Home`, `ThisMac`, `Search`, `FileOperations`, `Properties`, `Archives`, `Network`, `Trash`, `Cloud`, `GalleryLibraries`, `FolderOptions`, `ItemActions`, `Accessibility`, `VisualParity`, `Consistency`, `Performance`, `Reliability`, `SettingsTransfer`. Each has an area document in `docs/features/` |
| `Features/<Area>/` | One folder per feature area, each registered by one line in `Features.swift`: `IconViews`, `DetailsDepth` (grouping, filters, columns), `Home`, `ThisMac`, `Search`, `FileOperations`, `Properties`, `Archives`, `Network`, `Trash`, `Cloud`, `GalleryLibraries`, `FolderOptions`, `ItemActions`, `Accessibility`, `VisualParity`, `Consistency`, `Performance`, `Reliability`, `Workspaces`. Each has an area document in `docs/features/` |
| `Features/<Area>/` | One folder per feature area, each registered by one line in `Features.swift`: `IconViews`, `DetailsDepth` (grouping, filters, columns), `Home`, `ThisMac`, `Search`, `FileOperations`, `Properties`, `Archives`, `Network`, `Trash`, `Cloud`, `GalleryLibraries`, `FolderOptions`, `ItemActions`, `Accessibility`, `VisualParity`, `Consistency`, `Performance`, `Reliability`, `WindowsShortcuts`. Each has an area document in `docs/features/` |
| `Features/<Area>/` | One folder per feature area, each registered by one line in `Features.swift`: `IconViews`, `DetailsDepth` (grouping, filters, columns), `Home`, `ThisMac`, `Search`, `FileOperations`, `Properties`, `Archives`, `Network`, `Trash`, `Cloud`, `GalleryLibraries`, `FinderTags`, `FolderOptions`, `ItemActions`, `Accessibility`, `VisualParity`, `Consistency`, `Performance`, `Reliability`. Each has an area document in `docs/features/` |
| `Features/<Area>/` | One folder per feature area, each registered by one line in `Features.swift`: `IconViews`, `DetailsDepth` (grouping, filters, columns), `Home`, `ThisMac`, `Search`, `FileOperations`, `Properties`, `Archives`, `Network`, `Trash`, `Cloud`, `GalleryLibraries`, `FolderOptions`, `ItemActions`, `Accessibility`, `VisualParity`, `Consistency`, `Performance`, `Reliability`, `AddressEntry`. Each has an area document in `docs/features/` |
| `Features/<Area>/` | One folder per feature area, each registered by one line in `Features.swift`: `IconViews`, `DetailsDepth` (grouping, filters, columns), `Home`, `ThisMac`, `Search`, `FileOperations`, `Properties`, `Archives`, `Network`, `Trash`, `Cloud`, `GalleryLibraries`, `FolderOptions`, `ItemActions`, `Accessibility`, `VisualParity`, `Consistency`, `Performance`, `Reliability`, `Services`. Each has an area document in `docs/features/` |

Features never depend on line order: each declares the features it `requires`, and `Features.registerAll()` registers
them in a stable dependency order (DEC-024). How to write one, and the extension points it plugs into: **Writing a
feature** below and [EXTENSION-POINTS.md](EXTENSION-POINTS.md).

A feature that adds a `LocationProvider` also says what that place refuses: see section 1.

**Registering.** Write `enum MyFeature: ExplorerFeature { static let id = "my-feature"; static func register() { … } }`
in your files, then add *one* line `MyFeature.self,` to `Features.all` in a free slot. Don't reorder lines or remove the
blank lines between them. Location providers registered later still win (you replace a core placeholder by
registering, never by editing it). Avoid editing `PlaceholderPages.swift`, `CoreFeature`, or another feature's files;
contribute to an extension point (or add one) instead and list it in your area document.

## Writing a feature

**The contract** (`Sources/Arbor/Features.swift`):

```swift
enum TrashFeature: ExplorerFeature {
    static let id = "trash"                       // lowercase-with-dashes; prefixes every contribution id
    static let requires = ["file-operations"]     // what it builds on (default []); "core" is implicit
    static func register() { … }                  // contributions only: no windows, no disk work
}
```

`requires` lists the features whose registrations this one builds on: it overrides their commands, wraps or adds to
what they register, or needs their contributions in place. `FeatureGraph` (ArborCore) sorts `Features.all` so every
feature comes after what it requires and otherwise keeps the listed order; a missing dependency, a duplicate id or a
cycle stops launch with a message naming the features. After registration, any extension error (below) stops launch
too, and `Tests/ArborTests/FeatureRegistrationTests.swift` registers every feature in `scripts/test.sh` and fails on the
same problems.

**Extension points** (`Sources/ArborCore/ExtensionPoint.swift`). Shared code calls a named point; features contribute
with an id and an optional `order`. Pick the kind by what the call site needs:

| Kind | Call site | Contribute with | Use it for |
|---|---|---|---|
| `Handlers<Input, Output>` | `first(input)`: the first non-nil answer (`handle(input)` for `Output == Void`) | `register(id, order:) { … nil-or-answer }` (`handles:` for true/false) | "who handles this?": open a file, an icon override, a breadcrumb builder |
| `Observers<Input>` | `send(input)`: every contribution runs | `observe(id, order:) { … }` | did/will events: a window was created, a tab displayed, a job finished |
| `Pipeline<Value, Context>` | `apply(value, context)`: each gets the previous output | `add(id, order:) { value, context in … }` | filters and adjustments: hidden files, drive lists, wrapping a pane |
| `Provided<Value>` | `.value` (a default until someone provides) | `provide(id, value)`; a second provider is an error | exactly one owner: start location, session restore, the search controller |
| Command overrides | the command's `isAvailable(_:)`, `perform(_:)`… | `CommandRegistry.shared.override(commandID, id, when:, isEnabled:, perform:…)`, `hide`, `hide(prefix:)`, `adjustSubmenu`, `beforePerform`, `replace` | changing another feature's command in your place (Trash, archives, Gallery) |

Rules:
- **Ids** are `"<feature id>.<what>"` (`"archives.open-file"`), unique per point. A duplicate id, a second provider, a
  second registration of a command id (use `replace`), a second `replace` of one command, a script step name used twice,
  or an override of a command nobody registers is an *extension error*: debug builds stop at once; every build refuses
  to launch with a message naming the point and both contributions.
- **Order**: contributions run by `ExtensionOrder` (`.first`, `.early`, `.normal`, `.late`, `.last`, `.custom(n)`), then
  by registration. Give an order only when your contribution must run before or after another one on the same point,
  and say why in a comment naming that contribution ("aliases resolve before anything looks at the file's type").
- **Commands**: never assign a command's closures. Overrides apply only where their `when` holds; for each aspect
  (availability, enabled, state, title, submenu, perform) the first matching override in run order decides, else the
  command's own closure. An override that adds to the behavior it replaces calls `command.perform(ctx, after: id)`.
- **Threading**: points are filled once at launch on the main thread and only read afterwards; calling one doesn't
  allocate or lock, so row decoration and sorting may use them (a few may be read off the main thread; their
  documentation says so).
- **New point**: declare it as a `static let` named after the expression that reaches it
  (`Handlers<…>("WindowHooks.tabTitle", "what it is for", signature: "…")`) and add it to `ExtensionCatalog.points`.

**Worked example** (hypothetical; `Webloc.url(in:)` stands for reading the file): a feature that opens `.webloc` files in the browser instead of their app, and hides Rename for them.

```swift
enum WeblocFeature: ExplorerFeature {
    static let id = "webloc"
    static let requires = ["item-actions"]       // it changes item-actions' multi-rename command

    static func register() {
        // Before shortcuts are resolved (item-actions.shortcuts runs at .normal): a .webloc is never an alias.
        InteractionHooks.openFile.register("webloc.open-in-browser", order: .early, handles: { window, file in
            guard file.url.pathExtension == "webloc", let target = Webloc.url(in: file.url) else { return false }
            SystemOpen.open(target)
            return true
        })
        CommandRegistry.shared.hide("file.rename", "webloc.no-rename") { ctx in
            ctx.selection.contains { $0.url.pathExtension == "webloc" }
        }
        DebugScript.registerLogger("webloc.log") { _ in "webloc: ready" }
    }
}
// Features.swift, in a free slot of `all`:   WeblocFeature.self,
```

Check it with `scripts/list-extension-points.sh`: the two contributions show up in run order, and `errors: none`.

## Window, tabs, locations

A window has one set of views. Each `TabState` holds history (`NavigationHistory` of `Location`s), view mode, sort, search
text, selection names, scroll anchor and a cached listing (global LRU of 8). `BrowserWindowController` API you'll use:
`navigate(to:select:)`, `goBack/goForward/goUp/reload()`, `openTab(_:)`, `activeTab`, `location`, `itemView`,
`selectedItems`, `visibleItems`, `applyFilter(_:)`, `setViewMode(_:)`, `setSortOrder(_:)`, `toggleSidePane(_:)`,
`startTransfer(_:_:to:)`, `refreshSelecting(_:rename:)`, `statusBar.setMessage(_:isError:)`, `context(surface:sender:)`.

The controller is one class split into extensions by area (all in `Window/`). Members shared between these files are
internal only because Swift has no cross-file `private`; features use the API above, not them.

| File | Holds |
|---|---|
| `BrowserWindowController.swift` | stored state, `active`, initializers, the tab list (open, select, close, move, replace all, take/adopt, `TabStripDelegate`) and `ensureItemView(for:)`, so only it writes `tabs`, `activeIndex` and `itemView` |
| `+Layout.swift` | building the window's views and split view, side pane show/toggle, `ExplorerSplitView` |
| `+Observation.swift` | preference, Quick access, clipboard, job and volume notifications; `volumeUnmountHandler` |
| `+Navigation.swift` | `NavRequest`, navigate/Back/Forward/Up/Refresh, loading, committing history, load failures, folder watching |
| `+Display.swift` | putting a tab's items or page on screen, view mode, sort, filter, `selectedItems`, `visibleItems` |
| `+Chrome.swift` | `updateChrome()` and `refreshChrome()`: address bar, buttons, command bar, status bar, side pane |
| `+Commands.swift` | `context(surface:sender:)`, `perform`, Edit menu responder actions, menu validation, context menus |
| `+AddressBar.swift` | typed addresses, `networkAddressHandler`, focusing the address bar and search box |
| `+FileOperations.swift` | `startTransfer`, `transferDropped` (drops from the tree, item views and breadcrumb), `refreshSelecting`, `neighborURL(after:)`, `open(_:inNewTab:)` |
| `+AddressBar.swift` | typed addresses, `networkAddressHandler`, `unresolvedAddress`, focusing the address bar and search box |
| `+FileOperations.swift` | `startTransfer`, `refreshSelecting`, `neighborURL(after:)`, `open(_:inNewTab:)` |
| `+Delegates.swift` | `ItemViewDelegate` (open, selection, inline rename, drop, keys), `NavigationPaneDelegate`, `LocationHost` |
| `+QuickLook.swift` | the Quick Look panel (Space) |
| `+WindowDelegate.swift` | `NSWindowDelegate`: undo manager, traffic lights, full screen, close teardown |

Tab tear-off and merge live in `TabTearOff.swift`.

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
    func limitation(of action: LocationAction, in location: Location) -> String? {   // required: why an action can't run here
        action.notAFolderLimitation()
    }
    // Optional: watch(_:onChange:) -> AnyObject?, title(for:), icon(for:size:), emptyText(for:)
}
// register(): LocationRegistry.register(TrashProvider())
```
`limitation(of:in:)` has no default on purpose, so a new provider can't compile without saying what it refuses. Answer from
memory only (main thread, like `targetFolder`). The reason appears as the tooltip of the greyed button or menu item and in the
status bar when the command is pressed (`CommandDispatcher.refuse`), by button, menu or shortcut. A page that isn't a folder answers
`action.notAFolderLimitation()`, as here; `TrashProvider` shows how to answer per action. Add a sample of the new provider to `ProviderCapabilityMatrixTests.samples`: the test fails
until it has one, and it checks that a command runs exactly where the provider gives no reason.
Pages get `context.host` (`LocationHost`: `navigate(to:select:)`, `openInNewTab(_:)`, `showStatusMessage`), and may adopt
`LocationPageStatus` for status-bar text. Open handlers: `LocationRegistry.registerOpenHandler("archives.browse") { item in item.url.pathExtension == "zip" ? .archive(item.url, innerPath: "") : nil }`. They may run off the main thread (outside opens), so they use thread-safe state only.
Breadcrumbs for new kinds: `Breadcrumbs.register("myfeature.crumbs") { location in … [Crumb] or nil }`.

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
`cut:`), `yieldsToTextInput`. Each id is registered once; another feature changes it with `CommandRegistry.shared.override`
(per location) or upgrades it with `replace` (see Writing a feature). Keys inside the file list (F2, Space) use
`KeyBinding(code)` with the default `.itemView` scope, except keys whose meaning differs between the keyboard presets
(Return, ⌘↓, ⌫, ⌦): those belong in `FileListKeyPreset.rows` and nowhere else. Run any command from scripts with `click:<id>`.

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
SearchRegistry.factory.provide("search.explorer") { window in IndexedSearch(window: window) }   // one instance per window
```
Pair it with a `LocationProvider` for `.search` locations.

## Look and feel

All colors and metrics live in `Support/Theme.swift` (light/dark dynamic). Draw custom chrome in `draw(_:)` (fill
`bounds`, not `dirtyRect`: views don't clip on macOS 14+), use `ChromeButton` for flat buttons and
`ExplorerRowView` for list rows. Folder/drive/location icons come from `IconProvider.shared` (code-drawn folders + SF
Symbols; never Microsoft assets, DEC-018). Don't subclass `NSTableHeaderView` or its cells (rows stop drawing on macOS 26).

## Extension points for cross-feature behavior

Shared views call typed extension points instead of knowing about features. Contribute to one (or add one) rather than
editing another feature's files. The full list with every contribution in run order: [EXTENSION-POINTS.md](EXTENSION-POINTS.md)
(regenerate it with `scripts/list-extension-points.sh --markdown`).

| Points | Where | Used for |
|---|---|---|
| `InteractionHooks` | `Support/InteractionHooks.swift` | open file, commit rename, drop, drag hover (spring-loading), left and right mouse down, icon decoration, extra item detail lines |
| `ItemHooks` | `Support/ItemHooks.swift` | drag writers (file promises for archive members) and drop handlers for drops without file URLs |
| `WindowHooks`, `ItemViewHooks`, `NavigationPaneHooks`, `PreviewPolicy` | `Window/WindowHooks.swift` | Folder Options effects (title bar path, name decoration, tree options, preview handlers), selection changes |
| `PreviewHooks`, `SidePaneRegistry.wrappers` | `Locations/LocationPageExtras.swift`, `Panes/SidePane.swift` | Quick Look / Preview pane for items without a file on disk; wrapping a pane when it is created |
| `ViewOptions`, `FileSorter.columnValues` | `Features/DetailsDepth/ViewOptions.swift`, ArborCore | per-tab columns, Group by, filters; `folderKindResolver`, `columnsEdited`; sort values of extra columns |
| `DetailsColumns.register`, `ColumnCatalog.register` | `Views/DetailsColumns.swift`, ArborCore | per-location column layouts (Trash, search, ZIP, cloud) and extra columns |
| `Breadcrumbs.register`, `LocationRegistry.registerOpenHandler` | `Window/`, `Locations/` | breadcrumbs for new location kinds; opening a file as a location (archives, saved searches); open handlers may run off the main thread, thread-safe state only |
| `CommandRegistry.override` & co. | `Commands/ExplorerCommand.swift` | another feature's command behaving differently in your place |
| `OperationCenter`, `TransferPreflight`, `SystemTrash.observers` | `Support/`, ArborCore | job preparation, admission (queue), verification, history; questions before a copy; the Trash journal |

## Scripts

| Script | Does |
|---|---|
| `scripts/build-app.sh [debug\|release] [--universal]` | builds `build/Arbor.app` (zero warnings expected) |
| `scripts/test.sh` | unit tests (also checks the string table with `extract-strings.sh --check`) |
| `scripts/core-checks.sh`, `scripts/behavior-checks.sh [group…]` | headless regression checks for fixed bugs |
| `scripts/acceptance.sh [Txx…]` | the task scenarios T01–T30 of SPEC.md §17.5, headless; results in docs/ACCEPTANCE.md |
| `scripts/bench.sh [--check]` | memory and responsiveness workloads; `--check` compares with `scripts/bench-budgets.txt` (docs/PERFORMANCE.md) |
| `scripts/extract-strings.sh [--check]` | regenerates `Resources/en.lproj/Localizable.strings` |
| `scripts/list-extension-points.sh [--markdown FILE]` | every extension point with its contributions in run order, the feature order; fails on registration errors |
| `scripts/make-dmg.sh`, `scripts/sign-and-notarize.sh` | release packaging (docs/RELEASING.md) |

## Testing your feature

Unit-test logic in `ArborCore`. Drive the app headless (TESTING.md). Add script steps and log lines from your own files:
`DebugScript.registerStep("emptytrash") { arg, window in …; return 0.8 }` and `DebugScript.registerLogger("trash.log") { w in "trash: …" }`.
Step names are registered once (a second registration is an extension error). `extensions:/path` lists every extension
point with its contributions (`scripts/list-extension-points.sh`).
Keep `scripts/build-app.sh debug` at zero warnings, record status and decisions in your area document
(`docs/features/<area>.md`, decisions numbered `DEC-<area>-N`), and keep `docs/FEATURE-STATUS.md`, the consolidated list
of every requirement, in step with it.
