# Testing Arbor

## 1. Unit tests (logic)
```bash
scripts/test.sh
```
Put logic in `Sources/ArborCore` and test it with Swift Testing in `Tests/ArborCoreTests`.
Tests must use disposable fixture folders (`Fixture` in `FileSystemTests.swift`), never real user files or the real Trash.
`scripts/build-app.sh debug` must build with zero warnings.

## 2. Scripted UI checks (the real app)
`Sources/Arbor/DebugScript.swift` drives the live UI through the same command registry and responder chain as the menus.
Always run headless so nothing appears on screen:

```bash
scripts/build-app.sh debug
ROOT=$(mktemp -d); FX="$ROOT/fixture"; mkdir -p "$FX"; echo hi > "$FX/a.txt"
ARBOR_HEADLESS=1 ARBOR_APPEARANCE=dark \
ARBOR_SCRIPT="wait:1;select:a.txt;click:edit.copy;event;click:edit.paste;event;wait:1.5;log:$ROOT/state.txt;snapshot:$ROOT/shot.png;quit" \
  build/Arbor.app/Contents/MacOS/Arbor "$FX"
cat "$ROOT/state.txt"
```

Environment:
- `ARBOR_HEADLESS=1`: invisible, click-through window, no Dock icon. Preferences (pins, view mode, sort, panes) go to a throwaway domain that `quit` deletes, and window/split/column geometry is neither read nor saved, so runs never change the user's settings.
- `ARBOR_APPEARANCE=light|dark`: forces the appearance (check both).
- The path argument opens that folder; without it the window opens Home.

Steps (separated by `;`; the first `:` separates a step from its argument):

| Step | Does |
|---|---|
| `wait:1.5` | pause (seconds) |
| `event` | post an event boundary (undo grouping closes per event); put it after each user action |
| `select:a.txt\|b.md` | select rows by name in the active tab (empty = none) |
| `click:<command id>` | perform a registry command with the active tab's context, e.g. `click:edit.copy`, `click:file.newFolder`, `click:view.previewPane`, `click:tab.closeRight` |
| `action:cut:` | send a selector through the responder chain (`undo:` etc.) |
| `newtab` / `closetab` / `duptab` / `detachtab` | tab commands on the active tab |
| `tab:N` / `movetab:FROM:TO` | select tab N; move a tab (1-based) |
| `location:home\|thismac\|gallery\|network\|trash\|<path>\|<location key>` | navigate the active tab |
| `back` / `forward` / `up` / `refresh` | navigation |
| `view:details\|largeIcons\|…` | set the view mode (unregistered modes show Details; `log` says so) |
| `type:New name` / `enter` / `escape` | edit the focused text field (rename, address) |
| `button:Keep Both` | click a button in the window's sheet or modal alert |
| `search:rep` | type into the search box |
| `address:~/Documents` | submit text through the address bar |
| `log:/path` | append windows, tab titles, active tab, location key, view mode, rows, selection, status bar, history, breadcrumb, command bar and status-bar toggle states, panes, navigation tree, frames |
| `crumbs:/path` | append breadcrumb segments, collapsed segments and every chevron's menu entries |
| `menu:<which>:/path` | append a menu's titles, shortcuts, checks and disabled states. `<which>`: `item`, `background`, `tree:<row>`, `tab:<n>`, `new`, `sort`, `view`, `seemore`, `main:<title>` |
| `hittest:x,y:/path` | append the view class under a window point (top-left origin), e.g. to prove the tab row gets clicks |
| `undostate:/path` | append the undo stack state |
| `snapshot:/path.png` | draw the window (title bar included) into a PNG; `snapshotlayer:` renders the layer tree instead |
| `quit` | delete the headless preferences domain and exit |

Features add steps and log lines from their own files: `DebugScript.registerStep("name") { arg, window in … }` and `DebugScript.registerLogger { window in "…" }`.

Rules of thumb:
- Start with `wait:1` so the first location has loaded.
- Use a unique `mktemp -d` fixture and output paths per run; several test runs may happen at once.
- Read the PNGs to check visuals, in light and dark.
- End scripts with `quit`. Never leave a test app running, headless or not.
- Rendering note (macOS 26): a custom `NSTableHeaderView` or header-cell subclass stops table rows from drawing (on screen and in snapshots). Style headers through the stock cell's attributed title instead.

## 3. Accessibility, keyboard and localization checks
Steps: `axdump:/path` (accessibility tree as VoiceOver sees it), `key:shift+F10` (keys through the real keyboard path), `focus:/path`, `mouse:3|4`, `swipe:back|forward`, `compose:<text>` (input-method marked text), `announcements:/path`, `contextkey:/path`, `textsize:130`.
Environment: `ARBOR_PSEUDO_LOC=1` (accented, longer strings), `ARBOR_RTL=1` (right-to-left layout), `ARBOR_CONTRAST=1`, `ARBOR_REDUCE_MOTION=1`, `ARBOR_TEXT_SIZE=150`. Keep the string table current with `scripts/extract-strings.sh` (`--check` verifies). Details: docs/features/accessibility.md.
